//! # gpty — terminal workspace CLI
//!
//! Controls the gpty GUI over JSON-RPC IPC.
//!
//! A GUI is started on demand only for commands a fresh instance can satisfy
//! — `new-pane` and `layout load` — and `--no-daemon` refuses even those.
//! Every other command answers with the shared "no gpty GUI is running"
//! hint when nothing is listening, instead of opening a window it cannot
//! use; `gpty daemon start` starts one explicitly (the hint names it).

mod commands;
mod plugin_manifest;
mod plugin_store;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::process;
use std::time::Duration;

use clap::{CommandFactory, Parser};
use gpty_ipc::client::IpcClient;
use gpty_ipc::transport;

/// Bundled agent skill, shipped at `skills/gpty/SKILL.md` and printed by `gpty --skill`.
const SKILL: &str = include_str!("../../../skills/gpty/SKILL.md");

#[derive(Parser)]
#[command(
    name = "gpty",
    version,
    about = "Control the gpty ADE — a graphical PTY foundation with a public API",
    long_about = None
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Print the bundled agent skill (SKILL.md) and exit
    #[arg(long)]
    skill: bool,

    /// Machine-readable JSON output
    #[arg(long, global = true)]
    json: bool,

    /// IPC socket path (default: platform-specific)
    #[arg(long, global = true)]
    socket: Option<String>,

    /// Connection timeout in milliseconds
    #[arg(long, global = true, default_value = "5000")]
    timeout: u64,

    /// Never start a GUI (commands that need one fail)
    #[arg(long, global = true)]
    no_daemon: bool,

    /// Verbose output to stderr
    #[arg(short, long, global = true)]
    verbose: bool,
}

#[derive(clap::Subcommand)]
enum Commands {
    /// Open a new pane
    NewPane {
        /// Pane type: terminal, code_viewer, file_tree, inspector, reasoning, cli_view
        #[arg(short = 't', long, default_value = "terminal")]
        pane_type: String,

        /// Shell command to run (terminal only)
        #[arg(short, long)]
        command: Option<String>,

        /// Program arguments (cli_view only; repeatable)
        #[arg(long = "arg", value_name = "ARG", allow_hyphen_values = true)]
        args: Vec<String>,

        /// Split direction: left, right, top, bottom
        #[arg(short, long, default_value = "bottom")]
        split: String,

        /// Pane title
        #[arg(long)]
        title: Option<String>,

        /// Focus the new pane
        #[arg(short, long, default_value = "true")]
        focus: bool,

        /// Comma-separated pane tags for broadcast targeting
        #[arg(long, value_delimiter = ',')]
        tags: Vec<String>,
    },

    /// List all active panes
    ListPanes,

    /// Close a pane
    KillPane {
        /// Pane ID or "active"
        pane_id: String,
    },

    /// Focus a pane
    FocusPane {
        /// Pane ID
        pane_id: String,
    },

    /// Send text to a terminal pane
    Inject {
        /// Target pane ID
        pane_id: String,

        /// Text to send (trailing newline added)
        #[arg(short, long)]
        text: String,
    },

    /// Output JSON Schema describing all commands
    Schema {
        /// Output format: json-schema, mcp
        #[arg(long, default_value = "json-schema")]
        format: String,
    },

    /// Manage the GUI daemon
    Daemon {
        #[command(subcommand)]
        action: DaemonAction,
    },

    /// Save, load, or list workspace layouts
    Layout {
        #[command(subcommand)]
        action: LayoutAction,
    },

    /// List, enable, or disable concept triggers
    Concept {
        #[command(subcommand)]
        action: ConceptAction,
    },

    /// Install, manage, and run plugins
    Plugin {
        #[command(subcommand)]
        action: PluginAction,
    },

    /// Read pane output (screen plus scrollback)
    PaneRead {
        /// Target pane ID or label
        pane_id: String,

        /// Max lines (1-2000)
        #[arg(long, default_value = "200")]
        lines: i64,
    },

    /// Pane status; omit the pane for every pane's status
    PaneStatus {
        /// Target pane ID or label (omit for all panes)
        pane_id: Option<String>,
    },

    /// Declare this pane's agent state (run inside a pane; display only)
    State {
        /// idle, working, needs-attention, completed, or failed
        value: String,
    },

