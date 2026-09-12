use std::io::{self, BufRead, Read, Write};

use clap::CommandFactory;
use gpty_ipc::client::IpcClient;
use gpty_ipc::protocol::{JsonRpcError, Request, build_error, build_response};

/// Map a kebab-case MCP tool name to the camelCase IPC method the GUI
/// registers: `pane-read` → `paneRead`, `broadcast` → `broadcast`.
///
/// Derived rather than table-driven: the tool name and the method name are
/// the same identifier in two conventions, and a table silently drifts as
/// soon as a command is added. The previous table omitted `pane-*` and
/// `concept-*`, so six tools answered -32601.
fn tool_to_ipc_method(tool_name: &str) -> String {
    let mut out = String::with_capacity(tool_name.len());
    let mut upper_next = false;
    for ch in tool_name.chars() {
        match ch {
            '-' => upper_next = true,
            _ if upper_next => {
                out.extend(ch.to_uppercase());
                upper_next = false;
            }
            _ => out.push(ch),
        }
    }
    out
}

/// Handle daemon tools locally (no IPC needed). Returns Some(result) if handled, None if not a daemon tool.
async fn run_daemon_tool(tool_name: &str, client: &IpcClient) -> Option<serde_json::Value> {
    match tool_name {
        "daemon-start" => {
            Some(serde_json::json!({"status": "GUI daemon auto-spawns on first tool call"}))
        }
        "daemon-stop" => match client.call("shutdown", Some(serde_json::Value::Null)).await {
            Ok(r) => r.result,
            Err(_) => Some(serde_json::json!({"status": "GUI not running"})),
        },
        "daemon-status" => match client.call("version", None).await {
            Ok(r) => r.result,
            Err(_) => Some(serde_json::json!({"version": null, "status": "not running"})),
        },
        _ => None,
    }
}

/// Largest request accepted from the MCP client, matching the control
/// socket's own request cap (`gpty_ipc::server::MAX_REQUEST_LEN`).
const MAX_MESSAGE_LEN: usize = 64 * 1024;

/// Read and throw away the rest of an oversized line, so the next iteration
/// starts at a message boundary instead of inside the previous one.
fn discard_line(reader: &mut impl io::BufRead) -> io::Result<()> {
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(());
        }
        match available.iter().position(|b| *b == b'\n') {
            Some(at) => {
                reader.consume(at + 1);
                return Ok(());
            }
            None => {
                let len = available.len();
                reader.consume(len);
            }
        }
    }
}

