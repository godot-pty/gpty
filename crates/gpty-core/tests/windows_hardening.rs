//! Windows-only: the process DACL that [`gpty_core::hardening`] installs must
//! withhold memory access while keeping the rights the app itself needs.
//!
//! This is an integration test, not a unit test, on purpose: hardening changes
//! the process-wide DACL, so a unit test inside the library target would change
//! it for every other unit test sharing that process. Cargo gives each
//! integration-test file its own binary, so this test starts from a normal
//! (unhardened) process and its change dies with the process.
//!
//! Two things are deliberately modelled:
//! - **The opener is a normal same-user process.** A process that *enables*
//!   `SeDebugPrivilege` can open any process regardless of its DACL, so the
//!   test drops that privilege first; it reports the state it found.
//! - **The DACL is checked independently of the access probe.** `GetSecurityInfo`
//!   reads the installed ACL back and asserts the owner ACE withholds memory
//!   and thread-injection rights, even if a privileged opener could still get
//!   through.
//!
//! Run by the `rust-windows` CI job:
//! `cargo test -p gpty-core --test windows_hardening`.

#![cfg(windows)]

use core::ffi::c_void;
use core::ptr::null_mut;

use gpty_core::hardening::{ALLOW_DEBUG_ENV, harden_process};

const PROCESS_TERMINATE: u32 = 0x0000_0001;
const PROCESS_CREATE_THREAD: u32 = 0x0000_0002;
const PROCESS_VM_READ: u32 = 0x0000_0010;
const PROCESS_VM_WRITE: u32 = 0x0000_0020;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x0000_1000;
const ERROR_ACCESS_DENIED: i32 = 5;

const TOKEN_QUERY: u32 = 0x0000_0008;
const TOKEN_ADJUST_PRIVILEGES: u32 = 0x0000_0020;
const TOKEN_USER_CLASS: u32 = 1;
const TOKEN_PRIVILEGES_CLASS: u32 = 3;
const SE_PRIVILEGE_ENABLED: u32 = 0x0000_0002;
const ERROR_NOT_ALL_ASSIGNED: i32 = 1300;

const SE_KERNEL_OBJECT: u32 = 6;
const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn OpenProcess(desired_access: u32, inherit_handle: i32, process_id: u32) -> *mut c_void;
    fn GetCurrentProcess() -> *mut c_void;
    fn GetCurrentProcessId() -> u32;
    fn CloseHandle(handle: *mut c_void) -> i32;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
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
    fn LookupPrivilegeValueW(system: *const u16, name: *const u16, luid: *mut u64) -> i32;
    fn AdjustTokenPrivileges(
        token: *mut c_void,
        disable_all: i32,
        new_state: *const u8,
        buffer_len: u32,
        previous: *mut c_void,
        return_len: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: *mut c_void, string: *mut *mut u16) -> i32;
    fn GetSecurityInfo(
        handle: *mut c_void,
        object_type: u32,
        security_info: u32,
        owner: *mut *mut c_void,
        group: *mut *mut c_void,
        dacl: *mut *mut c_void,
        sacl: *mut *mut c_void,
        descriptor: *mut *mut c_void,
    ) -> u32;
    fn GetAce(acl: *mut c_void, index: u32, ace: *mut *mut c_void) -> i32;
    fn EqualSid(a: *mut c_void, b: *mut c_void) -> i32;
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

fn last_error() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

fn open_token() -> *mut c_void {
    let mut token: *mut c_void = null_mut();
    // SAFETY: `token` is an out-pointer this function owns.
    let ok = unsafe {
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
            &mut token,
        )
    };
    assert_ne!(ok, 0, "OpenProcessToken must succeed for the test token");
    token
}

/// The token's user SID, returned with the buffer that holds it.
fn token_user_sid(token: *mut c_void) -> (Vec<usize>, *mut c_void) {
    let mut needed: u32 = 0;
    // SAFETY: a sizing query with no output buffer.
    unsafe { GetTokenInformation(token, TOKEN_USER_CLASS, null_mut(), 0, &mut needed) };
    assert_ne!(needed, 0, "sizing the token user must succeed");
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
    assert_ne!(ok, 0, "reading the token user must succeed");
    // SAFETY: TOKEN_USER's first field is the user SID pointer.
    let sid = buffer[0] as *mut c_void;
    assert!(!sid.is_null(), "the token must name a user SID");
    (buffer, sid)
}

