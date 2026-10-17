use serde::{Deserialize, Serialize};

use crate::protocol::JsonRpcError;

// ── Requests ─────────────────────────────────────────────

/// Parameters for the `newPane` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct NewPaneParams {
    #[serde(rename = "type")]
    pub pane_type: gpty_core::types::PaneType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Argument vector for `command` (cli_view only: the program is run
    /// directly, never through a shell).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default = "default_split")]
    pub split: SplitDirection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Pane tags for broadcast targeting (each sanitized like attachment_id).
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "default_true")]
    pub focus: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum SplitDirection {
    Left,
    Right,
    Top,
    Bottom,
}

fn default_split() -> SplitDirection {
    SplitDirection::Bottom
}

fn default_true() -> bool {
    true
}

/// Parameters for the `killPane` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct KillPaneParams {
    pub pane_id: String,
}

/// Parameters for the `focusPane` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct FocusPaneParams {
    pub pane_id: String,
}

/// Parameters for the `inject` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct InjectParams {
    pub pane_id: String,
    pub text: String,
}

/// Parameters for the `layoutSave` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct LayoutSaveParams {
    pub name: String,
}

/// Parameters for the `layoutLoad` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct LayoutLoadParams {
    pub name: String,
}

// ── Responses ────────────────────────────────────────────

/// Response for `newPane`.
#[derive(Debug, Serialize, Deserialize)]
pub struct NewPaneResponse {
    pub pane_id: String,
    pub label: String,
    #[serde(rename = "type")]
    pub pane_type: String,
}

/// A single pane entry for `listPanes`.
#[derive(Debug, Serialize, Deserialize)]
pub struct PaneInfo {
    pub id: String,
    pub label: String,
    #[serde(rename = "type")]
    pub pane_type: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub col: i64,
    pub row: i64,
    pub cspan: i64,
    pub rspan: i64,
    pub focused: bool,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// Parameters for the `broadcast` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct BroadcastParams {
    pub tags: Vec<String>,
    pub text: String,
}

/// Response for `listPanes`.
#[derive(Debug, Serialize, Deserialize)]
pub struct ListPanesResponse {
    pub panes: Vec<PaneInfo>,
    pub count: usize,
}

/// Generic success response.
#[derive(Debug, Serialize, Deserialize)]
pub struct SuccessResponse {
    pub success: bool,
}

/// Response for `layoutList`.
#[derive(Debug, Serialize, Deserialize)]
pub struct LayoutListResponse {
    pub layouts: Vec<String>,
}

/// Response for `version`.
#[derive(Debug, Serialize, Deserialize)]
pub struct VersionResponse {
    pub version: String,
    pub protocol: String,
}

// ── Error helper ─────────────────────────────────────────

/// Build an IPC error dict (for JSON response).
pub fn ipc_error(code: i64, message: impl Into<String>) -> JsonRpcError {
    JsonRpcError::new(code, message)
}

