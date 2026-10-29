//! Keeping gPTY's own credentials out of reach of the programs it runs.
//!
//! The GUI and the CLI can hold `GPTY_SECRET`, the control socket's shared
//! secret. A pane's shell is a *child* of the GUI and runs as the same user,
//! so the kernel's rules — not file permissions — decide whether that shell
//! can read the parent's environment:
//!
//! - **Linux**: `/proc/<pid>/environ`, `/proc/<pid>/mem` and `/proc/<pid>/maps`
//!   are readable by the owner only while the target process is dumpable, and
//!   same-user `ptrace` is refused once it is not.
//! - **Windows**: there is no path to another process's environment; it is read
//!   out of the target's PEB with `ReadProcessMemory`, which needs a handle
//!   with `PROCESS_VM_READ`. A process's default DACL grants the signed-in
//!   user that right, so gPTY installs a DACL that does not.
//! - **macOS**: exposed through `KERN_PROCARGS2` (`ps -E`, `pgrep`) to any
//!   same-user reader whether or not tracing is denied; no mechanism is wired.
//!
//! [`harden_process`] applies the platform's mechanism once at startup.
//! Measured on Linux (2026-10-29): a process that clears the bit has its
//! `/proc/<pid>/environ` and `maps` become root-owned, an exec'd child's read
//! fails with `EACCES`, while that child — a separate `exec`ed program, and
//! the programs it starts — returns to dumpable and stays debuggable. That is
//! the property gPTY wants:
//!
//! - programs in panes cannot recover the secret from the GUI's (or a client's)
//!   environment, so with `GPTY_SECRET` set they cannot authenticate to the
//!   control socket;
//! - a user can still attach a debugger to their own shell and programs.
//!
//! The Windows DACL is the same trade with the platform's own currency: it
//! withholds `PROCESS_VM_READ`, `PROCESS_VM_WRITE`, `PROCESS_VM_OPERATION` and
//! `PROCESS_CREATE_THREAD` from the user, while keeping identity
//! (`PROCESS_QUERY_LIMITED_INFORMATION`, which the socket's peer check needs),
//! termination (a hung GUI can still be ended), synchronization and
//! `READ_CONTROL`. Exactly one ACE is installed, for the process owner: a
//! SYSTEM process holds `SeDebugPrivilege`, and a blanket SYSTEM ACE would
//! re-grant full access whenever gPTY itself runs as SYSTEM (the owner would
//! then match it, and the hardening would be a no-op).
//!
//! A process that *enables* `SeDebugPrivilege` overrides any process DACL;
//! that is an elevated debugger, not a normal pane, and is outside what a DACL
//! can promise - the Windows test and the smoke probe drop the privilege so
//! they model the same-user case the guard is for.
//!
//! ## Cost, and the opt-out
//!
//! A non-dumpable process on Linux produces no core dump and cannot be
//! attached to by a same-user debugger or profiler; a hardened process on
//! Windows cannot be opened for memory reads by the same user either. Set
//! [`ALLOW_DEBUG_ENV`] to a truthy value (`1`/`true`/`yes`/`on`) before
//! launching gPTY to skip the marking — a developer debugging the GUI or the
//! CLI, not a normal user.
//!
//! ## Platform status
//!
//! Linux (and Android) uses the dumpable bit; Windows uses the process DACL;
//! macOS has no wired mechanism, which is recorded in SECURITY.md and the
//! roadmap rather than implied. A failed call is a diagnostic the caller logs
//! and continues past — the process still works, it is only as exposed as it
//! was before.

use std::io;

/// Set this to a truthy value to keep the process dumpable (developers only).
///
/// This is an escape hatch for debugging gPTY itself: with it set, the GUI and
/// the CLI skip [`harden_process`], and a pane's programs can again read their
/// environment. It does not grant a pane anything it could not already do
/// without a secret set.
pub const ALLOW_DEBUG_ENV: &str = "GPTY_ALLOW_DEBUG";

