//! JSON-RPC over IPC server.
//!
//! Binds a platform socket and accepts connections in a loop.
//! Each connection reads one newline-delimited JSON-RPC request,
//! dispatches to a registered handler, and writes back the response.

use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::protocol;
use crate::protocol::{JsonRpcError, Request};

/// Maximum request line length in bytes; oversize requests get an error.
const MAX_REQUEST_LEN: usize = 64 * 1024; // 64 KiB
/// Maximum in-flight connections; excess connections are dropped.
const MAX_CONNECTIONS: usize = 16;
/// Per-connection lifetime cap so slow clients cannot hold a slot forever.
const CONNECTION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// A boxed, cloneable async handler function.
///
/// Receives the parsed `params` value (or `Value::Null` when absent)
/// and returns either a result value or a JSON-RPC error.
pub type HandlerFn = Arc<
    dyn Fn(
            serde_json::Value,
        ) -> Pin<Box<dyn Future<Output = Result<serde_json::Value, JsonRpcError>> + Send>>
        + Send
        + Sync,
>;
/// The IPC server — binds a socket and dispatches JSON-RPC requests.
pub struct IpcServer {
    handlers: HashMap<String, HandlerFn>,
    socket_path: String,
    /// Optional shared secret; when set, requests must carry a matching gpty_secret.
    secret: Option<String>,
}

impl IpcServer {
    /// Create a new server that will bind to `socket_path`.
    pub fn new(socket_path: impl Into<String>) -> Self {
        Self {
            handlers: HashMap::new(),
            socket_path: socket_path.into(),
            secret: None,
        }
    }

    /// Require clients to present this shared secret (GPTY_SECRET).
    pub fn set_secret(&mut self, secret: String) {
        self.secret = Some(secret);
    }

    /// Register a handler for a named JSON-RPC method.
    pub fn register(&mut self, method: &str, handler: HandlerFn) {
        self.handlers.insert(method.to_string(), handler);
    }

