//! The suite's temp-path contract (v0.7.2): every test artifact lives inside a
//! guard that removes it when the test ends, so a full gate run leaves the
//! shared temp directory as it found it. The guard is `tempfile::TempDir`;
//! these pin the two properties the rest of the suite relies on — removal on
//! success, and removal while a failed assertion unwinds.

#[cfg(unix)]
mod unix {
    use std::os::unix::net::UnixListener;
    use std::panic::{AssertUnwindSafe, catch_unwind};

    use tempfile::TempDir;

    /// The path is unbindable once the test ends: a socket left behind keeps
    /// its inode until reboot, and a full `/tmp` eventually fails a spawn.
    #[test]
    fn the_guard_removes_a_bound_socket_on_success() {
        let path;
        {
            let tmp = TempDir::new().expect("a private temp directory");
            path = tmp.path().join("guard-success.sock");
            let listener = UnixListener::bind(&path).expect("bind");
            assert!(path.exists(), "the fixture needs the socket file to exist");
            drop(listener);
        }
        assert!(
            !path.exists(),
            "dropping the guard must remove the socket file"
        );
    }

    /// A panicking test unwinds through the guard too, which is what keeps a
    /// single failing assertion from leaking an artifact of every later run.
    #[test]
    fn the_guard_removes_a_bound_socket_when_the_test_panics() {
        let tmp = TempDir::new().expect("a private temp directory");
        let path = tmp.path().join("guard-panic.sock");
        let socket = path.clone();
        let panicked = catch_unwind(AssertUnwindSafe(move || {
            // Moved into the unwinding frame, so the guard drops mid-panic;
            // declared before the listener so it drops after it.
            let _guard = tmp;
            let _listener = UnixListener::bind(&socket).expect("bind");
            panic!("a failed assertion unwinds through the guard");
        }));
        assert!(panicked.is_err(), "the closure must have panicked");
        assert!(
            !path.exists(),
            "unwinding must still remove the socket file"
        );
    }
}
