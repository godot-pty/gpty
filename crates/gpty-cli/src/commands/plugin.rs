//! `gpty plugin` — install, manage, and run plugins.
//!
//! A plugin is a git repo carrying `gpty-plugin.toml` (see
//! [`crate::plugin_manifest`]). Install clones it into a staging dir, parses
//! and gates the manifest, and — because a plugin's actions run as the user
//! with the workspace API — asks a human through the GUI's review dialog
//! (the `pluginInstall` IPC handshake, the same trust model as the Workspace
//! Trust dialog). Only after acceptance does the content move into
//! `<data>/plugins/<id>` and the record land in the store. Nothing in a
//! plugin executes during install: `build`/`startup` are shown in the review
//! but never run, and even `run` only spawns the CLI command an action names.
//!
//! Git is driven by argv, never a shell, and every id/ref is validated
//! before it joins a path or a command line.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use gpty_ipc::client::IpcClient;

use crate::PluginAction;
use crate::plugin_manifest::{
    self, ActionSpec, Manifest, Platform, ProfileSpec, current_version, parse_manifest,
    valid_plugin_id,
};
use crate::plugin_store::{self, PluginProfileRecord, PluginStore};

/// The review dialog waits on a human; the request deadline (and this
/// client's timeout) are minutes, not the default 5 s.
const REVIEW_TIMEOUT: Duration = Duration::from_secs(300);
/// A manifest is a small declaration file; anything larger is not a manifest
/// but something being smuggled in.
const MAX_MANIFEST_BYTES: usize = 64 * 1024;

pub async fn run(
    action: &PluginAction,
    socket_path: &str,
    timeout: Duration,
    json: bool,
    no_daemon: bool,
) -> anyhow::Result<()> {
    match action {
        PluginAction::Install { target } => {
            install(target, socket_path, timeout, json, no_daemon).await
        }
        PluginAction::List => list(json),
        PluginAction::Enable { id } => set_enabled(id, true, json),
        PluginAction::Disable { id } => set_enabled(id, false, json),
        PluginAction::Uninstall { id } => uninstall(id, json),
        PluginAction::Logs { id, lines } => logs(id, *lines),
        PluginAction::Run { id, action: name } => run_action(id, name, json),
        PluginAction::Validate { path } => validate(path, json),
    }
}

// ── Install ───────────────────────────────────────────────────────────

/// `owner/repo[@ref]` — the install target. Both id parts are held to the
/// manifest's `owner/name` shape, so the id can key the store and join paths
/// without another validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InstallTarget {
    pub owner: String,
    pub repo: String,
    pub ref_name: Option<String>,
}

impl InstallTarget {
    pub fn id(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }

    pub fn clone_url(&self) -> String {
        format!("https://github.com/{}/{}", self.owner, self.repo)
    }
}

pub(crate) fn parse_target(target: &str) -> anyhow::Result<InstallTarget> {
    let (id_part, ref_part) = match target.split_once('@') {
        Some((id, ref_name)) => {
            validate_ref_name(ref_name)?;
            (id, Some(ref_name.to_string()))
        }
        None => (target, None),
    };
    let Some((owner, repo)) = id_part.split_once('/') else {
        bail!("invalid plugin target `{target}` (expected `owner/repo` or `owner/repo@ref`)");
    };
    let id = format!("{owner}/{repo}");
    if !valid_plugin_id(&id) {
        bail!("invalid plugin target `{target}` (owner and repo must match [a-z0-9-], 1-63 chars)");
    }
    Ok(InstallTarget {
        owner: owner.to_string(),
        repo: repo.to_string(),
        ref_name: ref_part,
    })
}

/// Ref names are argv for `git fetch`, never a shell — but a ref starting
/// with `-` would be parsed as a git option, so the accepted set is the
/// boring one: letters, digits, and `._/-`, no `..`, no leading `.`/`-`,
/// capped like a path component. Full commit ids pass.
fn validate_ref_name(ref_name: &str) -> anyhow::Result<()> {
    let ok = !ref_name.is_empty()
        && ref_name.len() <= 128
        && !ref_name.starts_with(['-', '.'])
        && !ref_name.contains("..")
        && ref_name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '-'));
    if ok {
        Ok(())
    } else {
        bail!("invalid ref `{ref_name}` (letters, digits, `._/-`, no leading `-` or `.`, no `..`)")
    }
}

