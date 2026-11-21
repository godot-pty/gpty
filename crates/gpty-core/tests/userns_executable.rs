//! An executable whose owner is outside this process's UID map must still run.
//!
//! Rootless Podman, `--userns=keep-id`, Flatpak and `unshare -Ur` all leave the
//! host's root unmapped, so the kernel reports the owner of `/bin/bash` as
//! `/proc/sys/fs/overflowuid` (65534, `nobody`) while `geteuid()` is the user.
//! The spawn gate trusted only "me" and root, so every terminal and `cli_view`
//! pane refused to start - and the GUT suite stopped at its first terminal
//! fixture, with `Cannot start the pane's shell: executable belongs to another
//! user (uid 65534): /bin/bash`.
//!
//! The test *is* the namespace runner: it re-execs this test binary under
//! `unshare -Ur` (which maps only this user to the namespace's root - exactly
//! the shape that hides host root) and asserts the in-namespace preconditions
//! before asserting the outcome, so a run that failed to enter a namespace
//! cannot pass by accident. It is an integration test rather than a unit test
//! because it re-execs its own harness; `unshare`/UID maps are Linux-only, so
//! every other platform compiles an empty binary here.

#![cfg(target_os = "linux")]

use std::path::Path;

/// Set for the re-executed run, so the inner half never spawns another one.
const INNER: &str = "GPTY_USERNS_INNER";
/// The test name the inner harness is filtered to.
const TEST: &str = "system_binary_owned_by_an_unmapped_root_is_accepted";
/// System binaries to judge, in preference order: the shell a pane spawns
/// first, then two that are regular files even where the shell is a symlink.
const CANDIDATES: [&str; 4] = ["/usr/bin/sh", "/bin/sh", "/usr/bin/true", "/bin/true"];

#[test]
fn system_binary_owned_by_an_unmapped_root_is_accepted() {
    if std::env::var_os(INNER).is_some() {
        verify_inside();
        return;
    }
    match std::process::Command::new("unshare")
        .args(["-Ur", "true"])
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => {
            eprintln!("SKIP: user namespaces unavailable ({status})");
            return;
        }
        Err(error) => {
            eprintln!("SKIP: user namespaces unavailable ({error})");
            return;
        }
    }
    let exe = std::env::current_exe().expect("test binary path");
    let status = std::process::Command::new("unshare")
        .args(["-Ur"])
        .arg(&exe)
        .args([TEST, "--exact", "--nocapture"])
        .env(INNER, "1")
        .status()
        .expect("re-exec the test binary under unshare");
    assert!(status.success(), "the in-namespace run must pass");
}

/// The namespace must leave the candidate's owner outside this process's UID
/// map before the spawn gate is allowed to accept it. Kept in its own
/// function so the uid comparison never shares a diagnostic sink with the
/// spawn outcome.
fn assert_owner_is_unmapped(path: &Path) {
    use std::os::unix::fs::MetadataExt;

    let meta = std::fs::metadata(path).expect("stat the candidate");
    // SAFETY: `geteuid` takes no arguments, cannot fail, and touches no memory;
    // the call is unsafe only because every libc extern is.
    let me = unsafe { libc::geteuid() };
    assert!(
        meta.uid() != me,
        "the namespace must leave the candidate's owner unmapped"
    );
    assert!(meta.uid() != 0, "an unmapped host root is not uid 0 here");
}

/// The inner half: prove the namespace really leaves the owner unmapped, then
/// prove the spawn gate accepts it - directly and through `PATH`.
fn verify_inside() {
    use std::os::unix::fs::MetadataExt;

    let path = CANDIDATES
        .iter()
        .map(Path::new)
        .find(|candidate| {
            std::fs::metadata(candidate)
                .is_ok_and(|meta| meta.is_file() && meta.mode() & 0o022 == 0)
        })
        .expect("a private system binary must exist to judge");
    assert_owner_is_unmapped(path);
    eprintln!(
        "user namespace: {} is owned by an unmapped uid (not the caller)",
        path.display()
    );
    gpty_core::pty::validate_executable(&path.to_string_lossy())
        .expect("a private system binary must be accepted in an unmapped-root namespace");
    gpty_core::pty::validate_program("sh", Some("/usr/bin:/bin"))
        .expect("a PATH-resolved system shell must be accepted");
}
