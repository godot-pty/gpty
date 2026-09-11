//! Measures what a flooding pane costs the process, and how the terminal and
//! the scrollback store each keep up.
//!
//! Spawns one terminal through the real engine with a grid and a persistent
//! scrollback attached (the same shape the GUI builds), runs an endless line
//! flood in it, and samples RSS every 500 ms. Two rates are printed: how fast
//! the pane consumes PTY output (`generation` counts fed chunks, each up to
//! 4 KiB) and how fast the store commits rows (the writer thread's cadence,
//! forced with a flush so the sample is not just the flush interval).
//!
//!     cargo run --release -p gpty-core --example flood_probe -- <seconds>
//!
//! Linux only (reads `/proc/self/status`). Recorded with the v0.5.4 write
//! path: the pane consumes the flood at ~100 MB/s while the store trails at
//! ~0.11 M rows/s and RSS stays flat (30 MiB), versus 2.2 GiB in 20 s with
//! the old unbounded output queue.

use std::time::{Duration, Instant};

use gpty_core::engine::WorkspaceEngine;
use gpty_core::history::PaneHistory;
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
    let history = PaneHistory::open(db.to_str().unwrap(), "probe", 10_000).expect("history");
    let store = std::sync::Arc::clone(history.store());
    let history = std::sync::Arc::new(history);
    if let Ok(mut grid) = spawned.grid.lock() {
        grid.history = Some(std::sync::Arc::clone(&history));
    }

    let start = Instant::now();
    let mut peak_rss = 0u64;
    let mut last_generation = 0u64;
    let mut last_sample = Instant::now();
    while start.elapsed() < Duration::from_secs(seconds) {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let rss = rss_kib().unwrap_or(0);
        peak_rss = peak_rss.max(rss);

        let (generation, rows_on_screen) = spawned
            .grid
            .lock()
            .map(|g| (g.generation, g.num_rows()))
            .unwrap_or((0, 0));
        // A flush makes the committed count reflect the queue rather than the
        // flush interval; a sample could otherwise read the store mid-window.
        history.flush();
        let rows = store
            .lock()
            .map(|s| s.line_count().unwrap_or(0))
            .unwrap_or(0);
        let pending = history.pending();

        let dt = last_sample.elapsed().as_secs_f32();
        let chunks = generation.saturating_sub(last_generation);
        println!(
            "{:>5.1}s  rss {:>6} MiB  pane {:>6.1} MB/s  stored {:>6} rows  pending {:>7}  grid {}x{}",
            start.elapsed().as_secs_f32(),
            rss / 1024,
            (chunks as f32 * 4096.0) / dt / 1_000_000.0,
            rows,
            pending,
            rows_on_screen,
            spawned.grid.lock().map(|g| g.num_cols()).unwrap_or(0)
        );
        last_generation = generation;
        last_sample = Instant::now();
    }
    println!("peak rss {} MiB", peak_rss / 1024);
    let _ = std::fs::remove_file(&db);
}
