//! Feeds the CI build stamp into `gpty_core::BUILD_VERSION`.
//!
//! `env!` is not part of cargo's fingerprint, so without
//! `rerun-if-env-changed` a build restored from the release cache would keep
//! the previous night's stamp. The fallback keeps a local or tag build
//! identical to what it printed before this file existed.

fn main() {
    println!("cargo:rerun-if-env-changed=GPTY_BUILD_VERSION");
    let version = std::env::var("GPTY_BUILD_VERSION")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            std::env::var("CARGO_PKG_VERSION").expect("cargo always sets CARGO_PKG_VERSION")
        });
    println!("cargo:rustc-env=GPTY_BUILD_VERSION={version}");
}