    /// Run a command in a new terminal pane (executed through the configured shell)
    PaneRun {
        /// Command to run
        #[arg(long)]
        command: String,
    },

    /// Wait for a pane's output to match a regex pattern
    PaneWait {
        /// Target pane ID or label
        pane_id: String,

        /// Regex pattern (Rust regex syntax, max 1024 chars)
        #[arg(long)]
        pattern: String,

        /// Server-side deadline in ms (100-60000)
        #[arg(long, default_value = "10000")]
        timeout_ms: u64,
    },

    /// Inject text into every tagged terminal pane
    Broadcast {
        /// Comma-separated pane tags
        #[arg(long, value_delimiter = ',')]
        tags: Vec<String>,

        /// Text to send
        #[arg(short, long)]
        text: String,
    },

    /// Run as MCP server over stdio
    Mcp,

    /// Print version info
    Version,
}

#[derive(clap::Subcommand)]
enum ConceptAction {
    /// List all concepts with enabled/disabled status
    List,
    /// Enable or disable a concept by name
    Toggle {
        /// Concept name
        name: String,
    },
}

#[derive(clap::Subcommand)]
enum DaemonAction {
    /// Start the GUI daemon
    Start,
    /// Stop the running GUI
    Stop,
    /// Check daemon status
    Status,
}

#[derive(clap::Subcommand)]
enum LayoutAction {
    /// Save current layout
    Save { name: String },
    /// Load a saved layout
    Load { name: String },
    /// List saved layouts
    List,
}

#[derive(clap::Subcommand)]
enum PluginAction {
    /// Install a plugin from a git repo, reviewed in the GUI
    Install {
        /// Plugin target: owner/repo, or owner/repo@ref where ref is any
        /// tag, branch, or commit SHA. A bare owner/repo installs the
        /// default branch's latest.
        target: String,
    },
    /// List installed plugins
    List,
    /// Enable a plugin
    Enable {
        /// Plugin id (owner/name)
        id: String,
    },
    /// Disable a plugin
    Disable {
        /// Plugin id (owner/name)
        id: String,
    },
    /// Remove a plugin and its per-plugin directories
    Uninstall {
        /// Plugin id (owner/name)
        id: String,
    },
    /// Show a plugin's log files
    Logs {
        /// Plugin id (owner/name)
        id: String,

        /// Lines of the newest log to show
        #[arg(long, default_value = "50")]
        lines: usize,
    },
    /// Run one of the plugin's declared actions through the gpty CLI
    Run {
        /// Plugin id (owner/name)
        id: String,

        /// The action's name in the manifest
        action: String,
    },
    /// Check a manifest file or plugin directory with the install validator
    Validate {
        /// Path to a `gpty-plugin.toml`, or to the plugin directory holding it
        path: PathBuf,
    },
}

