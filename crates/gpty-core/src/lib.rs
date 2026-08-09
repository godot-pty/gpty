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
//! | [`engine`] | Central pub-sub orchestrator; spawns terminal tasks on the tokio runtime |
//! | [`pty`]    | Cross-platform PTY lifecycle via `portable-pty`; one OS thread per PTY |
//! | [`parser`] | Strips ANSI escape sequences from PTY output; extracts plain-text lines |
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

pub mod color;
pub mod concept;
pub mod engine;
pub mod history;
pub mod keymap;
pub mod parser;
pub mod pty;
pub mod term;
pub mod types;
