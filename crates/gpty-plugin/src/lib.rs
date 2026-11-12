//! Installed-plugin state shared by the CLI and the GDExtension.
//!
//! [`store`] owns `state_dir()/plugins.json` and the per-plugin content and
//! runtime directories. [`schema`] holds the caps the manifest validator and
//! the store both enforce, so the reader, the writer, and the install gate
//! cannot drift apart.

pub mod schema;
pub mod store;
