//! Resolve and validate the `omp` / Oh-My-Pi binary path.

use std::path::{Path, PathBuf};

/// Environment override for the omp binary (absolute path required).
pub const GPTY_OMP_ENV: &str = "GPTY_OMP";

/// Resolve `omp` from `GPTY_OMP` or `PATH`.
pub fn resolve_omp_binary() -> Option<PathBuf> {
    if let Ok(p) = std::env::var(GPTY_OMP_ENV) {
        let path = PathBuf::from(p.trim());
        if validate_omp_binary(&path) {
            return Some(path);
        }
        return None;
    }
    which("omp").filter(|p| validate_omp_binary(p))
}

/// Absolute, regular, and trusted by the one spawn-gate rule
/// ([`gpty_core::pty::validate_executable_file`]): not group/other-writable and
/// owned by this user, root, or a namespace's unmapped overflow UID. A
/// system-wide install (`/usr/bin/omp`, `/opt/...`, a container's nobody-owned
/// copy) is accepted - a user-owned copy only used to be.
///
/// The ancestor walk is deliberately not part of it: `GPTY_OMP` is the user's
/// own choice, and saved data never names this binary.
pub fn validate_omp_binary(path: &Path) -> bool {
    gpty_core::pty::validate_executable_file(path).is_ok()
}

fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            // Prefer absolute for validation.
            if let Ok(canon) = std::fs::canonicalize(&candidate) {
                return Some(canon);
            }
            if candidate.is_absolute() {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_path_rejected() {
        assert!(!validate_omp_binary(Path::new("omp")));
    }

    /// One rule, shared with the pane spawn gate: a private file passes, and a
    /// group/other-writable one is refused however it was named.
    #[cfg(unix)]
    #[test]
    fn the_file_rule_is_shared_with_the_pane_spawn_gate() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = tempfile::TempDir::new().expect("temp dir");
        let path = tmp.path().join("omp");
        std::fs::write(&path, b"#!/bin/sh\n").expect("write the probe");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(validate_omp_binary(&path));

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(
            !validate_omp_binary(&path),
            "a binary anyone can replace must not be spawned"
        );
    }
}