    /// Bind the socket and accept connections forever.
    ///
    /// Cleans up the socket file on Unix before binding.
    /// Never returns unless an unrecoverable I/O error occurs.
    pub async fn serve(&self) -> io::Result<()> {
        #[cfg(unix)]
        {
            // Clean up a stale socket from a previous run — but only one that
            // is ours. The /tmp fallback path is predictable, so another user
            // can plant something there first; unlinking blindly would delete
            // their file (and hide the squat), and following a symlink would
            // delete whatever it points at. Anything else is left alone and
            // the bind below fails closed.
            use std::os::unix::fs::FileTypeExt;
            match std::fs::symlink_metadata(&self.socket_path) {
                Ok(meta) if !meta.file_type().is_socket() => {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "{} exists and is not a socket; refusing to replace it",
                            self.socket_path
                        ),
                    ));
                }
                Ok(meta) if !owned_by_current_uid(&meta) => {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        format!(
                            "{} is a socket owned by another user; refusing to replace it",
                            self.socket_path
                        ),
                    ));
                }
                Ok(_) => {
                    let _ = std::fs::remove_file(&self.socket_path);
                }
                Err(_) => {}
            }

            let listener = tokio::net::UnixListener::bind(&self.socket_path)?;

            // Restrict the socket file to the owning user (default umask leaves 0755).
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(
                    &self.socket_path,
                    std::fs::Permissions::from_mode(0o600),
                )?;
            }
            log::info!("IPC server listening on {}", self.socket_path);

            let semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));
            loop {
                match listener.accept().await {
                    Ok((stream, _addr)) => {
                        if !peer_uid_matches(&stream) {
                            log::warn!("IPC connection rejected: peer UID mismatch");
                            drop(stream);
                            continue;
                        }
                        let permit = match semaphore.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                log::warn!("IPC connection rejected: connection limit reached");
                                drop(stream);
                                continue;
                            }
                        };
                        let handlers = self.handlers.clone();
                        let secret = self.secret.clone();
                        tokio::spawn(async move {
                            let _permit = permit;
                            match tokio::time::timeout(
                                CONNECTION_TIMEOUT,
                                handle_connection(stream, &handlers, secret.as_deref()),
                            )
                            .await
                            {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => log::warn!("IPC connection error: {e}"),
                                Err(_) => log::warn!("IPC connection timed out"),
                            }
                        });
                    }
                    Err(e) => {
                        log::error!("IPC accept error: {e}");
                    }
                }
            }
        }

        #[cfg(windows)]
        {
            log::info!("IPC server listening on {}", self.socket_path);

            let semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));
            loop {
                // A Windows named pipe instance serves exactly one client.
                // Create a fresh instance, wait for a client, then spawn its
                // handler and prepare the next instance. Multiple instances
                // of the same pipe name may coexist, so in-flight connections
                // do not block new ones.
                let server = match self.create_pipe_instance().await {
                    Ok(s) => s,
                    Err(e) => {
                        log::error!("IPC pipe create error: {e}");
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                        continue;
                    }
                };
                if let Err(e) = server.connect().await {
                    log::error!("IPC pipe connect error: {e}");
                    continue;
                }
                if !peer_uid_matches(&server) {
                    log::warn!("IPC connection rejected: peer user mismatch");
                    drop(server);
                    continue;
                }
                let permit = match semaphore.clone().try_acquire_owned() {
                    Ok(p) => p,
                    Err(_) => {
                        log::warn!("IPC connection rejected: connection limit reached");
                        drop(server);
                        continue;
                    }
                };
                let handlers = self.handlers.clone();
                let secret = self.secret.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    match tokio::time::timeout(
                        CONNECTION_TIMEOUT,
                        handle_connection(server, &handlers, secret.as_deref()),
                    )
                    .await
                    {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => log::warn!("IPC connection error: {e}"),
                        Err(_) => log::warn!("IPC connection timed out"),
                    }
                });
            }
        }

        #[cfg(not(any(unix, windows)))]
        {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "unsupported platform for IPC server",
            ))
        }
    }

    #[cfg(windows)]
    async fn create_pipe_instance(
        &self,
    ) -> io::Result<tokio::net::windows::named_pipe::NamedPipeServer> {
        use std::sync::atomic::{AtomicBool, Ordering};
        use tokio::net::windows::named_pipe;

        // FILE_FLAG_FIRST_PIPE_INSTANCE makes create() fail when *any*
        // instance of the name already exists, so it only guards the very
        // first instance this process creates — that is what blocks another
        // local process from squatting on the pipe name. Applying it to every
        // instance would instead make the accept loop fail with
        // "pipe create error" until the previous client disconnects,
        // serializing the daemon to one live connection.
        static FIRST_PIPE_INSTANCE: AtomicBool = AtomicBool::new(true);
        let first = FIRST_PIPE_INSTANCE.swap(false, Ordering::SeqCst);

        // Named pipes are network-reachable by default; this daemon is
        // local-only, so reject remote clients.
        named_pipe::ServerOptions::new()
            .reject_remote_clients(true)
            .first_pipe_instance(first)
            .create(&self.socket_path)
    }
}

/// True when `meta` describes a file this process owns.
///
/// Used before replacing a stale socket on the shared-`/tmp` fallback path:
/// only the owner may unlink entries in a sticky directory, and a socket
/// someone else created is a squatted path, not a leftover from a crash.
#[cfg(unix)]
fn owned_by_current_uid(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: geteuid takes no arguments and cannot fail.
    meta.uid() == unsafe { libc::geteuid() }
}

/// True when the peer process runs as the same effective UID as the server.
/// Fails closed: any credential-lookup error rejects the connection.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid_matches(stream: &tokio::net::UnixStream) -> bool {
    match stream.peer_cred() {
        Ok(cred) => cred.uid() == unsafe { libc::geteuid() },
        Err(e) => {
            log::warn!("IPC peer credential lookup failed: {e}");
            false
        }
    }
}

/// macOS and the BSDs answer the same question through `getpeereid`.
#[cfg(any(
    target_os = "macos",
    target_os = "freebsd",
    target_os = "dragonfly",
    target_os = "netbsd",
    target_os = "openbsd",
))]
fn peer_uid_matches(stream: &tokio::net::UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let mut uid: libc::uid_t = u32::MAX;
    let mut gid: libc::gid_t = u32::MAX;
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if rc != 0 {
        log::warn!("IPC peer credential lookup failed (getpeereid rc={rc})");
        return false;
    }
    uid == unsafe { libc::geteuid() }
}