/// Whether the generic gate may start a GUI for this command.
///
/// Only commands a *fresh* GUI can satisfy: creating a pane, or restoring a
/// saved layout. Every other command needs a workspace that already exists —
/// starting one would add a window and then fail at the command's actual
/// work, so those answer with `daemon::NO_GUI_HINT` instead (the same
/// message `--no-daemon` produces for the two that may spawn). `plugin
/// install` and `daemon start` never reach this gate: each is handled in its
/// own arm (the install review, and the explicit start).
///
/// Exhaustive on purpose: a new subcommand must choose a side.
fn may_autospawn(cmd: &Commands) -> bool {
    match cmd {
        Commands::NewPane { .. } => true,
        Commands::Layout {
            action: LayoutAction::Load { .. },
        } => true,
        Commands::ListPanes
        | Commands::KillPane { .. }
        | Commands::FocusPane { .. }
        | Commands::Inject { .. }
        | Commands::Schema { .. }
        | Commands::Daemon { .. }
        | Commands::Layout { .. }
        | Commands::Concept { .. }
        | Commands::Plugin { .. }
        | Commands::PaneRead { .. }
        | Commands::PaneStatus { .. }
        | Commands::State { .. }
        | Commands::PaneRun { .. }
        | Commands::PaneWait { .. }
        | Commands::Broadcast { .. }
        | Commands::Mcp
        | Commands::Version => false,
    }
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    if cli.verbose {
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    }

    // `--skill` prints the bundled agent skill and exits; no IPC, no daemon.
    if cli.skill {
        print!("{SKILL}");
        process::exit(0);
    }

    let socket_path = cli
        .socket
        .or_else(|| std::env::var("GPTY_SOCKET").ok())
        .unwrap_or_else(transport::default_socket_path);
    let timeout = Duration::from_millis(cli.timeout);

    // Handle commands that don't need IPC.
    match &cli.command {
        Some(Commands::Schema { format }) => {
            let result = commands::schema::run(format);
            match result {
                Ok(()) => process::exit(0),
                Err(e) => {
                    eprintln!("{e}");
                    process::exit(1);
                }
            }
        }
        Some(Commands::Version) => {
            println!("gpty {}", env!("CARGO_PKG_VERSION"));
            println!("protocol: 2.0");
            process::exit(0);
        }
        Some(Commands::Mcp) => {
            let client = IpcClient::new(&socket_path, timeout);
            if let Err(e) = commands::mcp::run(&client, &socket_path, timeout).await {
                eprintln!("mcp error: {e}");
                process::exit(1);
            }
            process::exit(0);
        }
        // `state` talks to the event socket with the credentials its parent
        // pane injected — never the control socket — so it must not reach the
        // daemon auto-spawn below (a pane strips GPTY_SOCKET/GPTY_SECRET, and
        // the declaration belongs to the pane that is already running).
        Some(Commands::State { value }) => {
            match commands::state::run(value, cli.json, timeout).await {
                Ok(()) => process::exit(0),
                Err(e) => {
                    eprintln!("{e}");
                    process::exit(1);
                }
            }
        }
        // `plugin` admin actions (list, enable, uninstall, logs, run) touch
        // only the store and the installed content — spawning the GUI for
        // them would be noise. `install` is the one action that needs the
        // GUI (its review dialog), and it ensures the daemon itself, so the
        // arm must sit above the auto-spawn below.
        Some(Commands::Plugin { action }) => {
            match commands::plugin::run(action, &socket_path, timeout, cli.json, cli.no_daemon)
                .await
            {
                Ok(()) => process::exit(0),
                Err(e) => {
                    report_error(&e);
                    process::exit(1);
                }
            }
        }
        // `daemon` owns its whole surface here: `start` is the explicit
        // spawner, and `stop`/`status` report a missing GUI instead of being
        // refused by the generic gate below (which must never spawn for a
        // command that only asks or shuts down).
        Some(Commands::Daemon { action }) => {
            match commands::daemon::run(action, &socket_path, timeout, cli.json, cli.no_daemon)
                .await
            {
                Ok(code) => process::exit(code),
                Err(e) => {
                    eprintln!("error: {e}");
                    process::exit(1);
                }
            }
        }
        None => {
            Cli::command().print_help().ok();
            process::exit(2);
        }
        _ => {}
    }

    let Some(command) = &cli.command else {
        unreachable!("handled above");
    };

    // Start a GUI only for commands a fresh workspace can satisfy, and only
    // when `--no-daemon` allows it. The never-spawn set (and `--no-daemon`)
    // reach the GUI through the dispatch below and fail there with the shared
    // hint when nothing answers — never with a window they cannot use.
    if !cli.no_daemon
        && may_autospawn(command)
        && let Err(e) = commands::daemon::ensure_running(&socket_path, timeout).await
    {
        eprintln!("error: {e}");
        process::exit(1);
    }

    let client = IpcClient::new(&socket_path, timeout);
    match commands::dispatch(command, &client, cli.json).await {
        Ok(()) => process::exit(0),
        Err(e) => {
            report_error(&e);
            process::exit(1);
        }
    }
}

/// Print a failed command: the shared no-GUI hint when nothing is listening
/// on the control socket, the error itself otherwise. The never-spawn set
/// and `--no-daemon` both land here, so all of them answer the same way.
fn report_error(e: &anyhow::Error) {
    if commands::daemon::is_not_running(e) {
        eprintln!("error: {}", commands::daemon::NO_GUI_HINT);
    } else {
        eprintln!("error: {e}");
    }
}
