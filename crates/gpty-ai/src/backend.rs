//! Common backend errors and metadata.

use crate::types::BackendKind;

#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl BackendError {
    /// True when the child's pipe is gone: it exited (or is exiting) between
    /// the caller's liveness probe and the write to its stdin. Only meaningful
    /// for a backend that talks to a child process over pipes.
    pub(crate) fn is_child_gone(&self) -> bool {
        matches!(self, Self::Io(error) if error.kind() == std::io::ErrorKind::BrokenPipe)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendInfo {
    pub kind: BackendKind,
    pub name: &'static str,
    pub available: bool,
}