fn sid_text(sid: *mut c_void) -> String {
    let mut text: *mut u16 = null_mut();
    // SAFETY: the SID is valid; `text` is an out-pointer this function frees.
    let ok = unsafe { ConvertSidToStringSidW(sid, &mut text) };
    if ok == 0 || text.is_null() {
        return "?".to_string();
    }
    // SAFETY: the API wrote a NUL-terminated UTF-16 string.
    let len = unsafe {
        let mut len = 0;
        while *text.add(len) != 0 {
            len += 1;
        }
        len
    };
    // SAFETY: `text` holds `len` readable UTF-16 units.
    let value = String::from_utf16_lossy(unsafe { core::slice::from_raw_parts(text, len) });
    // SAFETY: the API allocated `text` with LocalAlloc; LocalFree releases it.
    unsafe { LocalFree(text.cast::<c_void>()) };
    value
}

fn debug_privilege_luid() -> u64 {
    let name: Vec<u16> = "SeDebugPrivilege\0".encode_utf16().collect();
    let mut luid: u64 = 0;
    // SAFETY: the name is NUL-terminated; `luid` is an 8-byte out-value.
    let ok = unsafe { LookupPrivilegeValueW(null_mut(), name.as_ptr(), &mut luid) };
    assert_ne!(ok, 0, "SeDebugPrivilege must exist on Windows");
    luid
}

/// Whether the token holds SeDebugPrivilege, and whether it is enabled.
fn debug_privilege_state(token: *mut c_void, luid: u64) -> &'static str {
    let mut needed: u32 = 0;
    // SAFETY: a sizing query with no output buffer.
    unsafe { GetTokenInformation(token, TOKEN_PRIVILEGES_CLASS, null_mut(), 0, &mut needed) };
    if needed == 0 {
        return "UNKNOWN";
    }
    let mut buffer = vec![0u8; needed as usize];
    // SAFETY: the buffer is `needed` bytes.
    let ok = unsafe {
        GetTokenInformation(
            token,
            TOKEN_PRIVILEGES_CLASS,
            buffer.as_mut_ptr().cast::<c_void>(),
            needed,
            &mut needed,
        )
    };
    if ok == 0 || buffer.len() < 4 {
        return "UNKNOWN";
    }
    let count = u32::from_le_bytes(buffer[0..4].try_into().unwrap());
    for index in 0..count as usize {
        // TOKEN_PRIVILEGES: DWORD count, then LUID_AND_ATTRIBUTES (8 + 4).
        let offset = 4 + index * 12;
        if offset + 12 > buffer.len() {
            break;
        }
        let entry_luid = u64::from_le_bytes(buffer[offset..offset + 8].try_into().unwrap());
        if entry_luid == luid {
            let attributes =
                u32::from_le_bytes(buffer[offset + 8..offset + 12].try_into().unwrap());
            return if attributes & SE_PRIVILEGE_ENABLED != 0 {
                "ENABLED"
            } else {
                "DISABLED"
            };
        }
    }
    "ABSENT"
}

/// Turn SeDebugPrivilege off in this process's token. A normal pane process
/// does not have it enabled; an enabled privilege overrides any process DACL.
fn disable_debug_privilege(token: *mut c_void, luid: u64) {
    // TOKEN_PRIVILEGES: count = 1, one LUID_AND_ATTRIBUTES with attributes 0.
    let mut state = [0u8; 16];
    state[0..4].copy_from_slice(&1u32.to_le_bytes());
    state[4..12].copy_from_slice(&luid.to_le_bytes());
    state[12..16].copy_from_slice(&0u32.to_le_bytes());
    // SAFETY: `state` is a valid TOKEN_PRIVILEGES buffer.
    let ok = unsafe { AdjustTokenPrivileges(token, 0, state.as_ptr(), 0, null_mut(), null_mut()) };
    assert_ne!(ok, 0, "AdjustTokenPrivileges must succeed");
    let error = last_error();
    assert!(
        error == 0 || error == ERROR_NOT_ALL_ASSIGNED,
        "unexpected AdjustTokenPrivileges error {error}"
    );
}