/// illumos and Solaris hand the credentials over as an allocated `ucred`.
#[cfg(any(target_os = "solaris", target_os = "illumos"))]
fn peer_uid_matches(stream: &tokio::net::UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let mut cred: *mut libc::ucred_t = std::ptr::null_mut();
    // SAFETY: `cred` is a valid out-pointer; on success the kernel allocates a
    // ucred that `ucred_free` releases.
    let rc = unsafe { libc::getpeerucred(stream.as_raw_fd(), &mut cred) };
    if rc != 0 || cred.is_null() {
        log::warn!("IPC peer credential lookup failed (getpeerucred rc={rc})");
        return false;
    }
    // SAFETY: non-null and owned by this call until it is freed below.
    let uid = unsafe { libc::ucred_geteuid(cred) };
    unsafe { libc::ucred_free(cred) };
    uid == unsafe { libc::geteuid() }
}

/// Peer check for the named-pipe server: the client process is identified by
/// the id the pipe reports, and its token's user SID is compared with ours.
///
/// Windows has no `SO_PEERCRED`, and a named pipe's default ACL (owner,
/// SYSTEM, Administrators) is inherited rather than verified — so the check
/// has to be made here. Fails closed on every error, like the Unix paths.
#[cfg(windows)]
fn peer_uid_matches(server: &tokio::net::windows::named_pipe::NamedPipeServer) -> bool {
    use std::os::windows::io::AsRawHandle;
    win_peer::client_is_current_user(server.as_raw_handle().cast())
}

/// Remaining Unix platforms have no peer-credential API wired up here.
///
/// Accurate, not lazy: the socket's own mode (0600) and the owning-user check
/// on the path remain the gate, and SECURITY.md says so. Platforms that do
/// have an API — Linux, Android, macOS, the BSDs, illumos — are all covered
/// above.
#[cfg(all(
    unix,
    not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "freebsd",
        target_os = "dragonfly",
        target_os = "netbsd",
        target_os = "openbsd",
        target_os = "solaris",
        target_os = "illumos",
    ))
))]
fn peer_uid_matches(_stream: &tokio::net::UnixStream) -> bool {
    true
}

/// Raw Win32 calls behind [`peer_uid_matches`] on Windows.
///
/// Kept to `extern "system"` declarations rather than a `windows-sys`
/// dependency, the same way `gpty-gdext` pins its own module: three functions
/// from kernel32 and three from advapi32 do not justify a dependency tree the
/// release builds would carry on every platform.
#[cfg(windows)]
mod win_peer {
    use core::ffi::{c_int, c_void};

    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const TOKEN_QUERY: u32 = 0x0008;
    const TOKEN_USER_CLASS: u32 = 1;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetNamedPipeClientProcessId(pipe: *mut c_void, client_pid: *mut u32) -> c_int;
        fn OpenProcess(desired_access: u32, inherit_handle: c_int, process_id: u32) -> *mut c_void;
        fn GetCurrentProcess() -> *mut c_void;
        fn CloseHandle(handle: *mut c_void) -> c_int;
    }

    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> c_int;
        fn GetTokenInformation(
            token: *mut c_void,
            class: u32,
            info: *mut c_void,
            info_len: u32,
            returned_len: *mut u32,
        ) -> c_int;
        fn EqualSid(a: *mut c_void, b: *mut c_void) -> c_int;
    }

    /// The user SID of `process`, returned with the buffer that holds it.
    ///
    /// `TOKEN_USER` is a `SID_AND_ATTRIBUTES`, so the SID pointer is the first
    /// machine word of the returned buffer — the buffer must outlive the
    /// pointer, which is why both are handed back together.
    fn user_sid(process: *mut c_void) -> Option<(Vec<u8>, *mut c_void)> {
        let mut token: *mut c_void = core::ptr::null_mut();
        // SAFETY: `process` is a handle the caller obtained and has not closed;
        // `token` is an out-pointer this function owns.
        if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
            return None;
        }

        // First call sizes the buffer, the second fills it. A zero-sized answer
        // means the query itself failed, not that a zero-length token is valid.
        let mut needed: u32 = 0;
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
            unsafe { CloseHandle(token) };
            return None;
        }

        let mut buffer = vec![0u8; needed as usize];
        let ok = unsafe {
            GetTokenInformation(
                token,
                TOKEN_USER_CLASS,
                buffer.as_mut_ptr().cast(),
                needed,
                &mut needed,
            )
        };
        unsafe { CloseHandle(token) };
        if ok == 0 {
            return None;
        }

        // SAFETY: the query filled `buffer` with a TOKEN_USER whose first field
        // is the SID pointer.
        let sid = unsafe { *(buffer.as_ptr() as *const *mut c_void) };
        if sid.is_null() {
            return None;
        }
        Some((buffer, sid))
    }

    /// True when the client on `pipe` runs under the same user as this process.
    pub(super) fn client_is_current_user(pipe: *mut c_void) -> bool {
        let mut pid: u32 = 0;
        // SAFETY: `pipe` is a connected server-side pipe handle.
        if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 || pid == 0 {
            log::warn!("IPC peer lookup failed: the pipe did not report its client");
            return false;
        }

        // SAFETY: a plain process-id lookup; the handle is closed below.
        let client = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if client.is_null() {
            log::warn!("IPC peer lookup failed: cannot open client process {pid}");
            return false;
        }

        // SAFETY: GetCurrentProcess returns a pseudo-handle that must not be
        // closed, and `client` is a real handle that must be.
        let ours = user_sid(unsafe { GetCurrentProcess() });
        let theirs = user_sid(client);
        unsafe { CloseHandle(client) };

        let (Some((_ours_buffer, ours_sid)), Some((_theirs_buffer, theirs_sid))) = (ours, theirs)
        else {
            log::warn!("IPC peer lookup failed: no user token for client {pid}");
            return false;
        };
        // SAFETY: both SIDs point into buffers that are still alive here.
        unsafe { EqualSid(ours_sid, theirs_sid) != 0 }
    }
}

