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

    /// How many times `what` is on the reported list. Every test below uses a
    /// name of its own, because `REPORTED` is process-wide and cargo runs the
    /// tests of one binary in parallel.
    fn reported(what: &str) -> usize {
        REPORTED
            .lock()
            .unwrap()
            .iter()
            .filter(|seen| **seen == what)
            .count()
    }

    /// Poison a lock the only way one can be poisoned: a holder that panics.
    fn poisoned_mutex() -> Arc<Mutex<i32>> {
        let mutex = Arc::new(Mutex::new(7));
        let poisoner = Arc::clone(&mutex);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().unwrap();
            panic!("holder dies");
        })
        .join();
        mutex
    }

    fn poisoned_rwlock() -> Arc<RwLock<i32>> {
        let lock = Arc::new(RwLock::new(7));
        let poisoner = Arc::clone(&lock);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.write().unwrap();
            panic!("writer dies");
        })
        .join();
        lock
    }

    #[test]
    fn a_poisoned_lock_is_skipped_instead_of_panicking() {
        let mutex = poisoned_mutex();
        assert!(
            lock_or_warn(&mutex, "lock test: skipped mutex").is_none(),
            "the caller must be able to skip instead of panicking"
        );
    }

    #[test]
    fn a_poisoned_lock_is_reported_once_however_often_it_is_hit() {
        let what = "lock test: reported once";
        let mutex = poisoned_mutex();
        assert_eq!(
            reported(what),
            0,
            "nothing is reported before the first hit"
        );
        for _ in 0..5 {
            assert!(lock_or_warn(&mutex, what).is_none());
        }
        assert_eq!(
            reported(what),
            1,
            "a per-frame call site must not flood the log: one report, five hits"
        );
    }

    #[test]
    fn each_distinct_lock_is_reported_separately() {
        let (a, b) = ("lock test: distinct a", "lock test: distinct b");
        let mutex = poisoned_mutex();
        assert!(lock_or_warn(&mutex, a).is_none());
        assert_eq!((reported(a), reported(b)), (1, 0));
        assert!(lock_or_warn(&mutex, b).is_none());
        assert_eq!(
            (reported(a), reported(b)),
            (1, 1),
            "the second name is not swallowed by the first's report"
        );
    }

    #[test]
    fn a_healthy_lock_is_handed_out_and_never_reported() {
        let what = "lock test: healthy";
        let mutex = Mutex::new(7);
        {
            let mut guard = lock_or_warn(&mutex, what).expect("a healthy lock is handed out");
            *guard += 1;
        }
        assert_eq!(*mutex.lock().unwrap(), 8, "the guard writes through");
        assert_eq!(reported(what), 0, "a healthy lock is not a diagnostic");
    }

    #[test]
    fn a_poisoned_rwlock_is_skipped_for_read_and_write_alike() {
        let (r, w) = ("lock test: rw read", "lock test: rw write");
        let lock = poisoned_rwlock();
        assert!(read_or_warn(&lock, r).is_none(), "read skips");
        assert!(write_or_warn(&lock, w).is_none(), "write skips");
        assert_eq!((reported(r), reported(w)), (1, 1), "and each is reported");
    }

    #[test]
    fn a_healthy_rwlock_is_handed_out_for_read_and_write() {
        let (r, w) = ("lock test: healthy read", "lock test: healthy write");
        let lock = RwLock::new(7);
        *write_or_warn(&lock, w).expect("write guard") += 1;
        assert_eq!(*read_or_warn(&lock, r).expect("read guard"), 8);
        assert_eq!((reported(r), reported(w)), (0, 0));
    }
}
