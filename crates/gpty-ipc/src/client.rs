//! JSON-RPC over IPC client.
//!
//! Connects to a running gpty IPC server, sends a single
//! JSON-RPC request, and reads back the response.

use std::io;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::protocol::{JsonRpcError, Request, Response};
use crate::transport;

/// Errors returned by `IpcClient::call()`.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("connection error: {0}")]
    Connection(#[from] io::Error),

    #[error("request timed out after {0:?}")]
    Timeout(Duration),

    #[error("invalid response: {0}")]
    InvalidResponse(String),

    #[error("rpc error {code}: {message}")]
    RpcError {
        code: i64,
        message: String,
        #[source]
        data: Option<Box<dyn std::error::Error + Send + Sync>>,
    },
}

impl ClientError {
    /// Extract the JSON-RPC error details from a `Response` that has `error: Some(...)`.
    pub fn from_rpc_error(err: JsonRpcError) -> Self {
        ClientError::RpcError {
            code: err.code,
            message: err.message,
            data: None,
        }
    }
}

/// A client for the gpty IPC server.
pub struct IpcClient {
    socket_path: String,
    timeout: Duration,
    secret: Option<String>,
}

impl IpcClient {
    /// Create a new client.
    ///
    /// `socket_path` is the platform-specific socket address.
    /// `timeout` is the connection + read timeout.
    pub fn new(socket_path: impl Into<String>, timeout: Duration) -> Self {
        let secret = std::env::var("GPTY_SECRET").ok().filter(|s| !s.is_empty());
        Self {
            socket_path: socket_path.into(),
            timeout,
            secret,
        }
    }

    /// Connect to the default socket path.
    pub fn with_default_socket(timeout: Duration) -> Self {
        Self::new(transport::default_socket_path(), timeout)
    }

    /// Send a JSON-RPC request and return the parsed response.
    ///
    /// The `params` value is serialized as the request's `params` field.
    /// On success returns the full `Response` — callers should inspect
    /// `result` or `error`.
    pub async fn call(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<Response, ClientError> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        let counter = NEXT_ID.fetch_add(1, Ordering::Relaxed);

        let req = Request {
            jsonrpc: "2.0".into(),
            id: counter,
            method: method.to_string(),
            params,
            gpty_secret: self.secret.clone(),
        };

        let json = serde_json::to_string(&req).map_err(|e| {
            ClientError::InvalidResponse(format!("failed to serialize request: {e}"))
        })?;

        // Connect with timeout.
        let connect_fut = transport::connect(&self.socket_path);
        let mut stream = tokio::time::timeout(self.timeout, connect_fut)
            .await
            .map_err(|_| ClientError::Timeout(self.timeout))?
            .map_err(ClientError::Connection)?;

        // Write request.
        tokio::time::timeout(self.timeout, async {
            stream.write_all(json.as_bytes()).await?;
            stream.write_all(b"\n").await?;
            Ok::<_, io::Error>(())
        })
        .await
        .map_err(|_| ClientError::Timeout(self.timeout))?
        .map_err(ClientError::Connection)?;

        // Read response.
        let (reader, _writer) = tokio::io::split(stream);
        let mut buf_reader = BufReader::new(reader);
        let mut line = String::new();

        tokio::time::timeout(self.timeout, buf_reader.read_line(&mut line))
            .await
            .map_err(|_| ClientError::Timeout(self.timeout))?
            .map_err(ClientError::Connection)?;

        let line = line.trim().to_string();
        if line.is_empty() {
            return Err(ClientError::InvalidResponse("empty response".into()));
        }

        let resp: Response = serde_json::from_str(&line)
            .map_err(|e| ClientError::InvalidResponse(format!("failed to parse response: {e}")))?;

        Ok(resp)
    }
}

// ── Tests ────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_creation() {
        let client = IpcClient::new("/tmp/test.sock", Duration::from_secs(5));
        assert_eq!(client.socket_path, "/tmp/test.sock");
        assert_eq!(client.timeout, Duration::from_secs(5));
    }

    #[test]
    fn client_default_socket() {
        let client = IpcClient::with_default_socket(Duration::from_secs(1));
        assert!(!client.socket_path.is_empty());
    }

    #[test]
    fn client_error_display() {
        let err = ClientError::InvalidResponse("bad json".into());
        assert!(err.to_string().contains("bad json"));
    }

    #[cfg(unix)]
    mod unix {
        use super::*;
        use crate::server::IpcServer;

        #[tokio::test]
        async fn client_server_round_trip() {
            let socket_path = format!("/tmp/gpty-ipc-client-test-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.register(
                "greet",
                std::sync::Arc::new(|params| {
                    Box::pin(async move {
                        let name = params
                            .get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or("world");
                        Ok(serde_json::json!({"greeting": format!("hello, {name}")}))
                    })
                }),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            tokio::time::sleep(Duration::from_millis(200)).await;

            let client = IpcClient::new(&server_path, Duration::from_secs(5));
            let resp = client
                .call("greet", Some(serde_json::json!({"name": "gpty"})))
                .await
                .unwrap();

            assert!(resp.error.is_none());
            assert_eq!(
                resp.result.unwrap(),
                serde_json::json!({"greeting": "hello, gpty"})
            );
        }

        #[tokio::test]
        async fn client_authenticates_with_secret() {
            let socket_path = format!("/tmp/gpty-ipc-secret-test-{}.sock", std::process::id());
            let _ = std::fs::remove_file(&socket_path);

            let mut server = IpcServer::new(&socket_path);
            server.set_secret("s3cret".into());
            server.register(
                "greet",
                std::sync::Arc::new(|_params| {
                    Box::pin(async move { Ok(serde_json::json!({"greeting": "hello"})) })
                }),
            );

            let server_path = socket_path.clone();
            tokio::spawn(async move {
                let _ = server.serve().await;
            });

            tokio::time::sleep(Duration::from_millis(200)).await;

            // With GPTY_SECRET set, the client presents the secret and succeeds.
            unsafe { std::env::set_var("GPTY_SECRET", "s3cret") };
            let client = IpcClient::new(&server_path, Duration::from_secs(5));
            let resp = client.call("greet", None).await.unwrap();
            assert!(resp.error.is_none());

            // Without the env var, a fresh client fails with UNAUTHORIZED.
            unsafe { std::env::remove_var("GPTY_SECRET") };
            let client = IpcClient::new(&server_path, Duration::from_secs(5));
            let resp = client.call("greet", None).await.unwrap();
            let err = resp.error.unwrap();
            assert_eq!(err.code, JsonRpcError::UNAUTHORIZED);
        }

        #[tokio::test]
        async fn client_timeout() {
            let socket_path = format!("/tmp/gpty-ipc-timeout-test-{}.sock", std::process::id());
            let client = IpcClient::new(&socket_path, Duration::from_millis(100));
            let result = client.call("version", None).await;
            assert!(result.is_err());
        }
    }
}