/// The current platform as the manifest vocabulary names it. Anything else
/// fails the platform gate — an undeclared platform is refused, not guessed.
pub(crate) fn current_platform() -> anyhow::Result<Platform> {
    match std::env::consts::OS {
        "linux" => Ok(Platform::Linux),
        "macos" => Ok(Platform::Macos),
        "windows" => Ok(Platform::Windows),
        other => bail!("unsupported platform `{other}`"),
    }
}

/// The install-time gates, all fail-closed:
/// * the manifest must declare exactly the id being installed — the target
///   names the identity, so a repo cannot claim another plugin's id;
/// * the current platform must be in `platforms` (absent = all);
/// * `min_gpty_version` must not be newer than this CLI.
pub(crate) fn check_gates(
    manifest: &Manifest,
    target: &InstallTarget,
    platform: Platform,
) -> anyhow::Result<()> {
    if manifest.id != target.id() {
        bail!(
            "manifest id `{}` does not match the install target `{}`",
            manifest.id,
            target.id()
        );
    }
    if !manifest.platforms.contains(&platform) {
        bail!(
            "plugin `{}` does not support this platform (declared: {:?})",
            manifest.id,
            manifest.platforms
        );
    }
    if manifest.min_gpty_version > current_version() {
        bail!(
            "plugin `{}` requires gpty >= {}, this CLI is {}",
            manifest.id,
            manifest.min_gpty_version,
            current_version()
        );
    }
    Ok(())
}

/// Removes the staging dir when dropped, unless disarmed — the install path
/// has many exits and the clone must not survive any of them.
struct StagingGuard(PathBuf);

impl StagingGuard {
    fn disarm(mut self) {
        self.0 = PathBuf::new();
    }
}

