//! # gpty-ai
//!
//! Pluggable AI backends for gpty's Inspector pane.
//!
//! ## Backends
//!
//! | Kind | Crate module | Role |
//! |------|--------------|------|
//! | [`BackendKind::Mock`] | [`mock`] | Offline / tests — deterministic Markdown |
//! | [`BackendKind::Omp`] | [`omp`] | Oh-My-Pi via `omp --mode rpc` |
//!
//! Future: OpenAI-compatible HTTP, Anthropic, other harnesses (ACP, print mode).
//!
//! Each Godot bridge owns one private [`AiSession`]. A session keeps one
//! backend process alive across sequential prompts and exposes bounded,
//! correlated event envelopes for polling.

pub mod backend;
pub mod binary;
pub mod mock;
pub mod omp;
pub mod prompt;
pub mod registry;
pub mod stream;
pub mod types;

pub use backend::{BackendError, BackendInfo};
pub use binary::{GPTY_OMP_ENV, resolve_omp_binary, validate_omp_binary};
pub use mock::MockBackend;
pub use omp::OmpBackend;
pub use registry::AiSession;
pub use types::{
    AiEvent, AiEventEnvelope, BackendKind, DEFAULT_INSPECTOR_SYSTEM_PROMPT, EventChannel,
    MAX_CAPTURE_BYTES, ObservationRequest, SessionOpenRequest, SessionPromptRequest,
};
