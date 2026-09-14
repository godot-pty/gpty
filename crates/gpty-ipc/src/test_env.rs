//! Process-global environment guard shared by test modules that touch
//! `std::env`.
//!
//! Cargo runs one binary's tests on parallel threads, and the environment is
//! process-global: an unlocked set/remove pair races every other test reading
//! the same variable (a real `ci-check` parallel run failed this way). Every
//! module that mutates the environment in tests goes through this lock, and
//! the guards restore the previous value on drop — including on panic, so a
//! failing test cannot leak its value into the rest of the run. (AGENTS.md:
//! shared static state in integration tests.)

use std::sync::{LazyLock, Mutex, MutexGuard};

static LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

pub(crate) fn lock() -> MutexGuard<'static, ()> {
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Sets or clears one environment variable while holding the shared lock,
/// restoring the previous value on drop.
pub(crate) struct EnvVar {
    key: &'static str,
    previous: Option<std::ffi::OsString>,
    _lock: MutexGuard<'static, ()>,
}

impl EnvVar {
    pub(crate) fn set(key: &'static str, value: impl AsRef<std::ffi::OsStr>) -> Self {
        let lock = lock();
        let previous = std::env::var_os(key);
        // SAFETY: the lock makes this the only test touching the variable,
        // and the guard restores it on drop.
        unsafe { std::env::set_var(key, value) };
        Self {
            key,
            previous,
            _lock: lock,
        }
    }

    pub(crate) fn clear(key: &'static str) -> Self {
        let lock = lock();
        let previous = std::env::var_os(key);
        // SAFETY: as in `set`.
        unsafe { std::env::remove_var(key) };
        Self {
            key,
            previous,
            _lock: lock,
        }
    }
}

impl Drop for EnvVar {
    fn drop(&mut self) {
        match self.previous.take() {
            Some(previous) => unsafe { std::env::set_var(self.key, previous) },
            None => unsafe { std::env::remove_var(self.key) },
        }
    }
}

/// The same guard for a test that needs several variables at once: taking two
/// [`EnvVar`]s deadlocks on the shared lock (it did — the whole `xdg` module
/// hung), so the variables one resolution reads are set together.
pub(crate) struct EnvVars {
    previous: Vec<(&'static str, Option<std::ffi::OsString>)>,
    _lock: MutexGuard<'static, ()>,
}

impl EnvVars {
    /// Set or clear each variable under one guard; `None` clears a key.
    pub(crate) fn apply(changes: &[(&'static str, Option<&str>)]) -> Self {
        let lock = lock();
        let mut previous = Vec::with_capacity(changes.len());
        for (key, value) in changes {
            previous.push((*key, std::env::var_os(key)));
            // SAFETY: the guard makes this the only test touching these
            // variables, and it restores them on drop.
            unsafe {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
        }
        Self {
            previous,
            _lock: lock,
        }
    }
}

impl Drop for EnvVars {
    fn drop(&mut self) {
        for (key, previous) in self.previous.drain(..) {
            match previous {
                Some(previous) => unsafe { std::env::set_var(key, previous) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }
}