/// Mark this process so same-user processes cannot read its memory or
/// environment. Idempotent.
///
/// Call this once at startup, from the process's main thread, before any
/// long-lived work: the GUI's GDExtension init and the CLI's `main`. A
/// failure is a diagnostic the caller logs and continues past - never a
/// reason to refuse to start, because the process still works, it is only as
/// exposed as it was before this call. On a platform with no mechanism (see
/// the module docs) this is `Ok(())` and makes no claim.
pub fn harden_process() -> io::Result<()> {
    if opt_out_requested(std::env::var(ALLOW_DEBUG_ENV).ok().as_deref()) {
        return Ok(());
    }
    harden_now()
}

/// Whether `value` (the opt-out variable's contents) asks to stay debuggable.
///
/// Only a truthy value counts: `GPTY_ALLOW_DEBUG=` or `0` leaves the
/// hardening on, so a shell that exports the variable as an empty or numeric
/// flag cannot silently disable it.
fn opt_out_requested(value: Option<&str>) -> bool {
    value.map(str::trim).is_some_and(|v| {
        v.eq_ignore_ascii_case("1")
            || v.eq_ignore_ascii_case("true")
            || v.eq_ignore_ascii_case("yes")
            || v.eq_ignore_ascii_case("on")
    })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn harden_now() -> io::Result<()> {
    // SAFETY: `prctl` takes plain integers; PR_SET_DUMPABLE's other argument
    // is ignored. The call changes only this process's dumpable attribute.
    let rc = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if rc == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(windows)]
fn harden_now() -> io::Result<()> {
    windows::harden_process()
}

#[cfg(not(any(target_os = "linux", target_os = "android", windows)))]
fn harden_now() -> io::Result<()> {
    Ok(())
}

/// The Windows access mask, split out of the syscall module so the policy can
/// be tested on every platform: these numbers are the security decision.
#[cfg(any(windows, test))]
mod windows_policy {
    pub const PROCESS_TERMINATE: u32 = 0x0000_0001;
    pub const PROCESS_CREATE_THREAD: u32 = 0x0000_0002;
    pub const PROCESS_VM_READ: u32 = 0x0000_0010;
    pub const PROCESS_VM_WRITE: u32 = 0x0000_0020;
    pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x0000_1000;
    pub const SYNCHRONIZE: u32 = 0x0010_0000;
    pub const READ_CONTROL: u32 = 0x0002_0000;

    /// What the signed-in user keeps on a hardened process. `PROCESS_VM_READ`
    /// is what reads the PEB's environment block; `PROCESS_VM_WRITE` +
    /// `PROCESS_CREATE_THREAD` are what injects code; `PROCESS_VM_OPERATION`
    /// is not granted either. `PROCESS_QUERY_LIMITED_INFORMATION` is the mask
    /// the control socket's peer check opens a client with, so a hardened CLI
    /// must keep it or the GUI would reject every command.
    pub const USER_ACCESS: u32 =
        PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE | READ_CONTROL;

    /// Rights the user must not have on a hardened process.
    pub const WITHHELD_ACCESS: u32 = PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_CREATE_THREAD;

    // The policy is a compile-time invariant, not a convention: a future edit
    // that adds a memory right to `USER_ACCESS` fails the build.
    const _: () = assert!(
        USER_ACCESS & WITHHELD_ACCESS == 0,
        "a hardened Windows process must not grant memory or thread-injection access"
    );
}

#[cfg(windows)]
mod windows {
    use core::ffi::c_void;
    use std::io;

    use super::windows_policy::USER_ACCESS;

    const SE_KERNEL_OBJECT: u32 = 6;
    const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
    const TOKEN_QUERY: u32 = 0x0000_0008;
    const TOKEN_USER_CLASS: u32 = 1;
    const ACL_REVISION: u32 = 2;
    /// `SECURITY_MAX_SID_SIZE` from `winnt.h`: the largest legal SID, in bytes.
    const SECURITY_MAX_SID_SIZE: usize = 68;
    /// `sizeof(ACL)` from `winnt.h`.
    const ACL_HEADER_BYTES: usize = 8;
    /// `sizeof(ACCESS_ALLOWED_ACE)` from `winnt.h`, including its inline
    /// `SidStart` DWORD (which is counted again as the SID's first word).
    const ACCESS_ALLOWED_ACE_BYTES: usize = 12;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn CloseHandle(handle: *mut c_void) -> i32;
    }

    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> i32;
        fn GetTokenInformation(
            token: *mut c_void,
            class: u32,
            info: *mut c_void,
            info_len: u32,
            returned_len: *mut u32,
        ) -> i32;
        fn InitializeAcl(acl: *mut c_void, acl_len: u32, acl_revision: u32) -> i32;
        fn AddAccessAllowedAce(
            acl: *mut c_void,
            ace_revision: u32,
            access_mask: u32,
            sid: *mut c_void,
        ) -> i32;
        fn SetSecurityInfo(
            object: *mut c_void,
            object_type: u32,
            security_info: u32,
            owner: *mut c_void,
            group: *mut c_void,
            dacl: *mut c_void,
            sacl: *mut c_void,
        ) -> u32;
    }

    /// Replace this process's DACL with one that gives the user its normal
    /// identity and termination rights but no way to read its memory.
    pub(super) fn harden_process() -> io::Result<()> {
        // `TOKEN_USER` holds a pointer to the SID inside this buffer; it must
        // outlive the `AddAccessAllowedAce` calls below. `Vec<usize>` keeps
        // the buffer pointer-aligned for that first field.
        let (token_user, user_sid) = user_sid()?;

        // One `ACL` header and one ACE, for the process owner. SIDs are
        // DWORD-aligned, so `Vec<u32>` gives the ACL APIs the alignment they
        // document; `AddAccessAllowedAce` fills in the ACE's size.
        let acl_bytes = ACL_HEADER_BYTES
            + (ACCESS_ALLOWED_ACE_BYTES - size_of::<u32>() + SECURITY_MAX_SID_SIZE);
        let mut acl_buffer = vec![0u32; acl_bytes.div_ceil(size_of::<u32>())];
        let acl = acl_buffer.as_mut_ptr().cast::<c_void>();
        let acl_len = (acl_buffer.len() * size_of::<u32>()) as u32;

        // SAFETY: `acl` points at `acl_len` writable bytes, DWORD-aligned.
        if unsafe { InitializeAcl(acl, acl_len, ACL_REVISION) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the ACL has room for the ACE, and `user_sid` is valid and
        // outlives this call (it points inside `token_user`).
        let user_ace = unsafe { AddAccessAllowedAce(acl, ACL_REVISION, USER_ACCESS, user_sid) };
        // The ACE copies its SID, so the token buffer is no longer needed.
        drop(token_user);
        if user_ace == 0 {
            return Err(io::Error::last_os_error());
        }

        // SAFETY: the pseudo-handle designates this process with full access,
        // which is what writing the DACL requires; `acl` lives until after the
        // call. SetSecurityInfo reports a Win32 error code directly.
        let status = unsafe {
            SetSecurityInfo(
                GetCurrentProcess(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                acl,
                core::ptr::null_mut(),
            )
        };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        Ok(())
    }

    /// This process's user SID, returned with the buffer that holds it.
    ///
    /// `TOKEN_USER` is a `SID_AND_ATTRIBUTES`, so the SID pointer is the first
    /// machine word of the returned buffer — the buffer must outlive the
    /// pointer, which is why both are handed back together.
    fn user_sid() -> io::Result<(Vec<usize>, *mut c_void)> {
        let mut token: *mut c_void = core::ptr::null_mut();
        // SAFETY: `token` is an out-pointer this function owns.
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }

        // First call sizes the buffer, the second fills it. A zero-sized
        // answer means the query itself failed, not that a zero-length token
        // is valid.
        let mut needed: u32 = 0;
        // SAFETY: a sizing query with no output buffer, as the API documents.
        unsafe {
            GetTokenInformation(
                token,
                TOKEN_USER_CLASS,
                core::ptr::null_mut(),
                0,
                &mut needed,
            )
        };
        if needed == 0 {
            // SAFETY: `token` was opened above and is closed exactly once.
            unsafe { CloseHandle(token) };
            return Err(io::Error::last_os_error());
        }

        let mut buffer = vec![0usize; (needed as usize).div_ceil(size_of::<usize>())];
        // SAFETY: the buffer is at least `needed` bytes and pointer-aligned.
        let ok = unsafe {
            GetTokenInformation(
                token,
                TOKEN_USER_CLASS,
                buffer.as_mut_ptr().cast::<c_void>(),
                needed,
                &mut needed,
            )
        };
        // SAFETY: `token` was opened above and is closed exactly once.
        unsafe { CloseHandle(token) };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the query filled the buffer with a TOKEN_USER whose first
        // field is the SID pointer.
        let sid = buffer[0] as *mut c_void;
        if sid.is_null() {
            return Err(io::Error::other("the process token has no user SID"));
        }
        Ok((buffer, sid))
    }
}

