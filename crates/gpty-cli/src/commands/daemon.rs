use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};
use std::time::Duration;

use crate::DaemonAction;
use anyhow::{Context, anyhow, bail};
use gpty_ipc::client::{ClientError, IpcClient};
use gpty_ipc::protocol::{JsonRpcError, Response};

/// True when a response carries an authentication failure (code -32001).
fn auth_denied(resp: &gpty_ipc::protocol::Response) -> bool {
    resp.error
        .as_ref()
        .is_some_and(|e| e.code == JsonRpcError::UNAUTHORIZED)
}

const AUTH_HINT: &str =
    "GUI requires GPTY_SECRET authentication; set GPTY_SECRET to match the running GUI";

/// The one line every command prints when it needs a GUI and none is
/// listening: the never-spawn set and `--no-daemon` both end here instead of
/// each inventing a connect error, and the line names the remedy.
pub const NO_GUI_HINT: &str = "no gpty GUI is running (start one with `gpty daemon start`)";

/// Connect failures that mean *nothing is listening*: a missing socket or
/// pipe, or a stale file whose listener is gone (connect refused). Other
/// connect errors — a refused insecure path, a permission failure — are real
/// problems and keep their own message.
fn nothing_listening(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
    )
}

/// True when an error from any IPC call means no GUI is listening, whatever
/// context a command wrapped around it. The CLI's error path uses it so the
/// never-spawn set (and `--no-daemon`) answer with [`NO_GUI_HINT`] instead of
/// a raw connect error.
pub fn is_not_running(e: &anyhow::Error) -> bool {
    e.chain().any(|cause| {
        cause
            .downcast_ref::<ClientError>()
            .is_some_and(|c| matches!(c, ClientError::Connection(io) if nothing_listening(io)))
    })
}

/// What one `version` probe found.
enum Probe {
    /// A GUI answered.
    Running(Response),
    /// A GUI answered, refusing the request for a missing or mismatched
    /// `GPTY_SECRET`.
    Auth,
    /// Nothing is listening on the endpoint.
    Absent,
    /// A listener accepted the connection but did not answer within the probe
    /// timeout — a GUI that is starting up or wedged. Never treated as
    /// absence: one instance owns the endpoint, so a second GUI could not
    /// bind it anyway, and callers wait this out instead.
    Busy,
    /// A failure waiting cannot fix: a refused insecure path, a permission
    /// error, a malformed reply.
    Failed(String),
}

/// One `version` probe with a one-second budget. The probe is what keeps
/// `daemon status` snappy; how long a *caller* waits for a slow GUI is the
/// caller's deadline, applied in [`connect_with`].
async fn probe(socket_path: &str) -> Probe {
    probe_with(socket_path, Duration::from_secs(1)).await
}

/// A `version` probe with an explicit budget: long where the answer decides
/// whether a GUI exists, short for the best-effort stale-binary check, which
/// must never delay the command it precedes.
async fn probe_with(socket_path: &str, timeout: Duration) -> Probe {
    let client = IpcClient::new(socket_path, timeout);
    match client.call("version", None).await {
        Ok(resp) if resp.error.is_none() => {
            note_gui_version(&resp);
            Probe::Running(resp)
        }
        Ok(resp) if auth_denied(&resp) => Probe::Auth,
        Ok(resp) => Probe::Failed(format!(
            "the gpty GUI answered the version probe with an error: {}",
            resp.error
                .map(|e| format!("{}: {}", e.code, e.message))
                .unwrap_or_else(|| "unknown".into())
        )),
        Err(ClientError::Connection(io)) if nothing_listening(&io) => Probe::Absent,
        Err(ClientError::Timeout(_)) => Probe::Busy,
        // Includes the path: the client refuses insecure socket files before
        // sending anything, and "which path" is the actionable part.
        Err(ClientError::Connection(io)) => {
            Probe::Failed(format!("cannot use {socket_path}: {io}"))
        }
        Err(e) => Probe::Failed(e.to_string()),
    }
}

/// Set once a `version` response has been read in this process, so the
/// best-effort check some call sites run first skips its probe afterwards.
static VERSION_OBSERVED: AtomicBool = AtomicBool::new(false);
/// Set once a stale-binary warning has been printed. `daemon start` can see
/// two version responses (its pre-check and the connect loop), and the
/// mismatch is a property of the binaries, not of the command.
static VERSION_WARNED: AtomicBool = AtomicBool::new(false);