impl Drop for StagingGuard {
    fn drop(&mut self) {
        if !self.0.as_os_str().is_empty() {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

async fn install(
    target: &str,
    socket_path: &str,
    timeout: Duration,
    json: bool,
    no_daemon: bool,
) -> anyhow::Result<()> {
    let target = parse_target(target)?;
    let platform = current_platform()?;

    let staging_root = plugin_store::staging_root()?;
    std::fs::create_dir_all(&staging_root)
        .with_context(|| format!("creating {}", staging_root.display()))?;
    let staging = staging_root.join(format!("staging-{:016x}", plugin_store::temp_suffix()));
    let guard = StagingGuard(staging.clone());

    // Clone the pinned ref. argv only — git is driven the same way every
    // other child here is, and a hostile repo cannot reach a shell.
    let staging_str = staging.to_str().context("staging path is not UTF-8")?;
    let url = target.clone_url();
    git(&["clone", "--quiet", url.as_str(), staging_str])?;
    if let Some(ref_name) = &target.ref_name {
        git_in(&staging, &["fetch", "--quiet", "origin", ref_name.as_str()])?;
        git_in(&staging, &["checkout", "--quiet", "--detach", "FETCH_HEAD"])?;
    }
    let revision = git_in_out(&staging, &["rev-parse", "HEAD"])?;
    if revision.len() < plugin_store::MIN_REVISION_LEN {
        bail!("git returned an unusable revision `{revision}`");
    }

    let manifest = read_manifest(&staging)?;
    check_gates(&manifest, &target, platform)?;

    // Same content already installed? Nothing to review again.
    let store = PluginStore::open()?;
    if let Some(existing) = store.record(&manifest.id)?
        && existing.revision == revision
    {
        guard.disarm();
        println!(
            "`{}` is already installed at revision {}",
            manifest.id,
            short_rev(&revision)
        );
        return Ok(());
    }

    // A plugin's actions run as the user with the workspace API — installing
    // is a trust decision, and only a human can make it. No GUI answers
    // (declined, disconnected, no daemon) => nothing is installed.
    let summary = review_summary(&manifest, &target, &revision);
    let client = IpcClient::new(socket_path, REVIEW_TIMEOUT.max(timeout));
    if !no_daemon {
        crate::commands::daemon::ensure_running(socket_path, timeout).await?;
    }
    let accepted = review_install(&client, &summary).await?;
    if !accepted {
        bail!("install declined");
    }

    // Accepted: per-plugin runtime dirs, then the content move (rename on
    // one filesystem), then the record. The record is written last so a
    // half-moved install is not listed.
    for sub in ["config", "state", "logs"] {
        std::fs::create_dir_all(plugin_store::runtime_dir(&manifest.id)?.join(sub))?;
    }
    move_into_place(&staging, &manifest.id)?;
    guard.disarm();
    let record = store.upsert(&manifest.id, &revision, &profile_records(&manifest))?;

    print_result(
        json,
        serde_json::json!({
            "id": record.id,
            "name": manifest.name,
            "version": manifest.version.to_string(),
            "revision": record.revision,
            "enabled": record.enabled,
        }),
        format!(
            "installed `{}` {} at revision {}",
            manifest.name,
            manifest.id,
            short_rev(&revision)
        ),
    );
    Ok(())
}

/// Move the staged clone into `<data>/plugins/<id>`. An existing install
/// (a revision upgrade, already approved by the review) is swapped out with
/// a rollback if the new content cannot take its place.
fn move_into_place(staging: &Path, id: &str) -> anyhow::Result<()> {
    let root = plugin_store::content_root()?;
    std::fs::create_dir_all(&root).with_context(|| format!("creating {}", root.display()))?;
    let dest = root.join(id);
    if !dest.exists() {
        return std::fs::rename(staging, &dest)
            .with_context(|| format!("moving {} into {}", staging.display(), dest.display()));
    }
    let old = root.join(format!(
        ".old-{}-{:016x}",
        id.replace('/', "-"),
        plugin_store::temp_suffix()
    ));
    std::fs::rename(&dest, &old).with_context(|| format!("moving {} aside", dest.display()))?;
    match std::fs::rename(staging, &dest) {
        Ok(()) => {
            let _ = std::fs::remove_dir_all(&old);
            Ok(())
        }
        Err(e) => {
            let _ = std::fs::rename(&old, &dest);
            Err(e).with_context(|| format!("moving {} into {}", staging.display(), dest.display()))
        }
    }
}

/// Ask the GUI to show the review dialog. The verdict arrives as
/// `{"accepted": true|false}`; a decline is a verdict, not an error, and
/// anything else (timeout, disconnect, no daemon) fails closed.
pub(crate) async fn review_install(
    client: &IpcClient,
    summary: &serde_json::Value,
) -> anyhow::Result<bool> {
    let resp = client.call("pluginInstall", Some(summary.clone())).await?;
    if let Some(err) = &resp.error {
        bail!("plugin review failed: {} ({})", err.message, err.code);
    }
    let verdict = resp
        .result
        .as_ref()
        .and_then(|result| result.get("accepted"))
        .and_then(|accepted| accepted.as_bool());
    match verdict {
        Some(true) => Ok(true),
        Some(false) => Ok(false),
        None => bail!("plugin review returned no verdict"),
    }
}

/// The manifest's profiles as store records: the name plus its tiles as JSON.
///
/// The store is the GUI's read model, so the tiles travel as
/// `serde_json::Value` — `parse_manifest` already held every one of them to
/// the tile contract, and the GUI never parses TOML.
pub(crate) fn profile_records(manifest: &Manifest) -> Vec<PluginProfileRecord> {
    manifest
        .profiles
        .iter()
        .map(|profile| PluginProfileRecord {
            name: profile.name.clone(),
            tiles: profile
                .tiles
                .iter()
                .map(|tile| {
                    serde_json::to_value(tile).expect("a validated tile serializes to JSON")
                })
                .collect(),
        })
        .collect()
}

/// What the review dialog renders. All fields come from a validated manifest
/// (caps applied at parse time); the GUI re-caps the display, because the
/// dialog text is untrusted file content. `requested_ref` is the ref the
/// user named on the command line (a tag, branch, or commit SHA — or
/// "default branch" for a bare install), shown beside the resolved revision
/// so the review answers "what I asked for, resolved to what I get".
pub(crate) fn review_summary(
    manifest: &Manifest,
    target: &InstallTarget,
    revision: &str,
) -> serde_json::Value {
    serde_json::json!({
        "id": manifest.id,
        "name": manifest.name,
        "version": manifest.version.to_string(),
        "revision": revision,
        "requested_ref": target.ref_name.clone().unwrap_or_else(|| "default branch".into()),
        "source": format!("github.com/{}/{}", target.owner, target.repo),
        "build": manifest.build,
        "startup": manifest.startup,
        "actions": manifest
            .actions
            .iter()
            .map(|action| serde_json::json!({
                "name": action.name,
                "command": action.command,
                "args": action
                    .args
                    .iter()
                    .map(|(key, value)| (key.clone(), serde_json::Value::String(value.clone())))
                    .collect::<serde_json::Map<String, serde_json::Value>>(),
            }))
            .collect::<Vec<_>>(),
        "events": manifest
            .events
            .iter()
            .map(|event| serde_json::json!({"name": event.name, "type": event.kind}))
            .collect::<Vec<_>>(),
        "link_handlers": manifest
            .link_handlers
            .iter()
            .map(|handler| serde_json::json!({"scheme": handler.scheme, "command": handler.command}))
            .collect::<Vec<_>>(),
        "concepts": manifest.concepts.len(),
        // A profile is geometry plus the programs its tiles name; the review
        // says what activating it would start, not just how many tiles.
        "profiles": manifest
            .profiles
            .iter()
            .map(|profile| serde_json::json!({
                "name": profile.name,
                "tiles": profile.tiles.len(),
                "programs": profile_programs(profile),
            }))
            .collect::<Vec<_>>(),
    })
}

/// The most programs one review entry lists.
const MAX_PROFILE_PROGRAMS: usize = 8;
/// The most characters of one program name the review lists — the cap the
/// summary applies to the other displayed tile/argv values.
const MAX_PROGRAM_LEN: usize = 64;

/// The distinct `settings.command` values a profile's tiles name, in tile
/// order: "what this profile would run". A tile that names no program
/// (a code viewer, a file tree) contributes nothing. `settings.command` is
/// authored content with no manifest-level length cap, so each entry is
/// shortened for the dialog like every other displayed string.
fn profile_programs(profile: &ProfileSpec) -> Vec<String> {
    let mut programs: Vec<String> = Vec::new();
    for tile in &profile.tiles {
        let Some(command) = tile
            .get("settings")
            .and_then(|settings| settings.get("command"))
            .and_then(|command| command.as_str())
        else {
            continue;
        };
        let command = short(command, MAX_PROGRAM_LEN);
        if command.is_empty() || programs.contains(&command) {
            continue;
        }
        programs.push(command);
        if programs.len() >= MAX_PROFILE_PROGRAMS {
            break;
        }
    }
    programs
}

/// One capped, control-character-free string for the review summary — the
/// Rust mirror of `PluginReviewText.short` in the GUI, which re-caps the same
/// untrusted manifest strings before printing them.
fn short(text: &str, cap: usize) -> String {
    text.chars()
        .filter(|ch| !ch.is_control())
        .take(cap)
        .collect()
}

// ── List / enable / disable / uninstall ───────────────────────────────

fn list(json: bool) -> anyhow::Result<()> {
    let records = PluginStore::open()?.records()?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({"plugins": records}))?
        );
    } else if records.is_empty() {
        println!("No plugins installed.");
    } else {
        for record in &records {
            let state = if record.enabled {
                "enabled"
            } else {
                "disabled"
            };
            println!(
                "{:<10} {}  @{}",
                state,
                record.id,
                short_rev(&record.revision)
            );
        }
    }
    Ok(())
}

