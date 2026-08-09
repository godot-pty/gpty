use serde::{Deserialize, Serialize};

// ── JSON-RPC 2.0 protocol types ──────────────────────────

/// An incoming JSON-RPC 2.0 request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    pub id: u64,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

/// A JSON-RPC 2.0 response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub jsonrpc: String,
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

/// A JSON-RPC 2.0 error object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

impl JsonRpcError {
    // Standard JSON-RPC error codes.
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    pub const INTERNAL_ERROR: i64 = -32603;
    /// Application-level errors start here.
    pub const SERVER_ERROR: i64 = -32000;

    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn with_data(code: i64, message: impl Into<String>, data: serde_json::Value) -> Self {
        Self {
            code,
            message: message.into(),
            data: Some(data),
        }
    }
}

impl Request {
    /// Returns `true` when the request is a notification (no response expected).
    pub fn is_notification(&self) -> bool {
        self.id == 0
    }
}

// ── Convenience builders ─────────────────────────────────

/// Build a successful JSON-RPC 2.0 response.
pub fn build_response(id: u64, result: serde_json::Value) -> Response {
    Response {
        jsonrpc: "2.0".into(),
        id,
        result: Some(result),
        error: None,
    }
}

/// Build a JSON-RPC 2.0 error response.
pub fn build_error(id: u64, error: JsonRpcError) -> Response {
    Response {
        jsonrpc: "2.0".into(),
        id,
        result: None,
        error: Some(error),
    }
}

// ── Tests ────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_request() {
        let req = Request {
            jsonrpc: "2.0".into(),
            id: 1,
            method: "newPane".into(),
            params: Some(serde_json::json!({"type": "terminal"})),
        };
        let json = serde_json::to_string(&req).unwrap();
        let parsed: Request = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, 1);
        assert_eq!(parsed.method, "newPane");
        assert!(!parsed.is_notification());
    }

    #[test]
    fn notification_detection() {
        let req = Request {
            jsonrpc: "2.0".into(),
            id: 0,
            method: "ping".into(),
            params: None,
        };
        assert!(req.is_notification());
    }

    #[test]
    fn round_trip_response_success() {
        let resp = build_response(42, serde_json::json!({"pane_id": "T1"}));
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: Response = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, 42);
        assert!(parsed.result.is_some());
        assert!(parsed.error.is_none());
    }

    #[test]
    fn round_trip_response_error() {
        let err = JsonRpcError::new(JsonRpcError::METHOD_NOT_FOUND, "no such method");
        let resp = build_error(7, err);
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: Response = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, 7);
        assert!(parsed.result.is_none());
        let e = parsed.error.unwrap();
        assert_eq!(e.code, JsonRpcError::METHOD_NOT_FOUND);
        assert_eq!(e.message, "no such method");
    }

    #[test]
    fn request_without_params() {
        let json = r#"{"jsonrpc":"2.0","id":1,"method":"version"}"#;
        let req: Request = serde_json::from_str(json).unwrap();
        assert!(req.params.is_none());
    }

    #[test]
    fn jsonrpc_constants() {
        assert_eq!(JsonRpcError::PARSE_ERROR, -32700);
        assert_eq!(JsonRpcError::INTERNAL_ERROR, -32603);
        assert_eq!(JsonRpcError::SERVER_ERROR, -32000);
    }

    #[test]
    fn error_with_data() {
        let err = JsonRpcError::with_data(-32001, "custom", serde_json::json!({"hint": "retry"}));
        assert!(err.data.is_some());
    }
}
