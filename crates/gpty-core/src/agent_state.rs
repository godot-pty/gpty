//! Agent-state model — tiered, display-only detection of what a
//! terminal-hosted agent is doing.
//!
//! Three detection tiers, strongest first:
//!
//! 1. Capability-authenticated events (the `ompEvent` socket) —
//!    authoritative. The extension capability gates who may declare.
//! 2. OSC `gpty_state=<value>` declarations — published, spoofable by
//!    design (pasted text and `cat`-ed files can emit them). May set UI
//!    display state ONLY; never triggers actions, concepts, layouts, or
//!    IPC. Whitelisted values, single-shot, rate-limited.
//! 3. Regex / idle / exit heuristics — last resort, display only. Kept
//!    conservative: false positives cost a badge flash, false negatives
//!    nothing — the authoritative tiers exist for real signal.
//!
//! [`AgentStateTracker`] merges observations with tier precedence. States
//! surface through `paneStatus` and the titlebar badge — nothing else.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

/// Display-only agent state for a terminal. Never a decision input.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentState {
    /// No agent activity known.
    #[default]
    Idle,
    /// An agent turn is in flight.
    Working,
    /// The agent finished but wants the user's attention.
    NeedsAttention,
    /// The agent finished successfully.
    Completed,
    /// The agent finished with a failure.
    Failed,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Idle => "idle",
            AgentState::Working => "working",
            AgentState::NeedsAttention => "needs-attention",
            AgentState::Completed => "completed",
            AgentState::Failed => "failed",
        }
    }

    /// Strict whitelist for the Tier 2 OSC declaration channel. Unknown
    /// values are ignored — untrusted input must never set arbitrary state.
    pub fn from_declaration(value: &str) -> Option<Self> {
        match value.trim() {
            "idle" => Some(AgentState::Idle),
            "working" => Some(AgentState::Working),
            "needs-attention" | "needs_attention" => Some(AgentState::NeedsAttention),
            "completed" => Some(AgentState::Completed),
            "failed" => Some(AgentState::Failed),
            _ => None,
        }
    }
}

/// Detection tier. Lower = stronger: a Tier 1 observation can never be
/// overridden by Tier 2/3, and Tier 2 never by Tier 3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum StateTier {
    Tier1 = 1,
    Tier2 = 2,
    Tier3 = 3,
}

/// Minimum interval between accepted Tier 2 OSC declarations per terminal.
/// A flood of declarations (pasted text, prompt reprints) must not churn
/// the display state.
pub const DECLARATION_MIN_INTERVAL_MS: u64 = 500;

/// Tier 3 failure signals decay back to Idle after this long without a
/// refresh — a stale "Failed" badge would otherwise stick forever.
pub const TIER3_TTL_MS: u64 = 60_000;

/// Merges tiered observations into one display state per terminal.
#[derive(Debug, Clone, Copy, Default)]
pub struct AgentStateTracker {
    pub state: AgentState,
    pub tier: Option<StateTier>,
    pub at_unix_ms: u64,
    /// Tier 2 rate limit: timestamp of the last accepted OSC declaration.
    pub last_declaration_unix_ms: Option<u64>,
    /// Tier 3 TTL: timestamp of the last regex failure signal.
    pub last_t3_signal_unix_ms: Option<u64>,
}

impl AgentStateTracker {
    /// Apply an observation. Stronger tiers override; within the same tier
    /// the newest observation wins; weaker tiers are ignored. Returns true
    /// when the display state changed.
    pub fn observe(&mut self, tier: StateTier, state: AgentState, now_ms: u64) -> bool {
        if let Some(current) = self.tier
            && tier > current
        {
            return false;
        }
        let changed = self.tier != Some(tier) || self.state != state;
        self.tier = Some(tier);
        self.state = state;
        self.at_unix_ms = now_ms;
        changed
    }

    /// Tier 3 states decay back to Idle once no signal refreshed them for
    /// `ttl_ms`. Only Tier 3 decays — authoritative states persist until
    /// their source declares a change.
    pub fn decay_t3(&mut self, now_ms: u64, ttl_ms: u64) -> bool {
        if self.tier != Some(StateTier::Tier3) || self.state == AgentState::Idle {
            return false;
        }
        let stale = self
            .last_t3_signal_unix_ms
            .map(|t| now_ms.saturating_sub(t) >= ttl_ms)
            .unwrap_or(true);
        if stale {
            self.observe(StateTier::Tier3, AgentState::Idle, now_ms)
        } else {
            false
        }
    }
}