fn set_enabled(id: &str, enabled: bool, json: bool) -> anyhow::Result<()> {
    let store = PluginStore::open()?;
    let Some(record) = store.set_enabled(id, enabled)? else {
        bail!("plugin `{id}` is not installed");
    };
    let word = if enabled { "enabled" } else { "disabled" };
    print_result(
        json,
        serde_json::json!({"id": record.id, "enabled": record.enabled}),
        format!("{} `{}`", word, record.id),
    );
    Ok(())
}

fn uninstall(id: &str, json: bool) -> anyhow::Result<()> {
    let store = PluginStore::open()?;
    if !store.remove(id)? {
        bail!("plugin `{id}` is not installed");
    }
    // The record is the source of truth and is already gone; the content is
    // best-effort (a half-removed dir is reported, not retried).
    for dir in [
        plugin_store::content_dir(id)?,
        plugin_store::runtime_dir(id)?,
    ] {
        match std::fs::remove_dir_all(&dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => eprintln!("warning: could not remove {}: {e}", dir.display()),
        }
    }
    print_result(
        json,
        serde_json::json!({"id": id, "removed": true}),
        format!("removed `{id}`"),
    );
    Ok(())
}

// ── Logs ──────────────────────────────────────────────────────────────

fn logs(id: &str, lines: usize) -> anyhow::Result<()> {
    let dir = plugin_store::logs_dir(id)?;
    let mut files: Vec<_> = match std::fs::read_dir(&dir) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path.is_file())
            .collect(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(e) => bail!("{}: {e}", dir.display()),
    };
    files.sort();
    if files.is_empty() {
        println!("No logs for `{id}` yet.");
        return Ok(());
    }
    println!("logs for `{id}`:");
    for path in &files {
        println!(
            "  {}",
            path.file_name().unwrap_or_default().to_string_lossy()
        );
    }
    let newest = files.last().expect("non-empty");
    let text =
        std::fs::read_to_string(newest).with_context(|| format!("reading {}", newest.display()))?;
    let tail: Vec<&str> = text.lines().rev().take(lines).collect();
    println!(
        "--- {} ---",
        newest.file_name().unwrap_or_default().to_string_lossy()
    );
    for line in tail.into_iter().rev() {
        println!("{line}");
    }
    Ok(())
}

