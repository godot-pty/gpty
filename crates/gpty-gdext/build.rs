//! Link the GDExtension with a loader path relative to its own file.
//!
//! Release bundles ship the pinned FFmpeg libraries beside the extension
//! (`scripts/media-deps` builds them), so the library must find its own
//! directory before the system's FFmpeg — whose soname changes with every
//! distro release. The system libraries remain the fallback for a dev build
//! that has no bundle beside it.

fn main() {
    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path");
}
