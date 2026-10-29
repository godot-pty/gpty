//! Windows-only: the process DACL that [`gpty_core::hardening`] installs must
//! withhold memory access while keeping the rights the app itself needs.
//!
//! This is an integration test, not a unit test, on purpose: hardening changes
//! the process-wide DACL, so a unit test inside the library target would change
//! it for every other unit test sharing that process. Cargo gives each
//! integration-test file its own binary, so this test starts from a normal
//! (unhardened) process and its change dies with the process.
//!
//! Run by the `rust-windows` CI job:
//! `cargo test -p gpty-core --test windows_hardening`.

#![cfg(windows)]

use core::ffi::c_void;

use gpty_core::hardening::{ALLOW_DEBUG_ENV, harden_process};

const PROCESS_TERMINATE: u32 = 0x0000_0001;
const PROCESS_VM_READ: u32 = 0x0000_0010;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x0000_1000;
const ERROR_ACCESS_DENIED: i32 = 5;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn OpenProcess(desired_access: u32, inherit_handle: i32, process_id: u32) -> *mut c_void;
    fn GetCurrentProcessId() -> u32;
    fn CloseHandle(handle: *mut c_void) -> i32;
}

/// Open this process the way another same-user process would. A refusal comes
/// back as the Win32 error code, so the test can tell an access check from any
/// other failure.
fn open_current(access: u32) -> Result<*mut c_void, i32> {
    // SAFETY: both calls take and return plain values; a returned handle is
    // closed by the caller.
    let handle = unsafe { OpenProcess(access, 0, GetCurrentProcessId()) };
    if handle.is_null() {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(0))
    } else {
        Ok(handle)
    }
}

#[test]
fn hardening_withholds_memory_access_but_keeps_identity_and_terminate() {
    assert!(
        std::env::var_os(ALLOW_DEBUG_ENV).is_none(),
        "unset {ALLOW_DEBUG_ENV} to run this test: the opt-out is exactly what it disables"
    );

    // The before state: a process's default DACL grants the signed-in user
    // memory access, which is how a program in a pane reads the GUI's
    // environment. If this open failed, the assertion below could not tell
    // hardening from a broken probe.
    let before = open_current(PROCESS_VM_READ)
        .expect("the default DACL must grant the owner PROCESS_VM_READ");
    // SAFETY: `before` is a live handle from `OpenProcess`, closed once here.
    unsafe { CloseHandle(before) };

    harden_process().expect("installing the process DACL must succeed");

    match open_current(PROCESS_VM_READ) {
        Ok(handle) => {
            // SAFETY: a live handle, closed once before the assertion fails.
            unsafe { CloseHandle(handle) };
            panic!("a hardened process must refuse PROCESS_VM_READ");
        }
        Err(code) => assert_eq!(
            code, ERROR_ACCESS_DENIED,
            "the refusal must be the access check, not another failure"
        ),
    }

    // The control socket's peer check opens a client with exactly this mask;
    // losing it would make the GUI reject every command from a hardened CLI.
    let query = open_current(PROCESS_QUERY_LIMITED_INFORMATION)
        .expect("a hardened process must keep PROCESS_QUERY_LIMITED_INFORMATION");
    // SAFETY: a live handle from `OpenProcess`, closed once here.
    unsafe { CloseHandle(query) };

    // Task Manager's End task needs this one, so a hung GUI stays endable.
    let terminate =
        open_current(PROCESS_TERMINATE).expect("a hardened process must keep PROCESS_TERMINATE");
    // SAFETY: a live handle from `OpenProcess`, closed once here.
    unsafe { CloseHandle(terminate) };
}
