//! Instance-owned Godot bridge for one [`gpty_ai::AiSession`].

use std::sync::Arc;

use godot::prelude::*;
use gpty_ai::{AiSession, SessionOpenRequest, SessionPromptRequest};
use serde_json::{Value, json};

use crate::RUNTIME;

/// One private in-memory AI conversation. The historical class name is kept
/// so existing scenes can instantiate it, but there is no global event bus.
#[derive(GodotClass)]
#[class(base = Node)]
struct GptyAi {
    session: Option<Arc<AiSession>>,
    base: Base<Node>,
}

#[godot_api]
impl INode for GptyAi {
    fn init(base: Base<Node>) -> Self {
        Self {
            session: None,
            base,
        }
    }
}

#[godot_api]
impl GptyAi {
    /// Input: `{"backend":"mock"|"omp","system_prompt":"","cwd":"","model":""}`.
    /// Output: `{"ok":true,"session_id":"...","backend":"..."}` or an error object.
    #[func]
    fn session_open(&mut self, request_json: GString) -> GString {
        let config: SessionOpenRequest = match serde_json::from_str(&request_json.to_string()) {
            Ok(config) => config,
            Err(error) => return json_error(format!("invalid session_open JSON: {error}")),
        };
        match AiSession::open(RUNTIME.handle(), config) {
            Ok(session) => {
                if let Some(previous) = self.session.replace(Arc::clone(&session)) {
                    previous.close();
                }
                json_string(&json!({
                    "ok": true,
                    "session_id": session.id(),
                    "backend": session.backend().as_str(),
                }))
            }
            Err(error) => json_error(error),
        }
    }

    /// Input: `{"session_id":"...","capture":"...","concept_name":"","source_pane":""}`.
    /// Output includes the monotonic turn id and unique run id.
    #[func]
    fn session_prompt(&mut self, request_json: GString) -> GString {
        let raw = request_json.to_string();
        let value = match parse_object(&raw, "session_prompt") {
            Ok(value) => value,
            Err(error) => return json_error(error),
        };
        let session = match self.checked_session(&value) {
            Ok(session) => session,
            Err(error) => return json_error(error),
        };
        let request: SessionPromptRequest = match serde_json::from_value(value) {
            Ok(request) => request,
            Err(error) => return json_error(format!("invalid session_prompt JSON: {error}")),
        };
        match session.prompt(request) {
            Ok((turn_id, run_id)) => json_string(&json!({
                "ok": true,
                "session_id": session.id(),
                "turn_id": turn_id,
                "run_id": run_id,
            })),
            Err(error) => json_error(error),
        }
    }

    /// Input: `{"session_id":"...","max_events":128}`.
    /// Output: a JSON array of correlated event envelopes.
    #[func]
    fn session_poll(&mut self, request_json: GString) -> GString {
        let value = match parse_object(&request_json.to_string(), "session_poll") {
            Ok(value) => value,
            Err(error) => return json_error(error),
        };
        let session = match self.checked_session(&value) {
            Ok(session) => session,
            Err(error) => return json_error(error),
        };
        let max_events = value
            .get("max_events")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(128);
        match serde_json::to_value(session.poll(max_events)) {
            Ok(events) => json_string(&events),
            Err(error) => json_error(format!("failed to serialize events: {error}")),
        }
    }

    /// Input: `{"session_id":"..."}`.
    #[func]
    fn session_cancel(&mut self, request_json: GString) -> GString {
        let value = match parse_object(&request_json.to_string(), "session_cancel") {
            Ok(value) => value,
            Err(error) => return json_error(error),
        };
        let session = match self.checked_session(&value) {
            Ok(session) => session,
            Err(error) => return json_error(error),
        };
        json_string(&json!({
            "ok": true,
            "session_id": session.id(),
            "cancelled": session.cancel(),
        }))
    }

    /// Input: `{"session_id":"..."}`.
    #[func]
    fn session_close(&mut self, request_json: GString) -> GString {
        let value = match parse_object(&request_json.to_string(), "session_close") {
            Ok(value) => value,
            Err(error) => return json_error(error),
        };
        if let Err(error) = self.checked_session(&value) {
            return json_error(error);
        }
        let session = self.session.take().expect("checked active session");
        let session_id = session.id().to_string();
        session.close();
        json_string(&json!({
            "ok": true,
            "session_id": session_id,
            "closed": true,
        }))
    }

    /// Output: JSON array of `{kind,name,available}`.
    #[func]
    fn list_backends(&self) -> GString {
        let backends: Vec<Value> = AiSession::list_backends()
            .into_iter()
            .map(|backend| {
                json!({
                    "kind": backend.kind.as_str(),
                    "name": backend.name,
                    "available": backend.available,
                })
            })
            .collect();
        json_string(&Value::Array(backends))
    }

    fn checked_session(&self, request: &Value) -> Result<Arc<AiSession>, String> {
        let requested_id = request
            .get("session_id")
            .and_then(Value::as_str)
            .ok_or_else(|| "session_id is required".to_string())?;
        let session = self
            .session
            .as_ref()
            .ok_or_else(|| "no session is open".to_string())?;
        if requested_id != session.id() {
            return Err("session_id does not belong to this GptyAi instance".into());
        }
        Ok(Arc::clone(session))
    }
}

impl Drop for GptyAi {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            session.close();
        }
    }
}

fn parse_object(raw: &str, method: &str) -> Result<Value, String> {
    let value: Value =
        serde_json::from_str(raw).map_err(|error| format!("invalid {method} JSON: {error}"))?;
    if !value.is_object() {
        return Err(format!("{method} JSON must be an object"));
    }
    Ok(value)
}

fn json_string(value: &Value) -> GString {
    GString::from(
        &serde_json::to_string(value).unwrap_or_else(|_| {
            r#"{"ok":false,"error":"failed to serialize response"}"#.to_string()
        }),
    )
}

fn json_error(error: impl Into<String>) -> GString {
    json_string(&json!({"ok": false, "error": error.into()}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_parser_requires_object() {
        assert!(parse_object("[]", "test").is_err());
        assert!(parse_object(r#"{"session_id":"1"}"#, "test").is_ok());
    }
}
