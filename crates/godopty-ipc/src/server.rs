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

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::protocol;
use crate::protocol::{JsonRpcError, Request};

/// A boxed, cloneable async handler function.
///
/// Receives the parsed `params` value (or `Value::Null` when absent)
/// and returns either a result value or a JSON-RPC error.
pub type HandlerFn = Arc<
    dyn Fn(serde_json::Value)
            -> Pin<Box<dyn Future<Output = Result<serde_json::Value, JsonRpcError>> + Send>>
        + Send
        + Sync,
>;

/// The IPC server — binds a socket and dispatches JSON-RPC requests.
pub struct IpcServer {
    handlers: HashMap<String, HandlerFn>,
    socket_path: String,
}

impl IpcServer {
    /// Create a new server that will bind to `socket_path`.
    pub fn new(socket_path: impl Into<String>) -> Self {
        Self {
            handlers: HashMap::new(),
            socket_path: socket_path.into(),
        }
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
        // Clean up stale socket file on Unix.
        #[cfg(unix)]
        {
            let _ = std::fs::remove_file(&self.socket_path);
        }

        let listener = self.bind().await?;
        log::info!("IPC server listening on {}", self.socket_path);

        loop {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    let handlers = self.handlers.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_connection(stream, &handlers).await {
                            log::warn!("IPC connection error: {e}");
                        }
                    });
                }
                Err(e) => {
                    log::error!("IPC accept error: {e}");
                }
            }
        }
    }

    #[cfg(unix)]
    async fn bind(&self) -> io::Result<tokio::net::UnixListener> {
        tokio::net::UnixListener::bind(&self.socket_path)
    }

    #[cfg(windows)]
    async fn bind(&self) -> io::Result<tokio::net::windows::named_pipe::NamedPipeServer> {
        // Windows uses named pipes; for a simple implementation we
        // accept one connection at a time.
        use tokio::net::windows::named_pipe;
        let mut opts = named_pipe::ServerOptions::new();
        opts.first_pipe_instance(true);
        opts.create(&self.socket_path)
    }
}

/// Handle a single connection: read one JSON-RPC request, dispatch, respond.
async fn handle_connection(
    stream: impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    handlers: &HashMap<String, HandlerFn>,
) -> io::Result<()> {
    let (reader, mut writer) = tokio::io::split(stream);
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    // Read one newline-delimited JSON request.
    let n = buf_reader.read_line(&mut line).await?;
    if n == 0 {
        return Ok(()); // EOF
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
                JsonRpcError::new(
                    JsonRpcError::PARSE_ERROR,
                    format!("Parse error: {e}"),
                ),
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

    #[test]
    fn server_register_and_has_handler() {
        let mut server = IpcServer::new("/tmp/test.sock");
        server.register(
            "version",
            Arc::new(|_params| {
                Box::pin(async { Ok(serde_json::json!({"version": "0.3.0"})) })
            }),
        );
        // Handler is registered — integration test below verifies dispatch.
    }

    #[cfg(unix)]
    mod unix {
        use super::*;
        use crate::protocol::{Request, Response};

        async fn send_request(
            socket_path: &str,
            req: &Request,
        ) -> io::Result<Response> {
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
            let socket_path = format!("/tmp/godopty-ipc-test-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.register(
                "echo",
                Arc::new(|params| {
                    Box::pin(async move { Ok(params) })
                }),
            );
            server.register(
                "fail",
                Arc::new(|_params| {
                    Box::pin(async {
                        Err(JsonRpcError::new(-32001, "intentional failure"))
                    })
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
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 1);
            assert!(resp.error.is_none());
            assert_eq!(
                resp.result.unwrap(),
                serde_json::json!({"hello": "world"})
            );

            // Error call.
            let req = Request {
                jsonrpc: "2.0".into(),
                id: 2,
                method: "fail".into(),
                params: None,
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
            };
            let resp = send_request(&server_path, &req).await.unwrap();
            assert_eq!(resp.id, 3);
            assert_eq!(resp.error.unwrap().code, JsonRpcError::METHOD_NOT_FOUND);
        }
    }
}
