//! Cross-platform PTY lifecycle via [`portable_pty`].
//!
//! Spawns a shell process connected to a pseudo-terminal, runs a
//! dedicated I/O thread for reading, and exposes write/resize operations.
//! Each PTY uses one OS thread.

use std::io::{Read, Write};
use std::thread;

use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use tokio::sync::mpsc::UnboundedSender;

const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;
const READ_BUF_SIZE: usize = 4096;
/// A handle to a spawned PTY: shell process + I/O thread.

pub struct PtyHandle {
    pub id: u32,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    _child: Box<dyn portable_pty::Child + Send + Sync>,
    _read_thread: thread::JoinHandle<()>,
}

impl Drop for PtyHandle {
    fn drop(&mut self) {
        let _ = self._child.kill();
    }
}

impl PtyHandle {
    /// Spawn a shell process in a new PTY and start a reader thread.
    /// Output bytes are sent to `tx` as `Vec<u8>` chunks.
    pub fn spawn(
        id: u32, command: &str, args: &[&str], envs: &[String], tx: UnboundedSender<Vec<u8>>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let pty_system = native_pty_system();
        let mut cmd = CommandBuilder::new(command);
        cmd.args(args);
        cmd.env("TERM", "xterm-256color");
        for e in envs {
            if let Some((k, v)) = e.split_once('=') {
                cmd.env(k.trim(), v.trim());
            }
        }

        let pty_pair = pty_system.openpty(PtySize {
            rows: DEFAULT_ROWS, cols: DEFAULT_COLS, pixel_width: 0, pixel_height: 0,
        })?;
        let child = pty_pair.slave.spawn_command(cmd)?;
        let mut reader = pty_pair.master.try_clone_reader()?;
        let writer = pty_pair.master.take_writer()?;
        let master = pty_pair.master;

        let read_thread = thread::Builder::new()
            .name(format!("pty-reader-{id}"))
            .spawn(move || {
                let mut buf = [0u8; READ_BUF_SIZE];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => { if tx.send(buf[..n].to_vec()).is_err() { break; } }
                        Err(e) => { log::error!("[PTY {id}] Read error: {e}"); break; }
                    }
                }
            })?;

        Ok(Self { id, writer, master, _child: child, _read_thread: read_thread })
    }

    /// Write a line to the PTY (appends `\r` = Enter).
    pub fn write_line(&mut self, line: &str) -> Result<(), std::io::Error> {
        self.writer.write_all(line.as_bytes())?;
        self.writer.write_all(b"\r")?;
        self.writer.flush()
    }

    /// Write raw bytes to the PTY (no newline appended).
    pub fn write_bytes(&mut self, data: &[u8]) -> Result<(), std::io::Error> {
        self.writer.write_all(data)?;
        self.writer.flush()
    }

    /// Resize the PTY — sends SIGWINCH to the child process.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })?;
        Ok(())
    }
}
