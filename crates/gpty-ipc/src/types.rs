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
    #[serde(default = "default_split")]
    pub split: SplitDirection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
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
    #[serde(rename = "type")]
    pub pane_type: String,
}

/// A single pane entry for `listPanes`.
#[derive(Debug, Serialize, Deserialize)]
pub struct PaneInfo {
    pub id: String,
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
            split: SplitDirection::Bottom,
            title: Some("My Pane".into()),
            focus: true,
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

    #[test]
    fn roundtrip_kill_pane_params() {
        let params = KillPaneParams {
            pane_id: "T3".into(),
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: KillPaneParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_id, "T3");
    }

    #[test]
    fn roundtrip_focus_pane_params() {
        let params = FocusPaneParams {
            pane_id: "T1".into(),
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: FocusPaneParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_id, "T1");
    }

    #[test]
    fn roundtrip_inject_params() {
        let params = InjectParams {
            pane_id: "T2".into(),
            text: "ls -la".into(),
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: InjectParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_id, "T2");
        assert_eq!(back.text, "ls -la");
    }

    #[test]
    fn roundtrip_success_response() {
        let resp = SuccessResponse { success: true };
        let json = serde_json::to_string(&resp).unwrap();
        let back: SuccessResponse = serde_json::from_str(&json).unwrap();
        assert!(back.success);
    }

    #[test]
    fn roundtrip_new_pane_response() {
        let resp = NewPaneResponse {
            pane_id: "T5".into(),
            pane_type: "code_viewer".into(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: NewPaneResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pane_id, "T5");
        assert_eq!(back.pane_type, "code_viewer");
    }

    #[test]
    fn roundtrip_pane_info() {
        let info = PaneInfo {
            id: "T1".into(),
            pane_type: "terminal".into(),
            title: "bash".into(),
            command: Some("/bin/zsh".into()),
            col: 0,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: true,
        };
        let json = serde_json::to_string(&info).unwrap();
        let back: PaneInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "T1");
        assert_eq!(back.command.as_deref(), Some("/bin/zsh"));
    }

    #[test]
    fn roundtrip_list_panes_response() {
        let resp = ListPanesResponse {
            panes: vec![PaneInfo {
                id: "T1".into(),
                pane_type: "terminal".into(),
                title: "bash".into(),
                command: None,
                col: 0,
                row: 0,
                cspan: 1,
                rspan: 1,
                focused: true,
            }],
            count: 1,
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: ListPanesResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(back.count, 1);
        assert_eq!(back.panes.len(), 1);
    }

    #[test]
    fn roundtrip_layout_save_params() {
        let params = LayoutSaveParams {
            name: "mysetup".into(),
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: LayoutSaveParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.name, "mysetup");
    }

    #[test]
    fn roundtrip_layout_load_params() {
        let params = LayoutLoadParams {
            name: "mysetup".into(),
        };
        let json = serde_json::to_string(&params).unwrap();
        let back: LayoutLoadParams = serde_json::from_str(&json).unwrap();
        assert_eq!(back.name, "mysetup");
    }

    #[test]
    fn roundtrip_layout_list_response() {
        let resp = LayoutListResponse {
            layouts: vec!["setup1".into(), "setup2".into()],
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: LayoutListResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(back.layouts.len(), 2);
    }

    #[test]
    fn roundtrip_version_response() {
        let resp = VersionResponse {
            version: "0.3.0".into(),
            protocol: "1.0".into(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: VersionResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, "0.3.0");
        assert_eq!(back.protocol, "1.0");
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
            split: SplitDirection::Right,
            title: None,
            focus: false,
        };
        let v = serde_json::to_value(&params).unwrap();
        assert_eq!(v["type"], "terminal");
        assert_eq!(v["command"], "htop");
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
            split: SplitDirection::Bottom,
            title: None,
            focus: true,
        };
        let v = serde_json::to_value(&params).unwrap();
        assert_eq!(v["type"], "code-viewer");
        assert_eq!(v["split"], "Bottom");
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
            id: "T1".into(),
            pane_type: "terminal".into(),
            title: "bash".into(),
            command: None,
            col: 0,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: true,
        };
        let v = serde_json::to_value(&info).unwrap();
        assert_eq!(v["id"], "T1");
        assert_eq!(v["type"], "terminal");
        assert!(
            v.get("command").is_none(),
            "optional command must be omitted"
        );
    }

    #[test]
    fn wire_pane_info_with_command() {
        let info = PaneInfo {
            id: "T2".into(),
            pane_type: "terminal".into(),
            title: "zsh".into(),
            command: Some("/bin/zsh".into()),
            col: 1,
            row: 0,
            cspan: 1,
            rspan: 1,
            focused: false,
        };
        let v = serde_json::to_value(&info).unwrap();
        assert_eq!(v["command"], "/bin/zsh");
    }

    #[test]
    fn wire_new_pane_response_shape() {
        let resp = NewPaneResponse {
            pane_id: "T5".into(),
            pane_type: "code_viewer".into(),
        };
        let v = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["pane_id"], "T5");
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