// ── Run ───────────────────────────────────────────────────────────────

/// Spawn the named action's CLI command. The action is argv — the binary is
/// `GPTY_BIN_PATH` (or this very CLI) and the args are the manifest's
/// `--key value` pairs, so nothing is ever shell-evaluated. Child output is
/// captured to the per-plugin log dir and printed after the child exits.
fn run_action(id: &str, name: &str, json: bool) -> anyhow::Result<()> {
    let store = PluginStore::open()?;
    let Some(record) = store.record(id)? else {
        bail!("plugin `{id}` is not installed");
    };
    if !record.enabled {
        bail!("plugin `{id}` is disabled (run `gpty plugin enable {id}` first)");
    }
    let manifest = read_manifest(&plugin_store::content_dir(id)?)?;
    let Some(spec) = manifest.actions.iter().find(|action| action.name == name) else {
        bail!("plugin `{id}` has no action `{name}`");
    };

    let bin = std::env::var("GPTY_BIN_PATH")
        .ok()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or(std::env::current_exe().context("no current executable")?);

    let logs_dir = plugin_store::logs_dir(id)?;
    std::fs::create_dir_all(&logs_dir)
        .with_context(|| format!("creating {}", logs_dir.display()))?;
    let log_path = logs_dir.join(format!("{name}-{:010}.log", unix_secs()));
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .with_context(|| format!("opening {}", log_path.display()))?;

    let status = Command::new(&bin)
        .args(action_argv(spec))
        .stdout(log.try_clone().context("cloning log handle")?)
        .stderr(log)
        .status()
        .with_context(|| format!("spawning {}", bin.display()))?;

    let output = std::fs::read_to_string(&log_path).unwrap_or_default();
    let exit_code = status.code();
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "success": status.success(),
                "exit_code": exit_code,
                "log": log_path.to_string_lossy(),
                "output": output,
            }))?
        );
    } else {
        print!("{output}");
        eprintln!("logged to {}", log_path.display());
    }
    if !status.success() {
        bail!("`{name}` exited with {}", status);
    }
    Ok(())
}

/// The child argv for an action: the advertised CLI command plus each
/// manifest arg as a `--key value` pair (keys are `[a-z][a-z0-9_-]*`, so the
/// `--` prefix is the manifest's spelling convention).
pub(crate) fn action_argv(spec: &ActionSpec) -> Vec<String> {
    let mut argv = Vec::with_capacity(1 + spec.args.len() * 2);
    argv.push(spec.command.clone());
    for (key, value) in &spec.args {
        argv.push(format!("--{key}"));
        argv.push(value.clone());
    }
    argv
}

// ── Validate ──────────────────────────────────────────────────────────

