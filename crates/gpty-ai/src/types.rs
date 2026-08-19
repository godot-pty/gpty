//! Public session requests and event envelopes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BackendKind {
    #[default]
    Mock,
    Omp,
}

impl BackendKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mock => "mock",
            Self::Omp => "omp",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "mock" => Some(Self::Mock),
            "omp" | "oh-my-pi" | "pi" => Some(Self::Omp),
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
