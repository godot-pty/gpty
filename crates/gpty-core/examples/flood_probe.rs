//! Measures what a flooding pane costs the process, and how fast the pane
//! consumes it.
//!
//! Spawns one terminal through the real engine with a grid and a SQLite
//! history store attached (the same shape the GUI builds), runs an endless
//! line flood in it, and samples this process's RSS plus the pane's drained
//! line count every 500 ms. Use it to re-measure the output-path bounds —
//! `pty::OUTPUT_QUEUE_CHUNKS` (backpressure) and the history write path —
//! after touching either.
//!
//!     cargo run -p gpty-core --example flood_probe -- <seconds>
//!
//! Linux only (reads `/proc/self/status`). Recorded on the v0.5.4
//! backpressure change, 12 s: unbounded queue 1379 MiB peak with ~29 k
//! lines/s drained; bounded queue 30 MiB peak, same drain rate.

use std::time::{Duration, Instant};

use gpty_core::engine::WorkspaceEngine;
use gpty_core::history::HistoryStore;
use gpty_core::types::TerminalConfig;

fn rss_kib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            return rest.trim().trim_end_matches(" kB").trim().parse().ok();
        }
    }
    None
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let seconds: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);

    let engine = WorkspaceEngine::new(vec![]);
    let spawned = engine
        .spawn_terminal_with_grid(
            TerminalConfig { id: 1 },
            "sh",
            &["-c", "yes flood-line-flood-line-flood-line"],
            &[],
            &[],
            24,
            80,
        )
        .await
        .expect("spawn");

    let db = std::env::temp_dir().join(format!("flood-probe-{}.db", std::process::id()));
    let store = HistoryStore::open(db.to_str().unwrap(), "probe", 10_000).expect("history");
    let history = std::sync::Arc::new(std::sync::Mutex::new(store));
    if let Ok(mut grid) = spawned.grid.lock() {
        grid.history = Some(history.clone());
    }

    let start = Instant::now();
    let mut peak_rss = 0u64;
    let mut peak_lines = 0i64;
    while start.elapsed() < Duration::from_secs(seconds) {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let rss = rss_kib().unwrap_or(0);
        peak_rss = peak_rss.max(rss);
        // Monotonic (the row cap hides progress): the drain rate is what the
        // backpressure ceiling is set against.
        let lines = history
            .lock()
            .map(|h| h.max_line_num().unwrap_or(0))
            .unwrap_or(0);
        peak_lines = peak_lines.max(lines);
        let elapsed = start.elapsed().as_secs_f32();
        println!(
            "{elapsed:>5.1}s  rss {:>6} MiB  lines drained {lines:>9}  ({:.0}/s)",
            rss / 1024,
            lines as f32 / elapsed
        );
    }
    println!("peak rss {} MiB over {peak_lines} lines", peak_rss / 1024);
    let _ = std::fs::remove_file(&db);
}