/// `gpty plugin validate <path>` — the plugin-authoring loop, and what a
/// plugin repo's own CI runs: parse a manifest through exactly the validator
/// install uses, and report the verdict. No store, no GUI, no network.
///
/// A directory resolves to the manifest inside it, so an author points this
/// at the plugin checkout; a file is the manifest itself.
fn validate(path: &Path, json: bool) -> anyhow::Result<()> {
    match validate_manifest(path) {
        Ok(manifest) => {
            print_result(
                json,
                serde_json::json!({
                    "ok": true,
                    "id": manifest.id,
                    "name": manifest.name,
                    "version": manifest.version.to_string(),
                }),
                format!(
                    "plugin ok: {} {} ({} profiles, {} actions, {} events, {} concepts, {} link handlers)",
                    manifest.id,
                    manifest.version,
                    manifest.profiles.len(),
                    manifest.actions.len(),
                    manifest.events.len(),
                    manifest.concepts.len(),
                    manifest.link_handlers.len(),
                ),
            );
            Ok(())
        }
        Err(diagnostic) => {
            // Every failure — an unreadable path, an oversized file, a
            // rejected field — is the same verdict, so `--json` always
            // answers with the same envelope an authoring loop branches on.
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(
                        &serde_json::json!({"ok": false, "errors": [diagnostic]})
                    )?
                );
            }
            // A rejected manifest is an exit status, not a crash: the caller
            // prints the diagnostic to stderr and exits 1. In `--json` mode
            // the diagnostic reaches stderr too, so a human watching the run
            // still reads what failed.
            bail!("{diagnostic}");
        }
    }
}

/// The verdict as one diagnostic line: `<manifest path>: <what is wrong>`,
/// or the path/IO error when the file could not even be read.
fn validate_manifest(path: &Path) -> Result<Manifest, String> {
    let manifest_path = resolve_manifest_path(path).map_err(|e| format!("{e:#}"))?;
    let text = read_manifest_text(&manifest_path).map_err(|e| format!("{e:#}"))?;
    parse_manifest(&text).map_err(|e| format!("{}: {e}", manifest_path.display()))
}

/// The manifest a `validate` argument names: a directory is a plugin
/// directory, so the manifest is the one inside it; a file is the manifest.
fn resolve_manifest_path(path: &Path) -> anyhow::Result<PathBuf> {
    let metadata = std::fs::metadata(path)
        .with_context(|| format!("{}: not a readable file or directory", path.display()))?;
    if metadata.is_dir() {
        Ok(path.join(plugin_manifest::MANIFEST_FILENAME))
    } else {
        Ok(path.to_path_buf())
    }
}

// ── Shared helpers ────────────────────────────────────────────────────

/// Read and parse the manifest in a plugin directory. Size-capped: a
/// manifest is a declaration, and the file comes from an untrusted repo.
pub(crate) fn read_manifest(dir: &Path) -> anyhow::Result<Manifest> {
    let path = dir.join(plugin_manifest::MANIFEST_FILENAME);
    let text = read_manifest_text(&path)?;
    parse_manifest(&text).map_err(|e| anyhow!("{}: {e}", path.display()))
}

/// Read a manifest's bytes with the size cap, as UTF-8 text. Shared by
/// install and `validate` so both accept exactly the same files.
fn read_manifest_text(path: &Path) -> anyhow::Result<String> {
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    if bytes.len() > MAX_MANIFEST_BYTES {
        bail!(
            "{} is {} bytes; manifests are at most {MAX_MANIFEST_BYTES}",
            path.display(),
            bytes.len()
        );
    }
    String::from_utf8(bytes).with_context(|| format!("{} is not UTF-8", path.display()))
}

fn short_rev(revision: &str) -> String {
    revision.chars().take(12).collect()
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn print_result(json: bool, value: serde_json::Value, human: String) {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&value).expect("serializable")
        );
    } else {
        println!("{human}");
    }
}

