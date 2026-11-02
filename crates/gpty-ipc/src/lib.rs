// Unsafe is fenced at the crate boundary: an operation inside an `unsafe fn`
// needs its own block, and every unsafe block carries a `// SAFETY:` line, which
// `clippy -D warnings` enforces. The point is that a new block cannot land
// without the invariant it relies on being written down.
#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

//! JSON-RPC 2.0 IPC transport for gpty.
//!
//! Provides the protocol types, Unix-domain / named-pipe transport,
//! an async server that dispatches requests to registered handlers,
//! and a client for connecting to a running gpty GUI instance.

pub mod client;
pub mod protocol;
pub mod server;
pub mod transport;

#[cfg(test)]
pub(crate) mod test_env;