/// Conservative Tier 3 failure patterns (display-only). Standard Rust
/// `regex` — ReDoS-safe by construction, same stance as the concept engine.
static TIER3_FAILURE_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"(?i)\bfatal error\b",
        r"(?i)\bassertion failed\b",
        r"(?i)\bfailures?: [1-9][0-9]*\b",
        r"(?i)\btest result: FAILED\b",
        r"(?i)\btests? failed\b",
        r"(?i)\bcould not compile\b",
        r"(?i)^error: process didn't exit successfully",
        r"(?i)^npm error",
    ]
    .iter()
    .map(|p| Regex::new(p).expect("static tier-3 pattern must compile"))
    .collect()
});

/// True when a committed output line matches a Tier 3 failure pattern.
pub fn tier3_failure_match(line: &str) -> bool {
    TIER3_FAILURE_PATTERNS.iter().any(|re| re.is_match(line))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn declaration_whitelist() {
        assert_eq!(
            AgentState::from_declaration("working"),
            Some(AgentState::Working)
        );
        assert_eq!(
            AgentState::from_declaration("needs-attention"),
            Some(AgentState::NeedsAttention)
        );
        assert_eq!(
            AgentState::from_declaration("needs_attention"),
            Some(AgentState::NeedsAttention)
        );
        assert_eq!(
            AgentState::from_declaration(" completed "),
            Some(AgentState::Completed)
        );
        assert_eq!(AgentState::from_declaration("hacked"), None);
        assert_eq!(AgentState::from_declaration(""), None);
        assert_eq!(AgentState::from_declaration("WORKING"), None);
    }

    #[test]
    fn state_strings() {
        assert_eq!(AgentState::Idle.as_str(), "idle");
        assert_eq!(AgentState::Working.as_str(), "working");
        assert_eq!(AgentState::NeedsAttention.as_str(), "needs-attention");
        assert_eq!(AgentState::Completed.as_str(), "completed");
        assert_eq!(AgentState::Failed.as_str(), "failed");
    }

    #[test]
    fn stronger_tier_overrides_weaker() {
        let mut t = AgentStateTracker::default();
        assert!(t.observe(StateTier::Tier3, AgentState::Failed, 1000));
        assert_eq!(t.state, AgentState::Failed);

        assert!(t.observe(StateTier::Tier2, AgentState::Working, 2000));
        assert_eq!(t.state, AgentState::Working);
        assert_eq!(t.tier, Some(StateTier::Tier2));

        // Weaker tier must not override.
        assert!(!t.observe(StateTier::Tier3, AgentState::Failed, 3000));
        assert_eq!(t.state, AgentState::Working);

        // Strongest tier overrides everything.
        assert!(t.observe(StateTier::Tier1, AgentState::Completed, 4000));
        assert_eq!(t.state, AgentState::Completed);
    }

    #[test]
    fn same_tier_newest_wins() {
        let mut t = AgentStateTracker::default();
        assert!(t.observe(StateTier::Tier2, AgentState::Working, 1000));
        assert!(t.observe(StateTier::Tier2, AgentState::Completed, 2000));
        assert_eq!(t.state, AgentState::Completed);
        // No-op observation returns false.
        assert!(!t.observe(StateTier::Tier2, AgentState::Completed, 3000));
    }

    #[test]
    fn tier3_decay_after_ttl() {
        let mut t = AgentStateTracker::default();
        assert!(t.observe(StateTier::Tier3, AgentState::Failed, 1000));
        t.last_t3_signal_unix_ms = Some(1000);

        // Fresh: no decay.
        assert!(!t.decay_t3(1000 + TIER3_TTL_MS - 1, TIER3_TTL_MS));
        assert_eq!(t.state, AgentState::Failed);
        // Stale: decays to Idle.
        assert!(t.decay_t3(1000 + TIER3_TTL_MS, TIER3_TTL_MS));
        assert_eq!(t.state, AgentState::Idle);
    }

    #[test]
    fn authoritative_tiers_never_decay() {
        let mut t = AgentStateTracker::default();
        t.observe(StateTier::Tier1, AgentState::Failed, 1000);
        assert!(!t.decay_t3(200_000, TIER3_TTL_MS));
        assert_eq!(t.state, AgentState::Failed);

        let mut t2 = AgentStateTracker::default();
        t2.observe(StateTier::Tier2, AgentState::Working, 1000);
        assert!(!t2.decay_t3(200_000, TIER3_TTL_MS));
        assert_eq!(t2.state, AgentState::Working);
    }

    #[test]
    fn tier3_patterns() {
        assert!(tier3_failure_match(
            "test result: FAILED. 2 passed; 1 failed"
        ));
        assert!(tier3_failure_match("failures: 12"));
        assert!(tier3_failure_match("Assertion failed: x == y"));
        assert!(tier3_failure_match("error: could not compile `foo`"));
        assert!(tier3_failure_match(
            "error: process didn't exit successfully"
        ));
        assert!(tier3_failure_match("npm error something broke"));
        assert!(!tier3_failure_match("all tests passed"));
        assert!(!tier3_failure_match("failures: 0"));
        assert!(!tier3_failure_match("no errors here"));
    }
}