pub fn method_not_found(method: &str) -> JsonRpcError {
    JsonRpcError::new(
        JsonRpcError::METHOD_NOT_FOUND,
        format!("Unknown method: {method}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_new_pane_params() {
        let params = NewPaneParams {
            pane_type: gpty_core::types::PaneType::Terminal,
            command: Some("htop".into()),
            args: Vec::new(),
            split: SplitDirection::Bottom,
            title: Some("My Pane".into()),
            focus: true,
            tags: vec![],
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: NewPaneParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_type, gpty_core::types::PaneType::Terminal);
        assert_eq!(back.command.as_deref(), Some("htop"));
        assert!(matches!(back.split, SplitDirection::Bottom));
        assert_eq!(back.title.as_deref(), Some("My Pane"));
        assert!(back.focus);
    }

    #[test]
    fn new_pane_params_defaults() {
        let json = r#"{"type":"terminal","focus":true}"#;
        let params: NewPaneParams = serde_json::from_str(json).unwrap();
        assert!(params.command.is_none());
        assert!(matches!(params.split, SplitDirection::Bottom));
        assert!(params.title.is_none());
    }

    #[test]
    fn roundtrip_split_direction() {
        for dir in [
            SplitDirection::Left,
            SplitDirection::Right,
            SplitDirection::Top,
            SplitDirection::Bottom,
        ] {
            let json = serde_json::to_string(&dir).unwrap();
            let back: SplitDirection = serde_json::from_str(&json).unwrap();
            assert_eq!(back, dir);
        }
    }

    // The pairs below pin each type to the literal JSON the GUI's
    // `ipc_handlers.gd` reads and writes (`pane_id`, `text`, `name`, `tags`,
    // `success`, `layouts`, `panes`, `count`). Serialization is compared
    // against the *whole* object, so a renamed, added or dropped key fails;
    // deserialization starts from the literal a client sends, so a rename
    // that serde applied to both directions cannot hide.

    #[test]
    fn wire_kill_pane_params() {
        let params = KillPaneParams {
            pane_id: "T3".into(),
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            serde_json::json!({"pane_id": "T3"})
        );
        let back: KillPaneParams = serde_json::from_str(r#"{"pane_id":"active"}"#).unwrap();
        assert_eq!(back.pane_id, "active");
    }

    #[test]
    fn wire_focus_pane_params() {
        let params = FocusPaneParams {
            pane_id: "T1".into(),
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            serde_json::json!({"pane_id": "T1"})
        );
        let back: FocusPaneParams = serde_json::from_str(r#"{"pane_id":"T9"}"#).unwrap();
        assert_eq!(back.pane_id, "T9");
    }

    #[test]
    fn wire_inject_params() {
        let params = InjectParams {
            pane_id: "T2".into(),
            text: "ls -la".into(),
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            serde_json::json!({"pane_id": "T2", "text": "ls -la"})
        );
        let back: InjectParams =
            serde_json::from_str(r#"{"pane_id":"T2","text":"echo \"hi\"\n"}"#).unwrap();
        assert_eq!(
            (back.pane_id.as_str(), back.text.as_str()),
            ("T2", "echo \"hi\"\n")
        );
    }

    #[test]
    fn a_request_missing_a_required_field_is_rejected() {
        // The server relies on this to answer "invalid params" rather than
        // act on an empty pane id.
        assert!(serde_json::from_str::<KillPaneParams>("{}").is_err());
        assert!(serde_json::from_str::<InjectParams>(r#"{"pane_id":"T1"}"#).is_err());
        assert!(serde_json::from_str::<InjectParams>(r#"{"text":"x"}"#).is_err());
        assert!(serde_json::from_str::<BroadcastParams>(r#"{"text":"x"}"#).is_err());
        assert!(serde_json::from_str::<LayoutLoadParams>("{}").is_err());
    }

    #[test]
    fn wire_broadcast_params() {
        let params = BroadcastParams {
            tags: vec!["ci".into(), "backend".into()],
            text: "make test".into(),
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            serde_json::json!({"tags": ["ci", "backend"], "text": "make test"})
        );
        let back: BroadcastParams = serde_json::from_str(r#"{"tags":["ci"],"text":"go"}"#).unwrap();
        assert_eq!(
            (back.tags, back.text.as_str()),
            (vec!["ci".to_string()], "go")
        );
    }

    #[test]
    fn wire_success_response() {
        assert_eq!(
            serde_json::to_value(SuccessResponse { success: true }).unwrap(),
            serde_json::json!({"success": true})
        );
        let back: SuccessResponse = serde_json::from_str(r#"{"success":false}"#).unwrap();
        assert!(!back.success, "false must stay false, not default to true");
    }

    #[test]
    fn roundtrip_new_pane_response() {
        let resp = NewPaneResponse {
            pane_id: "pane-abc12345".into(),
            label: "T5".into(),
            pane_type: "code_viewer".into(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: NewPaneResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_id, "pane-abc12345");
        assert_eq!(back.label, "T5");
        assert_eq!(back.pane_type, "code_viewer");
    }

    #[test]
    fn roundtrip_pane_info() {
        let info = PaneInfo {
            id: "pane-abc12345".into(),
            label: "T1".into(),
            pane_type: "terminal".into(),
            title: "bash".into(),
            command: Some("/bin/zsh".into()),
            col: 0,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: true,
            tags: vec!["ci".into()],
        };
        let json = serde_json::to_string(&info).unwrap();
        let back: PaneInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "pane-abc12345");
        assert_eq!(back.command.as_deref(), Some("/bin/zsh"));
    }

    #[test]
    fn wire_list_panes_response() {
        let resp = ListPanesResponse {
            panes: vec![PaneInfo {
                id: "pane-abc12345".into(),
                label: "T1".into(),
                pane_type: "terminal".into(),
                title: "bash".into(),
                command: None,
                col: 0,
                row: 0,
                cspan: 60,
                rspan: 120,
                focused: true,
                tags: vec!["ci".into()],
            }],
            count: 1,
        };
        assert_eq!(
            serde_json::to_value(&resp).unwrap(),
            serde_json::json!({
                "panes": [{
                    "id": "pane-abc12345", "label": "T1", "type": "terminal",
                    "title": "bash", "col": 0, "row": 0, "cspan": 60, "rspan": 120,
                    "focused": true, "tags": ["ci"],
                }],
                "count": 1,
            }),
            "`command` is omitted when absent, and the type key is spelled `type`"
        );
        // What the GUI answers: a pane with no `tags` key (an older GUI) still
        // parses, with no tags.
        let back: ListPanesResponse = serde_json::from_str(
            r#"{"panes":[{"id":"p","label":"T1","type":"terminal","title":"t",
                "col":1,"row":2,"cspan":3,"rspan":4,"focused":false}],"count":1}"#,
        )
        .unwrap();
        assert_eq!(back.count, 1);
        assert_eq!(
            (
                back.panes[0].col,
                back.panes[0].row,
                back.panes[0].cspan,
                back.panes[0].rspan
            ),
            (1, 2, 3, 4)
        );
        assert!(back.panes[0].tags.is_empty());
    }

    #[test]
    fn wire_layout_params_use_name() {
        assert_eq!(
            serde_json::to_value(LayoutSaveParams {
                name: "mysetup".into()
            })
            .unwrap(),
            serde_json::json!({"name": "mysetup"})
        );
        assert_eq!(
            serde_json::to_value(LayoutLoadParams {
                name: "mysetup".into()
            })
            .unwrap(),
            serde_json::json!({"name": "mysetup"})
        );
        let save: LayoutSaveParams = serde_json::from_str(r#"{"name":"a b"}"#).unwrap();
        let load: LayoutLoadParams = serde_json::from_str(r#"{"name":"a b"}"#).unwrap();
        assert_eq!((save.name.as_str(), load.name.as_str()), ("a b", "a b"));
    }

    #[test]
    fn wire_layout_list_response() {
        assert_eq!(
            serde_json::to_value(LayoutListResponse {
                layouts: vec!["setup1".into(), "setup2".into()],
            })
            .unwrap(),
            serde_json::json!({"layouts": ["setup1", "setup2"]})
        );
        let back: LayoutListResponse = serde_json::from_str(r#"{"layouts":[]}"#).unwrap();
        assert!(back.layouts.is_empty());
    }

    #[test]
    fn wire_version_response_is_exactly_two_keys() {
        assert_eq!(
            serde_json::to_value(VersionResponse {
                version: "0.3.0".into(),
                protocol: "1.0".into(),
            })
            .unwrap(),
            serde_json::json!({"version": "0.3.0", "protocol": "1.0"})
        );
        let back: VersionResponse =
            serde_json::from_str(r#"{"version":"9.9.9","protocol":"2.0"}"#).unwrap();
        assert_eq!(
            (back.version.as_str(), back.protocol.as_str()),
            ("9.9.9", "2.0")
        );
    }

    #[test]
    fn ipc_error_helpers() {
        let err = ipc_error(-32000, "custom error");
        assert_eq!(err.code, -32000);
        assert!(err.message.contains("custom error"));

        let nf = method_not_found("badMethod");
        assert_eq!(nf.code, JsonRpcError::METHOD_NOT_FOUND);
        assert!(nf.message.contains("badMethod"));
    }

    // ── Wire-format structural tests ─────────────────────────────
    // These verify the concrete JSON shape matches the IPC contract.
    // Roundtrip tests cannot catch field renames (both serialize and
    // deserialize use the new name — the wire breaks, the test passes).

    #[test]
    fn wire_new_pane_params_full() {
        let params = NewPaneParams {
            pane_type: gpty_core::types::PaneType::Terminal,
            command: Some("htop".into()),
            args: vec!["-c".into(), "printf hi".into()],
            split: SplitDirection::Right,
            title: None,
            focus: false,
            tags: vec!["ci".into()],
        };
        let v = serde_json::to_value(&params).unwrap();
        assert_eq!(v["type"], "terminal");
        assert_eq!(v["command"], "htop");
        assert_eq!(v["args"], serde_json::json!(["-c", "printf hi"]));
        assert_eq!(v["split"], "Right");
        assert_eq!(v["focus"], false);
        assert!(
            v.get("title").is_none(),
            "None fields should skip serialization"
        );
    }

    #[test]
    fn wire_new_pane_params_minimal() {
        let params = NewPaneParams {
            pane_type: gpty_core::types::PaneType::CodeViewer,
            command: None,
            args: Vec::new(),
            split: SplitDirection::Bottom,
            title: None,
            focus: true,
            tags: vec![],
        };
        let v = serde_json::to_value(&params).unwrap();
        // The wire spelling is `PaneType::as_str()` — the GUI's registry key.
        assert_eq!(v["type"], "code_viewer");
        assert_eq!(v["split"], "Bottom");
        assert!(
            v.get("args").is_none(),
            "empty args should skip serialization"
        );
        assert!(v.get("command").is_none());
        assert!(v.get("title").is_none());
    }

    #[test]
    fn wire_split_direction_values() {
        assert_eq!(serde_json::to_value(SplitDirection::Left).unwrap(), "Left");
        assert_eq!(
            serde_json::to_value(SplitDirection::Right).unwrap(),
            "Right"
        );
        assert_eq!(serde_json::to_value(SplitDirection::Top).unwrap(), "Top");
        assert_eq!(
            serde_json::to_value(SplitDirection::Bottom).unwrap(),
            "Bottom"
        );
    }

    #[test]
    fn wire_pane_info_skips_optional() {
        let info = PaneInfo {
            id: "pane-abc12345".into(),
            label: "T1".into(),
            pane_type: "terminal".into(),
            title: "bash".into(),
            command: None,
            col: 0,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: true,
            tags: vec![],
        };
        let v = serde_json::to_value(&info).unwrap();
        assert_eq!(v["id"], "pane-abc12345");
        assert_eq!(v["type"], "terminal");
        assert!(
            v.get("command").is_none(),
            "optional command must be omitted"
        );
    }

    #[test]
    fn wire_pane_info_with_command() {
        let info = PaneInfo {
            id: "pane-abc67890".into(),
            label: "T2".into(),
            pane_type: "terminal".into(),
            title: "zsh".into(),
            command: Some("/bin/zsh".into()),
            col: 1,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: false,
            tags: vec!["backend".into()],
        };
        let v = serde_json::to_value(&info).unwrap();
        assert_eq!(v["command"], "/bin/zsh");
    }

    #[test]
    fn wire_new_pane_response_shape() {
        let resp = NewPaneResponse {
            pane_id: "pane-abc12345".into(),
            label: "T5".into(),
            pane_type: "code_viewer".into(),
        };
        let v = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["pane_id"], "pane-abc12345");
        assert_eq!(v["label"], "T5");
        assert_eq!(v["type"], "code_viewer");
    }

    #[test]
    fn wire_version_response_shape() {
        let resp = VersionResponse {
            version: "0.3.0".into(),
            protocol: "1.0".into(),
        };
        let v = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["version"], "0.3.0");
        assert_eq!(v["protocol"], "1.0");
    }
}
