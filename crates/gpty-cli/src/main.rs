//! # gpty — terminal workspace CLI
//!
//! Controls the gpty GUI over JSON-RPC IPC.
//! When the GUI is not running, `gpty` can auto-spawn it
//! (unless `--no-daemon` is passed).

mod commands;
#[cfg(test)]
mod tests;

use std::process;
use std::time::Duration;

use clap::Parser;
use gpty_ipc::client::IpcClient;
use gpty_ipc::transport;

#[derive(Parser)]
#[command(
    name = "gpty",
    version,
    about = "Control the gpty terminal workspace",
    long_about = None
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Machine-readable JSON output
    #[arg(long, global = true)]
    json: bool,

    /// IPC socket path (default: platform-specific)
    #[arg(long, global = true)]
    socket: Option<String>,

    /// Connection timeout in milliseconds
    #[arg(long, global = true, default_value = "5000")]
    timeout: u64,

    /// Don't auto-spawn the GUI if not running
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
        /// Pane type: terminal, code_viewer, file_tree, inspector, reasoning
        #[arg(short = 't', long, default_value = "terminal")]
        pane_type: String,

        /// Shell command to run (terminal only)
        #[arg(short, long)]
        command: Option<String>,

        /// Split direction: left, right, top, bottom
        #[arg(short, long, default_value = "bottom")]
        split: String,

        /// Pane title
        #[arg(long)]
        title: Option<String>,

        /// Focus the new pane
        #[arg(short, long, default_value = "true")]
        focus: bool,
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

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    if cli.verbose {
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    }

    let socket_path = cli
        .socket
        .or_else(|| std::env::var("GPTY_SOCKET").ok())
        .unwrap_or_else(transport::default_socket_path);
    let timeout = Duration::from_millis(cli.timeout);

    // Handle commands that don't need IPC.
    match &cli.command {
        Commands::Schema { format } => {
            let result = commands::schema::run(format);
            match result {
                Ok(()) => process::exit(0),
                Err(e) => {
                    eprintln!("{e}");
                    process::exit(1);
                }
            }
        }
        Commands::Version => {
            println!("gpty {}", env!("CARGO_PKG_VERSION"));
            println!("protocol: 2.0");
            process::exit(0);
        }
        Commands::Mcp => {
            let client = IpcClient::new(&socket_path, timeout);
            if let Err(e) = commands::mcp::run(&client).await {
                eprintln!("mcp error: {e}");
                process::exit(1);
            }
            process::exit(0);
        }
        _ => {}
    }

    // Ensure daemon is running (unless --no-daemon).
    if !cli.no_daemon
        && let Err(e) = commands::daemon::ensure_running(&socket_path, timeout).await
    {
        eprintln!("error: {e}");
        eprintln!("  Is gpty running? Start it or pass --no-daemon to skip.");
        process::exit(1);
    }

    let client = IpcClient::new(&socket_path, timeout);
    let result = commands::dispatch(&cli.command, &client, cli.json).await;

    match result {
        Ok(()) => process::exit(0),
        Err(e) => {
            eprintln!("{e}");
            process::exit(1);
        }
    }
}
