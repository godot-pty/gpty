use serde::{Deserialize, Serialize};

// ── JSON-RPC 2.0 protocol types ──────────────────────────

/// The control-IPC dialect version, pinned per release and reported by the
/// `version` method. Both binaries compare it: a GUI (or CLI) answering a
/// different value is from a different release, whatever the version numbers
/// say — the CLI's stale-binary warning says so instead of leaving commands
/// to fail opaquely. One definition, used by the server's `version` handler,
/// the CLI's `version` output, and the About tab (`get_ipc_protocol_version`).
pub const PROTOCOL_VERSION: &str = "2.0";

/// An incoming JSON-RPC 2.0 request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    /// Request id. JSON-RPC 2.0 notifications omit it entirely; requests
    /// that do carry one keep their id on the wire (`skip_serializing_if`
    /// only suppresses the field when it is absent).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
    /// Shared secret presented by the client (GPTY_SECRET). Required when
    /// the server has a secret configured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpty_secret: Option<String>,
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
    /// Authentication failure (missing or invalid gpty_secret).
    pub const UNAUTHORIZED: i64 = -32001;

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
    ///
    /// A notification omits `id` entirely; an explicit `"id": 0` is a normal
    /// request that must still be answered.
    pub fn is_notification(&self) -> bool {
        self.id.is_none()
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

    // The envelope is the one contract every client (the CLI, scripts, the
    // GUI's own client) shares, so each shape is pinned against literal JSON.
    // A serde round-trip alone would pass a renamed key, because both
    // directions would be renamed together.

    #[test]
    fn wire_request_envelope() {
        let req = Request {
            jsonrpc: "2.0".into(),
            id: Some(1),
            method: "newPane".into(),
            params: Some(serde_json::json!({"type": "terminal"})),
            gpty_secret: None,
        };
        assert_eq!(
            serde_json::to_value(&req).unwrap(),
            serde_json::json!({
                "jsonrpc": "2.0", "id": 1, "method": "newPane",
                "params": {"type": "terminal"},
            }),
            "an absent secret must not appear on the wire at all"
        );
        let parsed: Request = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":9,"method":"newPane","params":{"type":"terminal"}}"#,
        )
        .unwrap();
        assert_eq!(parsed.id, Some(9));
        assert_eq!(parsed.method, "newPane");
        assert_eq!(parsed.params, Some(serde_json::json!({"type": "terminal"})));
        assert!(parsed.gpty_secret.is_none());
        assert!(!parsed.is_notification());
    }

    /// The secret travels under the key `gpty_secret`: the server reads it
    /// from there, so a client spelling it any other way is treated as
    /// unauthenticated.
    #[test]
    fn wire_request_carries_the_secret_as_gpty_secret() {
        let req = Request {
            jsonrpc: "2.0".into(),
            id: Some(2),
            method: "version".into(),
            params: None,
            gpty_secret: Some("s3cret".into()),
        };
        assert_eq!(
            serde_json::to_value(&req).unwrap(),
            serde_json::json!({
                "jsonrpc": "2.0", "id": 2, "method": "version", "gpty_secret": "s3cret",
            })
        );
        let parsed: Request = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":2,"method":"version","gpty_secret":"s3cret"}"#,
        )
        .unwrap();
        assert_eq!(parsed.gpty_secret.as_deref(), Some("s3cret"));
    }

    #[test]
    fn notification_detection() {
        // A notification omits `id`; it still deserializes and is recognised.
        let raw = r#"{"jsonrpc":"2.0","method":"ping"}"#;
        let req: Request = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, None);
        assert!(req.is_notification());
        // Serializing a notification keeps the field absent.
        let json = serde_json::to_string(&req).unwrap();
        assert!(!json.contains("\"id\""));
    }

    #[test]
    fn explicit_zero_id_is_a_request() {
        // `"id": 0` is a legitimate request id, not a notification marker.
        let raw = r#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#;
        let req: Request = serde_json::from_str(raw).unwrap();
        assert_eq!(req.id, Some(0));
        assert!(!req.is_notification());
    }

    #[test]
    fn wire_response_success_has_result_and_no_error_key() {
        let resp = build_response(42, serde_json::json!({"pane_id": "T1"}));
        assert_eq!(
            serde_json::to_value(&resp).unwrap(),
            serde_json::json!({"jsonrpc": "2.0", "id": 42, "result": {"pane_id": "T1"}}),
            "JSON-RPC forbids `error` alongside `result`, even as null"
        );
        let parsed: Response =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":42,"result":{"pane_id":"T1"}}"#).unwrap();
        assert_eq!(parsed.id, 42);
        assert_eq!(parsed.result, Some(serde_json::json!({"pane_id": "T1"})));
        assert!(parsed.error.is_none());
    }

    #[test]
    fn wire_response_error_has_error_and_no_result_key() {
        let err = JsonRpcError::new(JsonRpcError::METHOD_NOT_FOUND, "no such method");
        let resp = build_error(7, err);
        assert_eq!(
            serde_json::to_value(&resp).unwrap(),
            serde_json::json!({
                "jsonrpc": "2.0", "id": 7,
                "error": {"code": -32601, "message": "no such method"},
            }),
            "the error is spelled code/message, with no `data` when there is none"
        );
        let with_data = JsonRpcError::with_data(-32001, "nope", serde_json::json!({"hint": 1}));
        assert_eq!(
            serde_json::to_value(&with_data).unwrap(),
            serde_json::json!({"code": -32001, "message": "nope", "data": {"hint": 1}})
        );
    }

    /// The numeric codes are the JSON-RPC spec's, and clients match on them;
    /// pin the ones the server hands out beyond those `jsonrpc_constants` covers.
    #[test]
    fn error_codes_match_the_jsonrpc_spec() {
        assert_eq!(JsonRpcError::INVALID_REQUEST, -32600);
        assert_eq!(JsonRpcError::METHOD_NOT_FOUND, -32601);
        assert_eq!(JsonRpcError::INVALID_PARAMS, -32602);
        assert_eq!(JsonRpcError::UNAUTHORIZED, -32001);
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

    #[test]
    fn deserialize_error_from_raw_json() {
        // Simulates a real error response from the wire
        let raw = r#"{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Invalid Request"}}"#;
        let resp: Response = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.id, 3);
        assert!(resp.result.is_none());
        let err = resp.error.unwrap();
        assert_eq!(err.code, -32600);
        assert_eq!(err.message, "Invalid Request");
        assert!(err.data.is_none());
    }

    #[test]
    fn deserialize_error_with_data_from_raw_json() {
        let raw = r#"{"jsonrpc":"2.0","id":5,"error":{"code":-32001,"message":"Custom","data":{"hint":"retry","attempt":3}}}"#;
        let resp: Response = serde_json::from_str(raw).unwrap();
        let err = resp.error.unwrap();
        assert_eq!(err.code, -32001);
        assert!(err.data.is_some());
        let data = err.data.unwrap();
        assert_eq!(data["hint"], "retry");
        assert_eq!(data["attempt"], 3);
    }
}