/// Read the installed DACL back and assert the owner ACE withholds the rights
/// a memory read or code injection needs.
fn assert_owner_ace_withholds_memory(user_sid: *mut c_void) {
    let mut dacl: *mut c_void = null_mut();
    let mut descriptor: *mut c_void = null_mut();
    // SAFETY: the DACL and descriptor are out-pointers this function frees.
    let status = unsafe {
        GetSecurityInfo(
            GetCurrentProcess(),
            SE_KERNEL_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    };
    assert_eq!(status, 0, "GetSecurityInfo must succeed");
    assert!(
        !dacl.is_null(),
        "the process must have a DACL after hardening"
    );
    // ACL: revision, sbz1, size (u16), ace count (u16 at offset 4), sbz2.
    // SAFETY: `dacl` points at a readable ACL.
    let ace_count =
        u16::from_le_bytes(unsafe { [*(dacl as *const u8).add(4), *(dacl as *const u8).add(5)] })
            as u32;
    println!("DACL_ACES={ace_count}");
    assert_eq!(
        ace_count, 1,
        "the DACL must be the owner's single ACE, with no blanket SYSTEM grant"
    );

    let mut found_owner = false;
    for index in 0..ace_count {
        let mut ace: *mut c_void = null_mut();
        // SAFETY: the index is below the ACL's ACE count.
        assert_ne!(
            unsafe { GetAce(dacl, index, &mut ace) },
            0,
            "GetAce must succeed"
        );
        let bytes = ace as *const u8;
        // SAFETY: the ACE header is at least 8 bytes (Header + AccessMask).
        let ace_type = unsafe { *bytes };
        if ace_type != ACCESS_ALLOWED_ACE_TYPE {
            continue;
        }
        // SAFETY: an allowed ACE is Header (4) + Mask (4) + inline SID.
        let mask = u32::from_le_bytes(unsafe {
            [*bytes.add(4), *bytes.add(5), *bytes.add(6), *bytes.add(7)]
        });
        let ace_sid = unsafe { bytes.add(8) as *mut c_void };
        // SAFETY: both SIDs are valid.
        if unsafe { EqualSid(ace_sid, user_sid) } != 0 {
            found_owner = true;
            assert_eq!(
                mask & (PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_CREATE_THREAD),
                0,
                "the owner ACE must withhold memory and thread-injection rights"
            );
            assert_ne!(
                mask & PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                "the owner ACE must keep the control socket's peer-check mask"
            );
        }
    }
    assert!(
        found_owner,
        "the installed DACL must have an ACE for the owner"
    );
    // SAFETY: GetSecurityInfo allocated the descriptor; LocalFree releases it.
    unsafe { LocalFree(descriptor) };
}

#[test]
fn hardening_withholds_memory_access_but_keeps_identity_and_terminate() {
    assert!(
        std::env::var_os(ALLOW_DEBUG_ENV).is_none(),
        "unset {ALLOW_DEBUG_ENV} to run this test: the opt-out is exactly what it disables"
    );

    let token = open_token();
    let (token_user, user_sid) = token_user_sid(token);
    println!("TOKEN={}", sid_text(user_sid));
    let luid = debug_privilege_luid();
    let privilege = debug_privilege_state(token, luid);
    println!("DEBUG_PRIV_BEFORE={privilege}");
    disable_debug_privilege(token, luid);
    println!("DEBUG_PRIV_AFTER={}", debug_privilege_state(token, luid));

    // The before state: a process's default DACL grants the signed-in user
    // memory access, which is how a program in a pane reads the GUI's
    // environment. If this open failed, the assertion below could not tell
    // hardening from a broken probe.
    let before = open_current(PROCESS_VM_READ)
        .expect("the default DACL must grant the owner PROCESS_VM_READ");
    // SAFETY: `before` is a live handle from `OpenProcess`, closed once here.
    unsafe { CloseHandle(before) };
    println!("VM_READ_BEFORE=ALLOWED");

    harden_process().expect("installing the process DACL must succeed");
    assert_owner_ace_withholds_memory(user_sid);

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
    println!("VM_READ_AFTER=DENIED");

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
    println!("QUERY=ALLOWED TERMINATE=ALLOWED");

    drop(token_user);
    // SAFETY: the token was opened by this test and is closed once here.
    unsafe { CloseHandle(token) };
}