/// Probe budget for the best-effort stale-binary check. A GUI too busy to
/// answer within it skips the warning rather than delaying the command that
/// is about to run.
pub const VERSION_CHECK_BUDGET: Duration = Duration::from_millis(500);

/// Best-effort stale-binary check for a call site that has not read the
/// version yet (the command `main` is about to dispatch, the MCP server at
/// startup). A no-op once a version has been read. Never fails and never
/// gates: the caller's real work runs whatever the probe finds.
pub async fn warn_on_version_mismatch(socket_path: &str, budget: Duration) {
    if VERSION_OBSERVED.load(AtomicOrdering::Relaxed) {
        return;
    }
    let _ = probe_with(socket_path, budget).await;
}

/// Record a `version` response and warn, once per process, when the GUI it
/// came from disagrees with this CLI about the IPC protocol or the version.
///
/// `gpty version` is local-only by design (it cannot probe a GUI), and a
/// subcommand this build lacks dies in clap before any IPC — so without this
/// a stale `gpty` on `PATH` never says so; its commands just fail opaquely.
fn note_gui_version(resp: &Response) {
    VERSION_OBSERVED.store(true, AtomicOrdering::Relaxed);
    let Some(result) = resp.result.as_ref() else {
        return;
    };
    let gui_version = result
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let gui_protocol = result
        .get("protocol")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let Some(line) = stale_binary_line(
        gpty_ipc::protocol::PROTOCOL_VERSION,
        gui_protocol,
        env!("CARGO_PKG_VERSION"),
        gui_version,
    ) else {
        return;
    };
    if VERSION_WARNED.swap(true, AtomicOrdering::Relaxed) {
        return;
    }
    eprintln!("warning: {line}");
}

/// The one line a mismatched binary pair earns, or `None` when they agree.
///
/// The protocol comes first: two builds that disagree about the wire are from
/// different releases whatever the numbers say. A GUI from before the field
/// existed (`protocol` absent) falls through to the version comparison, and a
/// response that names neither side is not evidence of anything.
fn stale_binary_line(
    cli_protocol: &str,
    gui_protocol: &str,
    cli_version: &str,
    gui_version: &str,
) -> Option<String> {
    if !gui_protocol.is_empty() && gui_protocol != cli_protocol {
        return Some(format!(
            "the gpty CLI speaks IPC protocol {cli_protocol} but the running GUI speaks {gui_protocol}; they are from different releases — reinstall the CLI (`cargo install --path crates/gpty-cli`) or use the one shipped beside the GUI"
        ));
    }
    if cli_version.is_empty() || gui_version.is_empty() || gui_version == cli_version {
        return None;
    }
    let order = parse_version_triple(cli_version)
        .zip(parse_version_triple(gui_version))
        .map(|(cli, gui)| cli.cmp(&gui));
    Some(match order {
        Some(std::cmp::Ordering::Less) => format!(
            "the gpty CLI (v{cli_version}) is older than the running GUI (v{gui_version}); reinstall the CLI (`cargo install --path crates/gpty-cli`) or use the one shipped beside the GUI"
        ),
        Some(std::cmp::Ordering::Greater) => format!(
            "the running GUI (v{gui_version}) is older than the gpty CLI (v{cli_version}); update the GUI, or use the CLI the newer release shipped"
        ),
        _ => format!(
            "the gpty CLI (v{cli_version}) and the running GUI (v{gui_version}) report different versions; make sure both come from the same release"
        ),
    })
}

