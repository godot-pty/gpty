use gpty_core::types::PaneType;
use gpty_ipc::client::IpcClient;

/// The pane type names this command accepts: [`PaneType`]'s wire spellings
/// plus the legacy `observer`, which is still translated to `inspector` below
/// with a warning.
///
/// Derived, not listed: a literal here could only drift from `PaneType::as_str`,
/// which is the spelling the GUI registers (and the one serde emits).
fn valid_types() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = PaneType::ALL.iter().map(|t| t.as_str()).collect();
    names.push("observer");
    names
}
// Mirrors the IPC request shape one-to-one; grouping would obscure dispatch.
#[allow(clippy::too_many_arguments)]
pub async fn run(
    client: &IpcClient,
    pane_type: &str,
    command: Option<&str>,
    args: &[String],
    split: Option<&str>,
    title: Option<&str>,
    focus: bool,
    tags: &[String],
    json: bool,
) -> anyhow::Result<()> {
    // Validate pane type with "did you mean?" suggestions.
    let valid_types = valid_types();
    if !valid_types.contains(&pane_type) {
        let suggestion = super::closest_match(pane_type, &valid_types);
        let hint = match suggestion {
            Some(s) => format!(" — did you mean \"{s}\"?"),
            None => String::new(),
        };
        anyhow::bail!(
            "invalid pane type: \"{pane_type}\"{hint}\nValid types: {}",
            valid_types.join(", ")
        );
    }

    let wire_type = if pane_type == "observer" {
        eprintln!("warning: pane type \"observer\" is deprecated; using \"inspector\"");
        "inspector"
    } else {
        pane_type
    };
    let mut params = serde_json::json!({
        "type": wire_type,
        "focus": focus,
    });
    // A named side is a preference the GUI honours on the largest tile; with
    // none, it splits by that tile's aspect, as its own spawns do. Sending the
    // flag's old default here made every call ask for `bottom`.
    if let Some(side) = split {
        params["split"] = serde_json::Value::String(side.to_string());
    }
    if let Some(cmd) = command {
        params["command"] = serde_json::Value::String(cmd.to_string());
    }
    // argv for `command`; the GUI read path ignores it for every type but
    // cli_view, which runs the program directly instead of through a shell.
    if !args.is_empty() {
        params["args"] = serde_json::Value::Array(
            args.iter()
                .map(|a| serde_json::Value::String(a.clone()))
                .collect(),
        );
    }
    if let Some(t) = title {
        // The API key; the handler turns it into the pane's `title_label`
        // (its display title, not its addressable `pane_label`).
        params["title"] = serde_json::Value::String(t.to_string());
    }
    params["tags"] = serde_json::Value::Array(
        tags.iter()
            .map(|t| serde_json::Value::String(t.clone()))
            .collect(),
    );
    super::call_and_format(client, "newPane", params, json).await
}
