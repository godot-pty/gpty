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
            // Clean up stale socket file on Unix.
            let _ = std::fs::remove_file(&self.socket_path);

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
        use tokio::net::windows::named_pipe;

        // Named pipes are network-reachable by default; this daemon is
        // local-only, so reject remote clients. first_pipe_instance guards
        // against another local process squatting on the pipe name.
        named_pipe::ServerOptions::new()
            .reject_remote_clients(true)
            .first_pipe_instance(true)
            .create(&self.socket_path)
    }
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

#[cfg(target_os = "macos")]
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

#[cfg(all(
    unix,
    not(any(target_os = "linux", target_os = "android", target_os = "macos"))
))]
fn peer_uid_matches(_stream: &tokio::net::UnixStream) -> bool {
    true
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

    // Notifications get no response.
    if req.is_notification() {
        return Ok(());
    }

    // Auth: when the server has a secret configured, require a match.
    if let Some(expected) = secret {
        let provided = req.gpty_secret.as_deref().unwrap_or("");
        if provided != expected {
            let resp = protocol::build_error(
                req.id,
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
            Ok(result) => protocol::build_response(req.id, result),
            Err(e) => protocol::build_error(req.id, e),
        }
    } else {
        protocol::build_error(
            req.id,
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

    #[cfg(unix)]
    mod unix {
        use super::*;
        use crate::protocol::{Request, Response};

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
                id: 1,
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
                id: 2,
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
                id: 3,
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
                id: 1,
                method: "echo".into(),
                params: None,
                gpty_secret: None,
            };

            // Missing secret → unauthorized.
            let resp = send_request(&server_path, &base).await.unwrap();
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
