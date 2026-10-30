//! # gpty-core
//!
//! The engine behind gpty: a cross-platform multi-PTY emulator.
//!
//! ## Module Map
//!
//! | Module | Role |
//! |--------|------|
//! | [`types`]  | Data vocabulary: `Concept`, `Event`, `Action`, `TerminalConfig` |
//! | [`concept`]| Regex trigger → labelled action routing (pure functions, no I/O) |
//! | [`agent_state`] | Tiered, display-only agent-state detection (events / OSC / heuristics) |
//! | [`engine`] | Central pub-sub orchestrator; spawns terminal tasks on the tokio runtime |
//! | [`pty`]    | Cross-platform PTY lifecycle via `portable-pty`; one OS thread per PTY |
//! | [`hardening`] | Keeps gPTY's own environment (the control secret) out of reach of pane programs |
//! | [`cli`]    | `cli_view` backend: one argv child, stdout+stderr merged into a bounded line queue |
//! | [`parser`] | Strips ANSI escape sequences from PTY output; extracts plain-text lines |
//! | [`escstring`] | Bounds an unterminated escape string so a pane program cannot grow parser memory |
//! | [`term`]   | Full terminal grid via `alacritty_terminal`; cursor, colors, scrolling |
//!
//! ## Data Flow
//!
//! ```text
//! PTY bytes ──→ [pty] ──→ [term] ──→ grid cells ──→ Godot _draw()  (Phase 2+)
//!                     │
//!                     └──→ [parser] ──→ plain-text lines
//!                                              │
//!                     ┌────────────────────────┘
//!                     ▼
//!              [concept] ──→ regex match? ──→ [engine] broadcast Event
//!                                                     │
//!                                                     ▼
//!                                              other terminal tasks
//!                                              (check labels → inject command)
//! ```

pub mod agent_state;
pub mod cli;
pub mod color;
pub mod concept;
pub mod engine;
pub mod escstring;
pub mod hardening;
pub mod history;
pub mod keymap;
pub mod links;
pub mod lock;
pub mod parser;
pub mod pty;
pub mod term;
pub mod types;
pub mod vault;
