// Unsafe is fenced at the crate boundary: an operation inside an `unsafe fn`
// needs its own block, and every unsafe block carries a `// SAFETY:` line, which
// `clippy -D warnings` enforces. The point is that a new block cannot land
// without the invariant it relies on being written down.
#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

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
//! | [`BackendKind::Cli`] | [`cli`] | Any CLI via a subprocess NDJSON bridge |
//!
//! Both process backends route their child's stderr through [`logtext`]: one
//! sanitized, bounded line at a time at `debug`, plus a bounded tail for a
//! failure message.
//!
//! Future: OpenAI-compatible HTTP, Anthropic, other harnesses (ACP, print mode).
//!
//! Each Godot bridge owns one private [`AiSession`]. A session keeps one
//! backend process alive across sequential prompts and exposes bounded,
//! correlated event envelopes for polling.

pub mod backend;
pub mod binary;
pub mod cli;
pub mod frame;
pub mod logtext;
pub mod mock;
pub mod omp;
pub mod prompt;
pub mod registry;
pub mod stream;
#[cfg(all(test, unix))]
pub(crate) mod test_temp_script;
pub mod types;

pub use backend::{BackendError, BackendInfo};
pub use binary::{GPTY_OMP_ENV, resolve_omp_binary, validate_omp_binary};
pub use cli::CliBackend;
pub use mock::MockBackend;
pub use omp::OmpBackend;
pub use registry::AiSession;
pub use types::{
    AiEvent, AiEventEnvelope, BackendKind, DEFAULT_INSPECTOR_SYSTEM_PROMPT, EventChannel,
    MAX_CAPTURE_BYTES, ObservationRequest, SessionOpenRequest, SessionPromptRequest,
};
