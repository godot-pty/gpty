//! Godot bridge for the `cli_view` pane: one child CLI whose stdout and
//! stderr the pane renders as plain text lines.
//!
//! The process itself lives in [`gpty_core::cli`]; this class is the FFI edge.
//! It parses what GDScript sends, checks it, and hands the argv to the core.
//! The caps are enforced here as well as in the core — a GDScript caller can
//! pass anything, and a pane built from a saved tile or from IPC is untrusted
//! input all the way down, so neither layer is the only gate.

use godot::builtin::PackedStringArray;
use godot::prelude::*;
use gpty_core::cli::{self, CliProcess};
use serde_json::{Value, json};

/// Longest command (program) accepted, in characters.
const MAX_COMMAND_CHARS: usize = 1024;
/// Most arguments accepted.
const MAX_ARGS: usize = 32;
/// Longest single argument accepted, in characters.
const MAX_ARG_CHARS: usize = 4096;
/// The replacement character Godot's lossy string conversion leaves behind.
const REPLACEMENT: char = '\u{FFFD}';

#[derive(GodotClass)]
#[class(base = Node)]
struct GptyCliView {
    /// The running child; `None` before the first `start` and after `stop`.
    process: Option<CliProcess>,
    base: Base<Node>,
}

#[godot_api]
impl INode for GptyCliView {
    fn init(base: Base<Node>) -> Self {
        Self {
            process: None,
            base,
        }
    }
}

#[godot_api]
impl GptyCliView {
    /// Input: `{"command":"prog","args":["-x"]}` — argv, never a shell.
    /// Output: `{"ok":true,"pid":N}` or `{"ok":false,"error":"..."}`.
    #[func]
    fn start(&mut self, config_json: GString) -> GString {
        let raw = config_json.to_string();
        let value: Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(error) => return json_error(format!("invalid start JSON: {error}")),
        };
        if !value.is_object() {
            return json_error("start JSON must be an object");
        }
        let command = match value.get("command") {
            Some(Value::String(command)) => command.as_str(),
            _ => return json_error("start needs a \"command\" string"),
        };
        if let Err(error) = check_command(command) {
            return json_error(error);
        }
        let args = match parse_args(&value) {
            Ok(args) => args,
            Err(error) => return json_error(error),
        };

        // Replace before spawning: restarting a pane from its settings must
        // not leave the previous CLI (and its helpers) running behind the new
        // one, and the old process would still be holding that pane's output.
        self.stop();
        match CliProcess::spawn(command, &args) {
            Ok(process) => {
                // A process we just spawned is running, so it has a pid; the
                // fallback only keeps the shape stable if that ever changes.
                let pid = process.pid().unwrap_or(0);
                self.process = Some(process);
                GString::from(json!({"ok": true, "pid": pid}).to_string().as_str())
            }
            Err(error) => json_error(error),
        }
    }

    /// Every complete line queued since the last call, stdout and stderr
    /// merged. Non-blocking; empty when the pane has no process.
    #[func]
    fn poll_lines(&mut self) -> PackedStringArray {
        let mut lines = PackedStringArray::new();
        let Some(process) = self.process.as_ref() else {
            return lines;
        };
        for line in process.poll_lines() {
            lines.push(line.as_str());
        }
        lines
    }

    /// JSON: `{program, args, pid, running, exit_code, exit_reason}` — the
    /// shape [`gpty_core::cli::CliProcess::status_json`] documents. A pane
    /// that never started reports the idle shape instead.
    #[func]
    fn status_json(&mut self) -> GString {
        match self.process.as_mut() {
            Some(process) => GString::from(process.status_json().as_str()),
            None => GString::from(cli::idle_status_json().as_str()),
        }
    }

    /// Kill the child and its process group. Safe with nothing running.
    #[func]
    fn stop(&mut self) {
        if let Some(mut process) = self.process.take() {
            process.stop();
        }
    }
}

