//! Public session requests and event envelopes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BackendKind {
    #[default]
    Mock,
    Omp,
    Cli,
}

impl BackendKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mock => "mock",
            Self::Omp => "omp",
            Self::Cli => "cli",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "mock" => Some(Self::Mock),
            "omp" | "oh-my-pi" | "pi" => Some(Self::Omp),
            "cli" => Some(Self::Cli),
            _ => None,
        }
    }
}

/// Configuration fixed for the lifetime of one backend process.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionOpenRequest {
    #[serde(default)]
    pub backend: BackendKind,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub model: String,
    /// `BackendKind::Cli` only: the adapter command as argv (never
    /// shell-evaluated). Each prompt runs one child process.
    #[serde(default)]
    pub command: Vec<String>,
    /// Environment keys to remove from the child before it starts.
    ///
    /// The Inspector and its adapters are third-party CLIs that have no
    /// business holding workspace-control credentials: a GUI started from a
    /// gpty pane inherits `GPTY_SECRET`, `GPTY_SOCKET`, and that pane's
    /// event capability, and an adapter that inherited them could drive the
    /// whole workspace. The caller (the Godot extension bridge) supplies the
    /// list so there is one authoritative definition.
    #[serde(default)]
    pub strip_env: Vec<String>,
}

/// Remove `keys` from a child's environment before it is spawned.
///
/// Shared by every backend that starts a child process, so a credential the
/// GUI inherited can never reach an adapter or the private OMP session.
pub(crate) fn strip_child_env(command: &mut tokio::process::Command, keys: &[String]) {
    for key in keys {
        command.env_remove(key);
    }
}

/// One prompt in an already-open session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionPromptRequest {
    /// Captured terminal / concept output (untrusted).
    pub capture: String,
    #[serde(default)]
    pub concept_name: String,
    #[serde(default)]
    pub source_pane: String,
}

/// Backwards-compatible prompt shape used by prompt assembly helpers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObservationRequest {
    pub backend: BackendKind,
    pub capture: String,
    #[serde(default)]
    pub concept_name: String,
    #[serde(default)]
    pub source_pane: String,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub model: String,
}

impl SessionPromptRequest {
    pub fn as_observation(&self, config: &SessionOpenRequest) -> ObservationRequest {
        ObservationRequest {
            backend: config.backend,
            capture: self.capture.clone(),
            concept_name: self.concept_name.clone(),
            source_pane: self.source_pane.clone(),
            system_prompt: config.system_prompt.clone(),
            cwd: config.cwd.clone(),
            model: config.model.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EventChannel {
    Lifecycle,
    Prompt,
    Thinking,
    Answer,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AiEvent {
    Started { backend: String },
    Prompt { text: String },
    TurnBegin,
    Thinking { text: String },
    AnswerStarted,
    Delta { text: String },
    Status { message: String },
    Done { text: String },
    Error { message: String },
    Cancelled,
}

impl AiEvent {
    pub fn channel(&self) -> EventChannel {
        match self {
            Self::Prompt { .. } => EventChannel::Prompt,
            Self::Thinking { .. } => EventChannel::Thinking,
            Self::AnswerStarted | Self::Delta { .. } | Self::Done { .. } => EventChannel::Answer,
            _ => EventChannel::Lifecycle,
        }
    }

    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Done { .. } | Self::Error { .. } | Self::Cancelled
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AiEventEnvelope {
    pub session_id: String,
    pub turn_id: u64,
    pub run_id: String,
    pub sequence: u64,
    pub channel: EventChannel,
    pub event: AiEvent,
}

pub const MAX_CAPTURE_BYTES: usize = 64 * 1024;
pub const DEFAULT_INSPECTOR_SYSTEM_PROMPT: &str = "\
You are gpty's Inspector. You receive captured terminal output from \
a concept trigger or a user prompt. Summarize what happened, call out errors or next steps, \
and reply in concise Markdown. Do not invent files or commands that are not \
supported by the capture. Do not request secrets.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_child_env_removes_every_key() {
        let mut command = tokio::process::Command::new("sh");
        strip_child_env(
            &mut command,
            &["GPTY_SECRET".to_string(), "GPTY_SOCKET".to_string()],
        );
        let removals: Vec<String> = command
            .as_std()
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(key, _)| key.to_string_lossy().into_owned())
            .collect();
        assert!(removals.contains(&"GPTY_SECRET".to_string()));
        assert!(removals.contains(&"GPTY_SOCKET".to_string()));
    }
}