/// Byte-wise equality that does not short-circuit on the first mismatch.
///
/// Defence-in-depth for the local control socket: it keeps a presented
/// `GPTY_SECRET` from being recovered a byte at a time by timing the
/// comparison. Access to the socket is still gated by the peer-UID check and
/// file permissions — this only removes the timing side channel.
fn constant_time_eq(provided: &[u8], expected: &[u8]) -> bool {
    if provided.len() != expected.len() {
        return false;
    }
    provided
        .iter()
        .zip(expected)
        .fold(0_u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

/// Handle a single connection: read one JSON-RPC request, dispatch, respond.
async fn handle_connection(
    stream: impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    handlers: &HashMap<String, HandlerFn>,
    secret: Option<&str>,
) -> io::Result<()> {
    let (reader, mut writer) = tokio::io::split(stream);
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    // Read one newline-delimited JSON request, bounded to MAX_REQUEST_LEN
    // bytes so a malicious client cannot force unbounded allocation.
    let mut limited = BufReader::new((&mut buf_reader).take(MAX_REQUEST_LEN as u64 + 1));
    let n = limited.read_line(&mut line).await?;
    if n == 0 {
        return Ok(()); // EOF
    }
    if !line.ends_with('\n') && line.len() == MAX_REQUEST_LEN + 1 {
        let resp = protocol::build_error(
            0,
            JsonRpcError::new(
                JsonRpcError::INVALID_REQUEST,
                format!("request exceeds {MAX_REQUEST_LEN} bytes"),
            ),
        );
        let json = serde_json::to_string(&resp).unwrap_or_default();
        writer.write_all(json.as_bytes()).await?;
        writer.write_all(b"\n").await?;
        return Ok(());
    }
    let line = line.trim().to_string();
    if line.is_empty() {
        return Ok(());
    }

    // Parse request.
    let req: Request = match serde_json::from_str(&line) {
        Ok(r) => r,
        Err(e) => {
            let resp = protocol::build_error(
                0,
                JsonRpcError::new(JsonRpcError::PARSE_ERROR, format!("Parse error: {e}")),
            );
            let json = serde_json::to_string(&resp).unwrap_or_default();
            writer.write_all(json.as_bytes()).await?;
            writer.write_all(b"\n").await?;
            return Ok(());
        }
    };

    // Notifications (no `id` field) get no response. Checked before auth so
    // an unauthenticated notification is dropped, not answered; a request
    // that merely carries `"id": 0` still runs the auth path below.
    if req.is_notification() {
        return Ok(());
    }

    // Response id for a real request; `id` is present whenever we get here.
    let id = req.id.unwrap_or(0);

    // Auth: when the server has a secret configured, require a match.
    if let Some(expected) = secret {
        let provided = req.gpty_secret.as_deref().unwrap_or("");
        if !constant_time_eq(provided.as_bytes(), expected.as_bytes()) {
            let resp = protocol::build_error(
                id,
                JsonRpcError::new(
                    JsonRpcError::UNAUTHORIZED,
                    "unauthorized: missing or invalid gpty_secret",
                ),
            );
            let json = serde_json::to_string(&resp).unwrap_or_default();
            writer.write_all(json.as_bytes()).await?;
            writer.write_all(b"\n").await?;
            return Ok(());
        }
    }

    // Dispatch.
    let params = req.params.unwrap_or(serde_json::Value::Null);
    let resp = if let Some(handler) = handlers.get(&req.method) {
        match handler(params).await {
            Ok(result) => protocol::build_response(id, result),
            Err(e) => protocol::build_error(id, e),
        }
    } else {
        protocol::build_error(
            id,
            JsonRpcError::new(
                JsonRpcError::METHOD_NOT_FOUND,
                format!("Unknown method: {}", req.method),
            ),
        )
    };

    let json = serde_json::to_string(&resp).unwrap_or_default();
    writer.write_all(json.as_bytes()).await?;
    writer.write_all(b"\n").await?;

    Ok(())
}

// ── Tests ────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constant_time_eq_matches_bytes_exactly() {
        assert!(constant_time_eq(b"s3cret", b"s3cret"));
        // Differing at the first byte and at the last byte are both false.
        assert!(!constant_time_eq(b"x3cret", b"s3cret"));
        assert!(!constant_time_eq(b"s3creX", b"s3cret"));
        // Length mismatch is false, including empty vs non-empty.
        assert!(!constant_time_eq(b"s3cre", b"s3cret"));
        assert!(!constant_time_eq(b"", b"s3cret"));
        assert!(constant_time_eq(b"", b""));
    }

    #[cfg(unix)]
    mod unix {
        use super::*;
        use crate::protocol::{Request, Response};

        /// The credential path itself, not just its effect on the accept loop:
        /// both ends of a socket pair belong to this process, so the check must
        /// answer "same user". (The rejection case needs a second UID and is
        /// covered by the platform check's fail-closed error paths.)
        #[tokio::test]
        async fn peer_credentials_of_this_process_match() {
            let (server_end, client_end) = tokio::net::UnixStream::pair().expect("socket pair");
            assert!(
                peer_uid_matches(&server_end),
                "a peer in this very process must be accepted"
            );
            // The identity comes from the kernel, so it does not matter which
            // end of the pair the server holds.
            assert!(peer_uid_matches(&client_end));
        }

        async fn send_request(socket_path: &str, req: &Request) -> io::Result<Response> {
            use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
            let mut stream = tokio::net::UnixStream::connect(socket_path).await?;
            let json = serde_json::to_string(req).unwrap();
            stream.write_all(json.as_bytes()).await?;
            stream.write_all(b"\n").await?;

            let mut reader = BufReader::new(&mut stream);
            let mut line = String::new();
            reader.read_line(&mut line).await?;
            let resp: Response = serde_json::from_str(line.trim()).unwrap();
            Ok(resp)
        }

        /// A path planted by someone else must fail the bind, not be deleted:
        /// the `/tmp` fallback is predictable, and unlinking blindly both destroys
        /// their file and hides that the control surface was squatted.
        #[cfg(unix)]
        #[tokio::test]
        async fn a_planted_socket_path_is_refused_not_unlinked() {
            let path = format!("/tmp/gpty-ipc-planted-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&path);
            std::fs::write(&path, b"not a socket").unwrap();

            let server = IpcServer::new(&path);
            let error = server
                .serve()
                .await
                .expect_err("a foreign path must not be replaced");
            assert!(
                error.to_string().contains("not a socket"),
                "the refusal must say what is in the way, got: {error}"
            );
            assert_eq!(
                std::fs::read(&path).unwrap(),
                b"not a socket",
                "the refused path must be left exactly as it was found"
            );
            let _ = std::fs::remove_file(&path);
        }

        #[tokio::test]
        async fn round_trip() {
            let socket_path = format!("/tmp/gpty-ipc-test-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.register(
                "echo",
                Arc::new(|params| Box::pin(async move { Ok(params) })),
            );
            server.register(
                "fail",
                Arc::new(|_params| {
                    Box::pin(async { Err(JsonRpcError::new(-32001, "intentional failure")) })
                }),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            // Give the server a moment to bind.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            // Successful call.
            let req = Request {
                jsonrpc: "2.0".into(),
                id: Some(1),
                method: "echo".into(),
                params: Some(serde_json::json!({"hello": "world"})),
                gpty_secret: None,
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 1);
            assert!(resp.error.is_none());
            assert_eq!(resp.result.unwrap(), serde_json::json!({"hello": "world"}));

            // Error call.
            let req = Request {
                jsonrpc: "2.0".into(),
                id: Some(2),
                method: "fail".into(),
                params: None,
                gpty_secret: None,
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 2);
            assert!(resp.result.is_none());
            assert_eq!(resp.error.unwrap().code, -32001);

            // Unknown method.
            let req = Request {
                jsonrpc: "2.0".into(),
                id: Some(3),
                method: "nonexistent".into(),
                params: None,
                gpty_secret: None,
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 3);
            assert_eq!(resp.error.unwrap().code, JsonRpcError::METHOD_NOT_FOUND);
        }

        #[tokio::test]
        async fn oversized_request_is_rejected() {
            let socket_path = format!("/tmp/gpty-ipc-oversize-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.register(
                "echo",
                Arc::new(|params| Box::pin(async move { Ok(params) })),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            let mut stream = tokio::net::UnixStream::connect(&server_path).await.unwrap();
            stream
                .write_all("x".repeat(MAX_REQUEST_LEN + 1).as_bytes())
                .await
                .unwrap();
            stream.write_all(b"\n").await.unwrap();

            let mut reader = BufReader::new(&mut stream);
            let mut line = String::new();
            reader.read_line(&mut line).await.unwrap();
            let resp: Response = serde_json::from_str(line.trim()).unwrap();
            assert_eq!(resp.error.unwrap().code, JsonRpcError::INVALID_REQUEST);
        }

        #[tokio::test]
        async fn secret_enforced_when_configured() {
            let socket_path = format!("/tmp/gpty-ipc-auth-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.set_secret("s3cret".into());
            server.register(
                "echo",
                Arc::new(|params| Box::pin(async move { Ok(params) })),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            let base = Request {
                jsonrpc: "2.0".into(),
                id: Some(1),
                method: "echo".into(),
                params: None,
                gpty_secret: None,
            };

            // Missing secret → unauthorized.
            let resp = send_request(&server_path, &base).await.unwrap();
            assert_eq!(resp.error.unwrap().code, JsonRpcError::UNAUTHORIZED);

            // An explicit `"id": 0` is a request, not a notification: it must
            // be answered (UNAUTHORIZED) rather than silently dropped before
            // the auth check.
            let req = Request {
                id: Some(0),
                ..base.clone()
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 0);
            assert_eq!(resp.error.unwrap().code, JsonRpcError::UNAUTHORIZED);

            // Wrong secret → unauthorized.
            let req = Request {
                gpty_secret: Some("wrong".into()),
                ..base.clone()
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.error.unwrap().code, JsonRpcError::UNAUTHORIZED);

            // Correct secret → dispatched.
            let req = Request {
                gpty_secret: Some("s3cret".into()),
                ..base
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert!(resp.error.is_none());
        }

        #[tokio::test]
        async fn connection_limit_drops_excess_connections() {
            let socket_path = format!("/tmp/gpty-ipc-cap-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.register(
                "echo",
                Arc::new(|params| Box::pin(async move { Ok(params) })),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            // Saturate the connection pool with idle connections.
            let mut held = Vec::new();
            for _ in 0..MAX_CONNECTIONS {
                held.push(tokio::net::UnixStream::connect(&server_path).await.unwrap());
            }

            // Let the server accept them all before the excess connection arrives.
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            // The 17th connection is accepted then dropped: read returns EOF
            // or ECONNRESET (server closed with unread data pending).
            let mut stream = tokio::net::UnixStream::connect(&server_path).await.unwrap();
            stream
                .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo\"}\n")
                .await
                .unwrap();

            let mut buf = [0u8; 16];
            let n = tokio::time::timeout(std::time::Duration::from_secs(2), stream.read(&mut buf))
                .await
                .expect("excess connection was not dropped within 2s");
            match n {
                Ok(0) => {}
                Ok(_) => panic!("expected EOF, got response data"),
                Err(e) if e.kind() == io::ErrorKind::ConnectionReset => {}
                Err(e) => panic!("unexpected read error: {e}"),
            }
        }
    }
}