/// Run git, returning its stdout/stderr on failure — never through a shell.
fn git(args: &[&str]) -> anyhow::Result<()> {
    let output = Command::new("git")
        .args(args)
        .output()
        .context("spawning git")?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

fn git_in(dir: &Path, args: &[&str]) -> anyhow::Result<()> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .context("spawning git")?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

fn git_in_out(dir: &Path, args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .context("spawning git")?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_parses_with_and_without_ref() {
        assert_eq!(
            parse_target("owner/repo").unwrap(),
            InstallTarget {
                owner: "owner".into(),
                repo: "repo".into(),
                ref_name: None,
            }
        );
        assert_eq!(
            parse_target("owner/repo@v1.2.3").unwrap(),
            InstallTarget {
                owner: "owner".into(),
                repo: "repo".into(),
                ref_name: Some("v1.2.3".into()),
            }
        );
        // A full commit id passes the ref shape.
        assert!(parse_target("owner/repo@a1b2c3d4e5f60718293a4b5c6d7e8f9012345678").is_ok());
    }

    #[test]
    fn target_rejects_bad_shapes() {
        assert!(parse_target("norepo").is_err());
        assert!(parse_target("Owner/Repo").is_err());
        assert!(parse_target("owner/repo/extra").is_err());
        assert!(parse_target("owner/").is_err());
        assert!(parse_target("").is_err());
        // Ref shapes: git-option injection and traversal must be refused.
        assert!(parse_target("owner/repo@--upload-pack=x").is_err());
        assert!(parse_target("owner/repo@..").is_err());
        assert!(parse_target("owner/repo@a..b").is_err());
        assert!(parse_target("owner/repo@.hidden").is_err());
        assert!(parse_target("owner/repo@sp ace").is_err());
    }

    #[test]
    fn gates_match_id_platform_and_version() {
        let manifest = parse_manifest(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.0"
"#,
        )
        .unwrap();
        let target = parse_target("owner/repo").unwrap();
        // All three gates pass on a declared platform with a satisfied floor.
        check_gates(&manifest, &target, Platform::Linux).unwrap();
        // A repo cannot install under another plugin's id.
        let other = parse_target("someone/else").unwrap();
        assert!(check_gates(&manifest, &other, Platform::Linux).is_err());
        // A platform not declared (empty = all, so use a narrowed manifest).
        let narrowed = parse_manifest(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.0"
platforms = ["windows"]
"#,
        )
        .unwrap();
        assert!(check_gates(&narrowed, &target, Platform::Linux).is_err());
        assert!(check_gates(&narrowed, &target, Platform::Windows).is_ok());
        // A future min_gpty_version refuses.
        let future = parse_manifest(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "99.0.0"
"#,
        )
        .unwrap();
        assert!(check_gates(&future, &target, Platform::Linux).is_err());
    }

    #[test]
    fn action_argv_is_argv_never_shell() {
        let spec = ActionSpec {
            name: "run-tests".into(),
            command: "pane-run".into(),
            args: vec![("command".into(), "cargo test && push".into())],
        };
        assert_eq!(
            action_argv(&spec),
            vec!["pane-run", "--command", "cargo test && push"]
        );
        let empty = ActionSpec {
            name: "list".into(),
            command: "list-panes".into(),
            args: vec![],
        };
        assert_eq!(action_argv(&empty), vec!["list-panes"]);
    }

    #[test]
    fn review_summary_names_everything_the_dialog_shows() {
        let manifest = parse_manifest(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.0"
build = ["make", "build"]
startup = ["make", "serve"]

[[actions]]
name = "run-tests"
command = "pane-run"
[actions.args]
command = "cargo test"

[[events]]
name = "on-done"
type = "pane.killed"

[[link_handlers]]
scheme = "demo"
command = ["gpty", "new-pane"]

[[profiles]]
name = "CI"
tiles = [{settings = {type = "terminal"}, col = 0, row = 0}]
"#,
        )
        .unwrap();
        let target = parse_target("owner/repo").unwrap();
        let summary = review_summary(&manifest, &target, "abc123def456");
        assert_eq!(summary["id"], "owner/repo");
        assert_eq!(summary["revision"], "abc123def456");
        // A bare install resolves the default branch tip; the dialog says so
        // instead of showing a ref the user never named.
        assert_eq!(summary["requested_ref"], "default branch");
        // A named ref is shown as typed: the review answers "what I asked
        // for, resolved to what I get".
        let pinned = parse_target("owner/repo@v1.2.0").unwrap();
        let pinned_summary = review_summary(&manifest, &pinned, "abc123def456");
        assert_eq!(pinned_summary["requested_ref"], "v1.2.0");
        assert_eq!(summary["actions"][0]["command"], "pane-run");
        assert_eq!(summary["actions"][0]["args"]["command"], "cargo test");
        assert_eq!(summary["events"][0]["type"], "pane.killed");
        assert_eq!(summary["link_handlers"][0]["scheme"], "demo");
        assert_eq!(summary["concepts"], 0);
        assert_eq!(summary["profiles"][0]["tiles"], 1);
        assert_eq!(summary["build"], serde_json::json!(["make", "build"]));
    }

    /// The review answers "what would this profile start": the distinct
    /// programs its tiles name, in tile order, capped so a hostile manifest
    /// cannot bloat the dialog.
    #[test]
    fn review_summary_lists_the_programs_each_profile_runs() {
        let tiles: Vec<String> = (0..MAX_PROFILE_PROGRAMS + 3)
            .map(|i| {
                format!(
                    "{{ col = 0, row = 0, settings = {{ type = \"cli_view\", command = \"prog{i}\" }} }}"
                )
            })
            .collect();
        let manifest = parse_manifest(&format!(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.0"

[[profiles]]
name = "Tools"
tiles = [
  {{ col = 0, row = 0, cspan = 30, rspan = 60, settings = {{ type = "terminal", command = "omp" }} }},
  {{ col = 30, row = 0, cspan = 30, rspan = 60, settings = {{ type = "terminal", command = "omp" }} }},
  {{ col = 0, row = 0, cspan = 60, rspan = 60, settings = {{ type = "code_viewer" }} }},
  {{ col = 0, row = 0, cspan = 60, rspan = 60, settings = {{ type = "terminal", command = "nvim" }} }},
]
"#
        ))
        .unwrap();
        let summary = review_summary(&manifest, &parse_target("owner/repo").unwrap(), "abc123");
        // Distinct, tile order, and a tile with no `command` contributes
        // nothing — the dialog never claims a code viewer runs a program.
        assert_eq!(
            summary["profiles"][0]["programs"],
            serde_json::json!(["omp", "nvim"])
        );

        let many = parse_manifest(&format!(
            "id = \"owner/repo\"\nname = \"Demo\"\nversion = \"1.0.0\"\nmin_gpty_version = \"0.5.0\"\n[[profiles]]\nname = \"Many\"\ntiles = [{}]\n",
            tiles.join(", ")
        ))
        .unwrap();
        let summary = review_summary(&many, &parse_target("owner/repo").unwrap(), "abc123");
        let programs = summary["profiles"][0]["programs"].as_array().unwrap();
        assert_eq!(programs.len(), MAX_PROFILE_PROGRAMS);
        assert_eq!(programs[0], "prog0", "tile order is what the review shows");
    }

    /// The store record is the GUI's only view of a plugin's tiles, so the
    /// toml → JSON conversion has to keep the tile shape (nested tables and
    /// arrays included) intact.
    #[test]
    fn profile_records_carry_the_validated_tiles_as_json() {
        let manifest = parse_manifest(
            r#"
id = "owner/repo"
name = "Demo"
version = "1.0.0"
min_gpty_version = "0.5.0"

[[profiles]]
name = "Tools"
tiles = [
  { col = 0, row = 0, cspan = 30, rspan = 60, settings = { type = "cli_view", attachment_id = "git-log", command = "git", shell_args = ["log", "--oneline"] } },
]
"#,
        )
        .unwrap();
        let records = profile_records(&manifest);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].name, "Tools");
        assert_eq!(records[0].tiles.len(), 1);
        let tile = &records[0].tiles[0];
        assert_eq!(tile["settings"]["command"], "git");
        assert_eq!(
            tile["settings"]["shell_args"],
            serde_json::json!(["log", "--oneline"])
        );
        assert_eq!(tile["cspan"], 30);
    }

    #[test]
    fn read_manifest_caps_size() {
        let dir =
            std::env::temp_dir().join(format!("gpty-plugin-manifest-cap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(plugin_manifest::MANIFEST_FILENAME),
            "x".repeat(MAX_MANIFEST_BYTES + 1),
        )
        .unwrap();
        assert!(
            read_manifest(&dir)
                .unwrap_err()
                .to_string()
                .contains("at most")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