/// Run as an MCP server over stdio: read JSON-RPC from stdin, forward to IPC, write to stdout.
pub async fn run(client: &IpcClient) -> anyhow::Result<()> {
    let stdin = io::stdin();
    let mut reader = io::BufReader::new(stdin.lock());
    let mut stdout = io::stdout();

    // Computed once: `tools/call` must reject any name that is not an
    // advertised tool (see `mcp_tool_names`).
    let allowed_tools = super::schema::mcp_tool_names(&crate::Cli::command());

    let mut line = Vec::new();
    loop {
        line.clear();
        // Same ceiling the control socket applies to a request. `lines()`
        // buffered a whole line whatever its length, so a runaway client
        // could grow `gpty mcp` without bound; anything past the cap is
        // refused and the rest of that line is discarded.
        let read = Read::take(&mut reader, MAX_MESSAGE_LEN as u64).read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if line.len() >= MAX_MESSAGE_LEN && !line.ends_with(b"\n") {
            discard_line(&mut reader)?;
            let resp = build_error(
                0,
                JsonRpcError::new(
                    JsonRpcError::INVALID_REQUEST,
                    format!("Request exceeds {MAX_MESSAGE_LEN} bytes"),
                ),
            );
            writeln!(stdout, "{}", serde_json::to_string(&resp)?)?;
            stdout.flush()?;
            continue;
        }
        let line = String::from_utf8_lossy(&line).trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = build_error(
                    0,
                    JsonRpcError::new(JsonRpcError::PARSE_ERROR, format!("Parse error: {e}")),
                );
                writeln!(stdout, "{}", serde_json::to_string(&resp)?)?;
                stdout.flush()?;
                continue;
            }
        };

        if req.is_notification() {
            continue;
        }

        // Present for every request that reaches here (notifications are
        // dropped above); fall back to 0 only to satisfy the response builder.
        let id = req.id.unwrap_or(0);

        let resp = match req.method.as_str() {
            "tools/list" => {
                let cmd = crate::Cli::command();
                let tools = super::schema::build_mcp_tools_inline(&cmd);
                build_response(id, tools)
            }
            "tools/call" => {
                let params = req.params.unwrap_or(serde_json::Value::Null);
                let tool_name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);

                if !allowed_tools.iter().any(|name| name == tool_name) {
                    build_error(
                        id,
                        JsonRpcError::new(
                            JsonRpcError::INVALID_PARAMS,
                            format!("Unknown tool: {tool_name}"),
                        ),
                    )
                // Daemon tools are handled locally (no GUI needed)
                } else if let Some(result) = run_daemon_tool(tool_name, client).await {
                    build_response(id, result)
                } else {
                    // Map kebab-case tool name to camelCase IPC method
                    let ipc_method = tool_to_ipc_method(tool_name);
                    match client.call(&ipc_method, Some(args)).await {
                        Ok(r) => {
                            if let Some(err) = r.error {
                                build_error(id, err)
                            } else {
                                build_response(id, r.result.unwrap_or(serde_json::Value::Null))
                            }
                        }
                        Err(e) => build_error(
                            id,
                            JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, e.to_string()),
                        ),
                    }
                }
            }
            "initialize" => build_response(
                id,
                serde_json::json!({
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "gpty", "version": env!("CARGO_PKG_VERSION")},
                    "capabilities": {"tools": {}}
                }),
            ),
            _ => build_error(
                id,
                JsonRpcError::new(
                    JsonRpcError::METHOD_NOT_FOUND,
                    format!("Unknown MCP method: {}", req.method),
                ),
            ),
        };

        writeln!(stdout, "{}", serde_json::to_string(&resp)?)?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// The IPC server's registrations, read from where they happen
    /// (`start_ipc_server_inner`): `version` and `shutdown` are answered in
    /// Rust, everything else is queued for GDScript.
    const IPC_SERVER_SRC: &str = include_str!("../../../../crates/gpty-gdext/src/ipc.rs");
    /// The other half of that vocabulary: the arms of
    /// `WorkspaceIpcHandlers.handle`, plus the request the workspace's own
    /// per-frame loop intercepts before dispatching (`paneWait`, whose
    /// response lands frames later).
    const IPC_HANDLERS_SRC: &str =
        include_str!("../../../../godot/scenes/terminal/ipc_handlers.gd");
    const WORKSPACE_SRC: &str = include_str!("../../../../godot/scenes/terminal/workspace.gd");
    /// The event listener's registrations. It is a second surface with its own
    /// method set (`gpty state` submits on it), so the CLI's literals have to be
    /// checked against both.
    const OMP_EVENTS_SRC: &str = include_str!("../../../../crates/gpty-gdext/src/omp_events.rs");

    /// The whole surface: routed methods plus the ones answered in Rust.
    fn registered_methods() -> BTreeSet<String> {
        let mut surface = rust_array_entries(IPC_SERVER_SRC, "let gdscript_methods = [");
        surface.extend(rust_local_methods(IPC_SERVER_SRC));
        surface
    }

    /// Methods the event listener answers, read from where it registers them.
    ///
    /// AGENTS.md states the listener serves exactly these three "and nothing
    /// else" — it is reachable by any same-UID process, and submission is gated
    /// by a per-PTY capability rather than by `GPTY_SECRET` — so a fourth
    /// method is new attack surface and has to change this list deliberately.
    fn event_listener_methods() -> BTreeSet<String> {
        let methods = rust_local_methods(OMP_EVENTS_SRC);
        let expected: BTreeSet<String> = ["eventsPoll", "ompEvent", "subscribe"]
            .into_iter()
            .map(str::to_string)
            .collect();
        assert_eq!(
            methods, expected,
            "the event listener's method set changed — a new method there is new \
             surface on a socket any same-UID process can reach"
        );
        methods
    }

    /// Entries of the Rust array literal whose `let <name> = [` is at `marker`.
    fn rust_array_entries(src: &str, marker: &str) -> BTreeSet<String> {
        let start = src
            .find(marker)
            .unwrap_or_else(|| panic!("`{marker}` not found in the IPC server"));
        let block = &src[start + marker.len()..];
        let end = block.find("];").expect("array literal is terminated");
        block[..end]
            .lines()
            .filter_map(|line| line.trim().strip_prefix('"')?.strip_suffix("\","))
            .map(str::to_string)
            .collect()
    }

    /// Methods the server answers in Rust, without the GDScript hop.
    fn rust_local_methods(src: &str) -> BTreeSet<String> {
        src.lines()
            .filter_map(|line| {
                let line = line.trim();
                let rest = line.strip_prefix("server.register(\"")?;
                if line.contains("make_gdscript_handler") {
                    return None;
                }
                rest.split('"').next().map(str::to_string)
            })
            .collect()
    }

    /// Top-level arms of the GDScript dispatch — the methods `handle` answers.
    ///
    /// Arms sit at two tabs inside the `match`; every string nested in a
    /// handler body is deeper, so indentation is what separates the
    /// vocabulary from the payload.
    fn gdscript_dispatch_arms(src: &str) -> BTreeSet<String> {
        src.lines()
            .filter_map(|line| line.strip_prefix("\t\t\"")?.split('"').next())
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// Methods the workspace intercepts in `_poll_ipc_requests` before it
    /// reaches the dispatcher.
    fn workspace_special_methods(src: &str) -> BTreeSet<String> {
        src.lines()
            .filter_map(|line| line.strip_prefix("\t\tif method == \"")?.split('"').next())
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// Method literals passed to the IPC client by the CLI's command modules.
    ///
    /// Scanned from source because the call sites are spread over
    /// `src/commands/*.rs`; the directory is read at test time, so a new
    /// command file is covered without being listed here.
    fn cli_call_site_methods() -> BTreeSet<String> {
        const MARKERS: [&str; 2] = ["call_and_format(", ".call("];
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/commands");
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
            .map(|entry| entry.expect("directory entry").path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "rs"))
            .collect();
        files.sort();
        assert!(
            !files.is_empty(),
            "no command sources under {}",
            dir.display()
        );

        let mut methods = BTreeSet::new();
        for path in files {
            let src = std::fs::read_to_string(&path).expect("read a command source");
            for marker in MARKERS {
                for (at, _) in src.match_indices(marker) {
                    if let Some(name) = first_argument_literal(&src[at + marker.len()..]) {
                        methods.insert(name);
                    }
                }
            }
        }
        methods
    }

    /// The identifier literal in a call's argument list, if it has one:
    /// `client.call("paneWait", …)` and `call_and_format(&client, "paneWait",
    /// …)` both hit it, while `client.call(&ipc_method, …)` — the derived
    /// name in this module — has no literal to check.
    fn first_argument_literal(args: &str) -> Option<String> {
        let mut depth = 1usize; // the '(' the marker ended with
        let mut end = args.len();
        for (i, ch) in args.char_indices() {
            match ch {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        end = i;
                        break;
                    }
                }
                _ => {}
            }
        }
        let call = &args[..end];
        let open = call.find('"')?;
        let close = call[open + 1..].find('"')? + open + 1;
        let literal = &call[open + 1..close];
        let is_identifier = literal.starts_with(|c: char| c.is_ascii_alphabetic())
            && literal.chars().all(|c| c.is_ascii_alphanumeric());
        is_identifier.then(|| literal.to_string())
    }

    /// The method vocabulary is written down twice — registered in Rust,
    /// dispatched in GDScript — and neither side can see the other. Drift
    /// answers -32601 at runtime, in whichever client happens to call the
    /// method, with no compile error anywhere.
    #[test]
    fn rust_registrations_and_gdscript_dispatch_agree() {
        let routed = rust_array_entries(IPC_SERVER_SRC, "let gdscript_methods = [");
        let local = rust_local_methods(IPC_SERVER_SRC);
        let arms = gdscript_dispatch_arms(IPC_HANDLERS_SRC);
        let specials = workspace_special_methods(WORKSPACE_SRC);

        assert!(!routed.is_empty(), "parsed no routed methods out of ipc.rs");
        assert!(
            !local.is_empty(),
            "parsed no locally answered methods out of ipc.rs"
        );
        assert!(
            !arms.is_empty(),
            "parsed no dispatch arms out of ipc_handlers.gd"
        );
        assert!(
            !specials.is_empty(),
            "parsed no intercepted methods out of workspace.gd"
        );

        let handled: BTreeSet<String> = arms.union(&specials).cloned().collect();
        assert_eq!(
            handled, routed,
            "the GDScript handlers and the Rust registrations disagree: a method \
             registered in Rust but handled on neither side fails at runtime with -32601 \
             (after the 5 s GDScript timeout), and a handler with no registration is \
             dead code"
        );
        assert!(
            arms.is_disjoint(&specials),
            "a method must be handled in exactly one place: {:?}",
            arms.intersection(&specials).collect::<Vec<_>>()
        );
        assert!(
            local.is_disjoint(&routed),
            "a method answered in Rust must not also be routed to GDScript: {:?}",
            local.intersection(&routed).collect::<Vec<_>>()
        );
    }

    /// Every advertised MCP tool must resolve to a method the GUI registers,
    /// no two tools may collapse onto one method, and every routed method
    /// must be reachable from some tool. `daemon-*` tools are answered by the
    /// MCP server itself and never reach the socket with a derived name.
    #[test]
    fn every_mcp_tool_maps_to_a_registered_method() {
        let routed = rust_array_entries(IPC_SERVER_SRC, "let gdscript_methods = [");
        let surface = registered_methods();
        let tools = crate::commands::schema::build_mcp_tools_inline(&crate::Cli::command());
        let names: Vec<&str> = tools["tools"]
            .as_array()
            .expect("schema exposes a tools array")
            .iter()
            .map(|t| t["name"].as_str().expect("every tool has a name"))
            .collect();
        assert!(!names.is_empty(), "schema must expose tools");

        let mut mapped = BTreeSet::new();
        for name in &names {
            if name.starts_with("daemon-") {
                continue;
            }
            let method = tool_to_ipc_method(name);
            assert!(
                surface.contains(&method),
                "MCP tool '{name}' maps to IPC method '{method}', which the GUI does not register"
            );
            assert!(
                mapped.insert(method.clone()),
                "two MCP tools map to '{method}'"
            );
        }
        let covered: BTreeSet<String> = mapped.intersection(&routed).cloned().collect();
        assert_eq!(
            covered, routed,
            "a routed method no tool reaches is dead surface; every tool that survives \
             the daemon filter must name a routed method"
        );
    }

    /// A command module naming a method the server does not register fails at
    /// runtime and passes every other check here — the literal it passes to
    /// `client.call` is a second, independent spelling of the vocabulary.
    #[test]
    fn cli_call_sites_name_registered_methods_only() {
        let surface = registered_methods();
        let listener = event_listener_methods();
        let used = cli_call_site_methods();
        assert!(
            !used.is_empty(),
            "parsed no IPC method literals out of src/commands"
        );

        // A command may address either listener: the control socket carries the
        // workspace API, the event socket carries submissions from inside a pane
        // (`gpty state` -> `ompEvent`). Only the literals that exist are held to
        // the event side — `subscribe`/`eventsPoll` are answered there but no CLI
        // command calls them (the smoke and the shipped extension do).
        let reachable: BTreeSet<String> = surface.union(&listener).cloned().collect();
        let unknown: Vec<_> = used.difference(&reachable).collect();
        assert!(
            unknown.is_empty(),
            "these method literals are not registered by the GUI: {unknown:?}"
        );
        let unreachable: Vec<_> = surface.difference(&used).collect();
        assert!(
            unreachable.is_empty(),
            "these registered methods are reachable from no CLI command: {unreachable:?}"
        );
    }
}
