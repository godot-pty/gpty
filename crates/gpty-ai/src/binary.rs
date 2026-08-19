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

/// Absolute, regular, user-owned, not group/other-writable (Unix).
pub fn validate_omp_binary(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if !path.is_absolute() {
            return false;
        }
        let Ok(meta) = std::fs::metadata(path) else {
            return false;
        };
        meta.is_file() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o022 == 0
    }
    #[cfg(not(unix))]
    {
        path.is_absolute() && std::fs::metadata(path).is_ok_and(|m| m.is_file())
    }
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
}
