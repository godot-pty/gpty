use serde::{Deserialize, Serialize};

use crate::protocol::JsonRpcError;

// ── Requests ─────────────────────────────────────────────

/// Parameters for the `newPane` method.
#[derive(Debug, Serialize, Deserialize)]
pub struct NewPaneParams {
    #[serde(rename = "type")]
    pub pane_type: godopty_core::types::PaneType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default = "default_split")]
    pub split: SplitDirection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default = "default_true")]
    pub focus: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
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