/// `X.Y.Z` as numbers; `None` for anything else (a pre-release suffix, a
/// date, `unknown`), which [`stale_binary_line`] words generically.
fn parse_version_triple(version: &str) -> Option<(u64, u64, u64)> {
    let mut parts = version.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

/// Wait for a GUI to answer on `socket_path`, starting one when the endpoint
/// is empty. Returns the `version` response and whether a GUI was launched.
///
/// A GUI is started only on [`Probe::Absent`] — a socket nothing is bound to.
/// A `Busy` endpoint is waited out within `timeout` (the GUI is starting or
/// busy), and a child that exits early is reported with its own startup
/// output instead of waiting out the deadline with the reason discarded.
async fn connect_with(socket_path: &str, timeout: Duration) -> anyhow::Result<(Response, bool)> {
    let deadline = tokio::time::Instant::now() + timeout;
    let mut child: Option<Child> = None;
    let mut startup_log: Option<PathBuf> = None;

    loop {
        match probe(socket_path).await {
            Probe::Running(resp) => {
                if let Some(path) = startup_log.take() {
                    // The GUI is up: its stderr goes nowhere from here, the
                    // same as the old `Stdio::null()`, and the file is not
                    // left behind for anyone to read.
                    let _ = std::fs::remove_file(path);
                }
                return Ok((resp, child.is_some()));
            }
            Probe::Auth => bail!(AUTH_HINT),
            Probe::Failed(why) => bail!("{why}"),
            Probe::Absent if child.is_none() => {
                let (path, log) = startup_log_file()?;
                child = Some(spawn_gui(log)?);
                startup_log = Some(path);
            }
            Probe::Absent | Probe::Busy => {}
        }

        if tokio::time::Instant::now() >= deadline {
            break;
        }
        if let Some(gui) = child.as_mut()
            && let Some(status) = gui.try_wait()?
        {
            let output = startup_log
                .as_deref()
                .map(take_startup_output)
                .unwrap_or_default();
            bail!("{}", gui_exited(status, &output));
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    let output = startup_log
        .as_deref()
        .map(take_startup_output)
        .unwrap_or_default();
    if child.is_some() {
        // Left running on purpose: it may still come up, and a timed-out CLI
        // is no reason to kill a GUI it just started.
        bail!(
            "the gpty GUI was started but did not answer on {socket_path} within {timeout:?}{}",
            if output.is_empty() {
                String::new()
            } else {
                format!("; its output: {output}")
            }
        )
    }
    bail!("the gpty GUI did not answer on {socket_path} within {timeout:?} (it may be busy)")
}

/// Ensure a GUI is running and answering on `socket_path`. Called only for
/// the commands that may start one (`new-pane`, `layout load`); every other
/// command reports [`NO_GUI_HINT`] through [`is_not_running`] instead of
/// opening a window it cannot use.
pub async fn ensure_running(socket_path: &str, timeout: Duration) -> anyhow::Result<()> {
    connect_with(socket_path, timeout).await.map(|_| ())
}

/// How [`start`] found the GUI.
pub enum Started {
    /// A GUI was already answering.
    Already(String),
    /// A GUI was launched and is now answering.
    Launched(String),
}

/// Start a GUI if none is answering — the one explicit spawner, shared by
/// `gpty daemon start` and the MCP `daemon-start` tool (the MCP server never
/// starts one implicitly: a tool call that finds no GUI fails and says so).
pub async fn start(socket_path: &str, timeout: Duration) -> anyhow::Result<Started> {
    match probe(socket_path).await {
        Probe::Running(resp) => Ok(Started::Already(version_of(&resp))),
        Probe::Auth => bail!(AUTH_HINT),
        Probe::Failed(why) => bail!("{why}"),
        Probe::Absent | Probe::Busy => {
            let (resp, launched) = connect_with(socket_path, timeout).await?;
            let version = version_of(&resp);
            if launched {
                Ok(Started::Launched(version))
            } else {
                Ok(Started::Already(version))
            }
        }
    }
}

/// The `version` string of a successful `version` response.
fn version_of(resp: &Response) -> String {
    resp.result
        .as_ref()
        .and_then(|r| r.get("version"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string()
}

/// Launch the discovered GUI with its stderr captured in `log`.
///
/// A GUI that cannot start (no display, missing libraries) says why on
/// stderr; that output is the only actionable part of the failure, so it is
/// kept for the failure paths instead of being discarded.
fn spawn_gui(log: File) -> anyhow::Result<Child> {
    let gui = find_gui_binary().ok_or_else(|| {
        anyhow!("no gpty GUI binary found beside this CLI (set GPTY_GUI to its path)")
    })?;
    Command::new(&gui)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(log))
        .spawn()
        .with_context(|| format!("could not start {}", gui.display()))
}

/// A private, unpredictable file to hold the child's stderr while it may
/// still die: a pipe held by a CLI that exits would leave the GUI writing
/// into a closed pipe for the rest of its life, while this file (removed once
/// the GUI answers, or read once it fails) cannot block or kill it.
fn startup_log_file() -> io::Result<(PathBuf, File)> {
    let path = std::env::temp_dir().join(format!(
        "gpty-gui-startup-{:016x}.log",
        crate::plugin_store::temp_suffix()
    ));
    let mut options = OpenOptions::new();
    // `create_new` is O_EXCL: a planted name cannot divert the write.
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&path)?;
    Ok((path, file))
}

/// Read whatever the child wrote, remove the file, and cap the tail so a
/// chatty child cannot bloat the error.
fn take_startup_output(path: &Path) -> String {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let _ = std::fs::remove_file(path);
    let text = text.trim();
    if text.len() > 2000 {
        let mut cut = text.len() - 2000;
        while !text.is_char_boundary(cut) {
            cut += 1;
        }
        return text[cut..].trim().to_string();
    }
    text.to_string()
}

fn gui_exited(status: ExitStatus, output: &str) -> String {
    if output.is_empty() {
        format!("the gpty GUI exited immediately ({status}) without starting up")
    } else {
        format!("the gpty GUI exited immediately ({status}): {output}")
    }
}

/// GUI names to look for beside the CLI: release bundles and `/usr/lib/gpty`
/// hold the export as `gpty-gui` while the CLI owns `gpty`.
const GUI_SIBLING_NAMES: [&str; 2] = ["gpty-editor", "gpty-gui"];

/// macOS bundle layout, relative to the directory holding the bundle.
const MACOS_APP_INTERNALS: &str = "gPTY.app/Contents/MacOS/gPTY";

fn find_gui_binary() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("GPTY_GUI") {
        let p = PathBuf::from(path);
        if gpty_ipc::transport::validate_gui_binary(&p) {
            log::warn!("spawning GUI from GPTY_GUI override: {}", p.display());
            return Some(p);
        }
        log::warn!(
            "ignoring GPTY_GUI override (failed validation): {}",
            p.display()
        );
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let home = dirs::home_dir();
    let gui = gui_candidates(dir, home.as_deref())
        .into_iter()
        .find(|candidate| launchable(candidate))?;
    log::info!("spawning GUI: {}", gui.display());
    Some(gui)
}

/// GUI locations to try, in priority order: an export shipped beside the CLI
/// (release bundle, `/usr/lib/gpty`), then the macOS bundle — which the release
/// zip puts next to the CLI and a normal install puts under `/Applications`.
fn gui_candidates(exe_dir: &Path, home: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = GUI_SIBLING_NAMES
        .iter()
        .map(|name| exe_dir.join(name))
        .collect();
    candidates.push(exe_dir.join(MACOS_APP_INTERNALS));
    candidates.push(Path::new("/Applications").join(MACOS_APP_INTERNALS));
    if let Some(home) = home {
        candidates.push(home.join("Applications").join(MACOS_APP_INTERNALS));
    }
    candidates
}

/// A discovered GUI must be an absolute regular file that no one else can
/// write. Unlike the `GPTY_GUI` override it need not be owned by this user:
/// an app under `/Applications` is normally root-owned.
fn launchable(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.mode() & 0o022 != 0 {
            return false;
        }
    }
    true
}

/// Handle `gpty daemon …` before the generic spawn gate: `start` is the one
/// explicit spawner, and `stop`/`status` report their outcome instead of
/// being refused by it. Returns the process exit code; real failures are
/// errors, printed by the caller.
pub async fn run(
    action: &DaemonAction,
    socket_path: &str,
    timeout: Duration,
    json: bool,
    no_daemon: bool,
) -> anyhow::Result<i32> {
    match action {
        DaemonAction::Start => {
            if no_daemon {
                bail!("--no-daemon forbids starting the GUI; drop the flag to start one");
            }
            match start(socket_path, timeout).await? {
                Started::Already(v) => println!("gpty GUI is already running (v{v})"),
                Started::Launched(v) => println!("gpty GUI started (v{v})"),
            }
            Ok(0)
        }
        DaemonAction::Stop => {
            let client = IpcClient::new(socket_path, timeout);
            match client.call("shutdown", Some(serde_json::json!({}))).await {
                Ok(resp) => {
                    super::format_response(&resp, json)?;
                    Ok(0)
                }
                // Idempotent by design: stopping nothing reaches the desired
                // end state, so it is a message and a success, not an error.
                Err(ClientError::Connection(io)) if nothing_listening(&io) => {
                    println!("gpty GUI is not running; nothing to stop.");
                    Ok(0)
                }
                Err(e) => Err(e.into()),
            }
        }
        DaemonAction::Status => match probe(socket_path).await {
            Probe::Running(resp) => {
                if json {
                    println!("{}", serde_json::to_string_pretty(&resp)?);
                } else {
                    println!("gpty GUI is running (v{})", version_of(&resp));
                }
                Ok(0)
            }
            Probe::Auth => {
                println!(
                    "gpty GUI is running but requires GPTY_SECRET authentication (mismatched GPTY_SECRET)."
                );
                Ok(1)
            }
            Probe::Absent => {
                println!("gpty GUI is not running.");
                Ok(1)
            }
            Probe::Busy => {
                println!("gpty GUI did not answer within one second (it may be busy).");
                Ok(1)
            }
            Probe::Failed(why) => {
                println!("{why}");
                Ok(1)
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private temp file, mirroring the `validate_gui_binary` tests.
    fn temp_file(name: &str, mode: u32) -> PathBuf {
        let path = std::env::temp_dir().join(format!("gpty-{name}-{}", std::process::id()));
        std::fs::write(&path, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        #[cfg(not(unix))]
        let _ = mode;
        path
    }

    /// The stale-binary check: the protocol is the primary signal, the
    /// version comparison is direction-aware, and a pair that agrees — or
    /// says nothing — earns no line.
    #[test]
    fn a_mismatched_binary_pair_earns_one_named_line() {
        assert!(stale_binary_line("2.0", "2.0", "0.5.5", "0.5.5").is_none());
        // Same numbers, different wire: only the protocol can catch it.
        let protocol = stale_binary_line("2.0", "3.0", "0.5.5", "0.5.5").expect("warns");
        assert!(
            protocol.contains("protocol 2.0") && protocol.contains("speaks 3.0"),
            "{protocol}"
        );
        assert!(
            protocol.contains("cargo install --path crates/gpty-cli"),
            "the remedy is named: {protocol}"
        );
        // The reported case: an older CLI shadowing a newer GUI on PATH.
        let older = stale_binary_line("2.0", "", "0.5.0", "0.5.5").expect("warns");
        assert!(
            older.contains("v0.5.0") && older.contains("v0.5.5") && older.contains("older than"),
            "{older}"
        );
        // The reverse repair is updating the GUI, not reinstalling the CLI.
        let newer = stale_binary_line("2.0", "2.0", "0.6.0", "0.5.5").expect("warns");
        assert!(newer.contains("GUI (v0.5.5) is older"), "{newer}");
        // Unparseable numbers still name both sides.
        let odd = stale_binary_line("2.0", "2.0", "0.5.5-rc1", "0.5.5").expect("warns");
        assert!(odd.contains("same release"), "{odd}");
        // Nothing to compare: a matching protocol and no version, or no
        // version at all, is not evidence of staleness.
        assert!(stale_binary_line("2.0", "2.0", "0.5.5", "").is_none());
        assert!(stale_binary_line("2.0", "", "", "0.5.5").is_none());
    }

    #[test]
    fn bundle_sibling_outranks_system_locations() {
        let candidates = gui_candidates(Path::new("/opt/gpty"), Some(Path::new("/home/u")));
        assert_eq!(candidates[0], PathBuf::from("/opt/gpty/gpty-editor"));
        assert_eq!(candidates[1], PathBuf::from("/opt/gpty/gpty-gui"));
        assert!(
            candidates.contains(&PathBuf::from("/opt/gpty/gPTY.app/Contents/MacOS/gPTY")),
            "the macOS zip extracts the CLI next to the bundle"
        );
        assert!(candidates.contains(&PathBuf::from("/Applications/gPTY.app/Contents/MacOS/gPTY")));
        assert!(candidates.contains(&PathBuf::from(
            "/home/u/Applications/gPTY.app/Contents/MacOS/gPTY"
        )));
    }

    #[test]
    fn user_applications_dir_needs_a_home() {
        let candidates = gui_candidates(Path::new("/opt/gpty"), None);
        assert_eq!(
            candidates
                .iter()
                .filter(|c| c.to_string_lossy().contains("Applications"))
                .count(),
            1,
            "without a home directory only the system /Applications candidate is offered"
        );
    }

    #[test]
    fn launchable_requires_a_private_regular_file() {
        let ok = temp_file("gui-ok", 0o755);
        assert!(launchable(&ok));

        let world_writable = temp_file("gui-world-writable", 0o777);
        #[cfg(unix)]
        assert!(
            !launchable(&world_writable),
            "a candidate anyone can replace must not be spawned"
        );

        assert!(!launchable(Path::new("/nonexistent/gpty-gui")));
        assert!(!launchable(Path::new("gpty-gui")), "relative path");
        assert!(!launchable(&std::env::temp_dir()), "a directory");

        std::fs::remove_file(&ok).unwrap();
        std::fs::remove_file(&world_writable).unwrap();
    }
}