impl Drop for GptyCliView {
    fn drop(&mut self) {
        if let Some(mut process) = self.process.take() {
            process.stop();
        }
    }
}

/// Read the optional `args` array, holding every entry to the same caps as
/// the command. A missing or `null` array means "no arguments".
fn parse_args(value: &Value) -> Result<Vec<String>, String> {
    let items = match value.get("args") {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Array(items)) => items,
        Some(_) => return Err("\"args\" must be an array of strings".to_string()),
    };
    if items.len() > MAX_ARGS {
        return Err(format!("at most {MAX_ARGS} arguments are accepted"));
    }
    let mut args = Vec::with_capacity(items.len());
    for item in items {
        let Some(arg) = item.as_str() else {
            return Err("every argument must be a string".to_string());
        };
        check_arg(arg)?;
        args.push(arg.to_string());
    }
    Ok(args)
}

/// Refuse a command that is empty, oversized, or mangled in transit.
fn check_command(command: &str) -> Result<(), String> {
    if command.is_empty() {
        return Err("command must not be empty".to_string());
    }
    check_length(command, MAX_COMMAND_CHARS, "command")?;
    check_encoding(command, "command")
}

/// Refuse an argument that is oversized or mangled in transit.
fn check_arg(arg: &str) -> Result<(), String> {
    check_length(arg, MAX_ARG_CHARS, "argument")?;
    check_encoding(arg, "argument")
}

fn check_length(value: &str, max: usize, what: &str) -> Result<(), String> {
    let count = value.chars().count();
    if count > max {
        return Err(format!("{what} is {count} characters, over the {max} cap"));
    }
    Ok(())
}

/// Refuse a value the Godot-to-Rust conversion substituted a character into.
///
/// `GString` is UTF-32 and may hold a lone surrogate or an invalid sequence,
/// which `to_string` turns into U+FFFD. What reaches `execvp` would then be a
/// *different* program or argument than the one configured, so the pane
/// refuses rather than running something the user never asked for.
fn check_encoding(value: &str, what: &str) -> Result<(), String> {
    if value.contains(REPLACEMENT) {
        return Err(format!("{what} contains U+FFFD (mangled text)"));
    }
    Ok(())
}

fn json_error(error: impl Into<String>) -> GString {
    GString::from(
        json!({"ok": false, "error": error.into()})
            .to_string()
            .as_str(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args_from(raw: &str) -> Result<Vec<String>, String> {
        parse_args(&serde_json::from_str(raw).unwrap())
    }

    #[test]
    fn args_are_optional() {
        assert_eq!(args_from("{}").unwrap(), Vec::<String>::new());
        assert_eq!(args_from(r#"{"args":null}"#).unwrap(), Vec::<String>::new());
        assert_eq!(
            args_from(r#"{"args":["-c","printf hi"]}"#).unwrap(),
            ["-c", "printf hi"]
        );
    }

    #[test]
    fn args_reject_the_wrong_shape() {
        assert!(args_from(r#"{"args":"-c"}"#).is_err());
        assert!(args_from(r#"{"args":[1]}"#).is_err());
        assert!(
            args_from(&format!(
                r#"{{"args":{}}}"#,
                serde_json::to_string(&vec!["x"; MAX_ARGS + 1]).unwrap()
            ))
            .is_err()
        );
    }

    #[test]
    fn the_caps_hold_one_past_the_boundary() {
        assert!(check_command("sh").is_ok());
        assert!(check_command("").is_err());
        assert!(check_command(&"x".repeat(MAX_COMMAND_CHARS)).is_ok());
        assert!(check_command(&"x".repeat(MAX_COMMAND_CHARS + 1)).is_err());
        assert!(check_arg(&"x".repeat(MAX_ARG_CHARS)).is_ok());
        assert!(check_arg(&"x".repeat(MAX_ARG_CHARS + 1)).is_err());
        assert!(check_command("bad\u{FFFD}prog").is_err());
        assert!(check_arg("bad\u{FFFD}arg").is_err());
    }
}