#[cfg(test)]
mod tests {
    use super::{ALLOW_DEBUG_ENV, opt_out_requested};

    #[test]
    fn only_a_truthy_opt_out_disables_the_hardening() {
        for value in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            assert!(opt_out_requested(Some(value)), "{value:?} must opt out");
        }
        for value in [
            None,
            Some(""),
            Some("0"),
            Some("false"),
            Some("no"),
            Some("off"),
        ] {
            assert!(
                !opt_out_requested(value),
                "{value:?} must keep the hardening on"
            );
        }
        assert_eq!(ALLOW_DEBUG_ENV, "GPTY_ALLOW_DEBUG");
    }

    /// The Windows policy, tested on every platform because the masks are the
    /// security decision: the user keeps identity and termination, never a way
    /// to read or write the process's memory.
    #[test]
    fn the_windows_user_mask_keeps_identity_and_terminate_but_withholds_memory() {
        use super::windows_policy::{
            PROCESS_CREATE_THREAD, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
            PROCESS_VM_READ, PROCESS_VM_WRITE, READ_CONTROL, SYNCHRONIZE, USER_ACCESS,
            WITHHELD_ACCESS,
        };

        assert_eq!(
            WITHHELD_ACCESS,
            PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_CREATE_THREAD
        );
        for withheld in [PROCESS_VM_READ, PROCESS_VM_WRITE, PROCESS_CREATE_THREAD] {
            assert_eq!(
                USER_ACCESS & withheld,
                0,
                "right 0x{withheld:04X} must be withheld"
            );
        }
        for kept in [
            PROCESS_QUERY_LIMITED_INFORMATION,
            PROCESS_TERMINATE,
            SYNCHRONIZE,
            READ_CONTROL,
        ] {
            assert_ne!(USER_ACCESS & kept, 0, "right 0x{kept:04X} must be kept");
        }
    }

    /// The mechanism itself: clearing the bit is observable, and the test
    /// restores it so the shared test process is left debuggable
    /// (`PR_SET_DUMPABLE` is process-wide, and cargo runs tests on threads).
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn hardening_clears_the_dumpable_bit_and_is_restorable() {
        use std::sync::{Mutex, MutexGuard};

        static LOCK: Mutex<()> = Mutex::new(());

        struct Restore(i32);
        impl Drop for Restore {
            fn drop(&mut self) {
                // SAFETY: restoring the value read at test entry.
                unsafe {
                    libc::prctl(libc::PR_SET_DUMPABLE, self.0, 0, 0, 0);
                }
            }
        }

        fn dumpable() -> i32 {
            // SAFETY: PR_GET_DUMPABLE ignores the remaining arguments.
            unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) }
        }

        let _guard: MutexGuard<()> = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _restore = Restore(dumpable());

        super::harden_now().expect("PR_SET_DUMPABLE must succeed in the test sandbox");
        assert_eq!(dumpable(), 0);
        // Idempotent, which is what lets every startup path call it.
        super::harden_now().expect("a second call must succeed too");
        assert_eq!(dumpable(), 0);
    }
}
