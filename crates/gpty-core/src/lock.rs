//! Lock helpers.
//!
//! The workspace uses `std::sync::Mutex` everywhere and treats a poisoned
//! lock as "skip this piece of work, keep the app running": a pane whose grid
//! lock was poisoned by a panic on another thread must not take the UI thread
//! down with it, and a capture queue nobody can lock must not abort a
//! teardown. That policy is deliberate — but skipping *silently* made a
//! poisoned lock indistinguishable from a pane that had simply stopped
//! producing output, which is a debugging dead end.
//!
//! [`lock_or_warn`] is that skip path with the first occurrence of each lock
//! reported. It exists instead of adopting `parking_lot` (which has no
//! poisoning at all): staying on one lock type keeps the panic visible rather
//! than invisible, and `std`'s poisoning is the only thing that distinguishes
//! "never locked" from "locked by a thread that died".

use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Locks already reported, so a per-frame call site cannot flood the log.
static REPORTED: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());

/// Lock `mutex`, or report `what` and return `None` when it is poisoned.
///
/// `what` names the lock for the reader of the log ("pane grid", "capture
/// queue"); each distinct name is reported once per process.
pub fn lock_or_warn<'a, T>(mutex: &'a Mutex<T>, what: &'static str) -> Option<MutexGuard<'a, T>> {
    match mutex.lock() {
        Ok(guard) => Some(guard),
        Err(_) => {
            report_poison(what);
            None
        }
    }
}

/// Read `rwlock`, or report `what` and return `None` when it is poisoned.
///
/// Same policy as [`lock_or_warn`]: the caller skips the work instead of
/// panicking, which matters most in a pane's task, where a panic ends the
/// pane. The concept lock holds an immutable snapshot behind a poisoned
/// `RwLock` — the data is still intact, but recovering it silently would hide
/// that a thread died, so the caller takes the skip path and the log says why.
pub fn read_or_warn<'a, T>(
    rwlock: &'a RwLock<T>,
    what: &'static str,
) -> Option<RwLockReadGuard<'a, T>> {
    match rwlock.read() {
        Ok(guard) => Some(guard),
        Err(_) => {
            report_poison(what);
            None
        }
    }
}

/// Write `rwlock`, or report `what` and return `None` when it is poisoned.
pub fn write_or_warn<'a, T>(
    rwlock: &'a RwLock<T>,
    what: &'static str,
) -> Option<RwLockWriteGuard<'a, T>> {
    match rwlock.write() {
        Ok(guard) => Some(guard),
        Err(_) => {
            report_poison(what);
            None
        }
    }
}

fn report_poison(what: &'static str) {
    let Ok(mut seen) = REPORTED.lock() else {
        return;
    };
    if seen.contains(&what) {
        return;
    }
    seen.push(what);
    drop(seen);
    log::error!(
        "lock poisoned ({what}): a thread panicked while holding it, so the work it guards is being skipped"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn a_poisoned_lock_is_skipped_instead_of_panicking() {
        let mutex = Arc::new(Mutex::new(7));
        let poisoner = Arc::clone(&mutex);
        // Poison it the only way a lock can be poisoned.
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().unwrap();
            panic!("holder dies");
        })
        .join();

        assert!(
            lock_or_warn(&mutex, "test lock is absent").is_none(),
            "the caller must be able to skip instead of panicking"
        );
        // Reporting is idempotent: the second occurrence is not re-logged.
        assert!(lock_or_warn(&mutex, "test lock is absent").is_none());
    }

    #[test]
    fn a_healthy_lock_is_handed_out() {
        let mutex = Mutex::new(7);
        let guard = lock_or_warn(&mutex, "healthy test lock").expect("lock");
        assert_eq!(*guard, 7);
    }
}
