//! JSON-RPC 2.0 IPC transport for gpty.
//!
//! Provides the protocol types, Unix-domain / named-pipe transport,
//! an async server that dispatches requests to registered handlers,
//! and a client for connecting to a running gpty GUI instance.

pub mod client;
pub mod protocol;
pub mod server;
pub mod transport;
pub mod types;
