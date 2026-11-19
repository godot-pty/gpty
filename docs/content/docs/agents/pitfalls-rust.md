---
title: "Pitfalls: Rust & FFI"
weight: 82
---

Traps and patterns for Rust, GDExtension (`gdext`), FFI boundaries, concurrency, and persistent storage.

## GDExtension Boundary & gdext

- **Parameter type marshaling:** In `gdext`, only `GString`, `bool`, and `i64` are reliably marshaled as direct input parameters in `#[func]` methods. Passing `Array<Variant>`, `Dictionary`, or bare `Variant` can silently fail (the GDScript call succeeds while the Rust method body never executes). Serialize complex structured payloads to JSON strings and deserialize with `serde_json`.
- **Typed arrays across FFI:** Passing a GDScript typed array like `Array[Dictionary]` to a Rust `Array<Variant>` parameter fails at runtime with type mismatch errors. Keep arrays untyped across the boundary.
- **Renamed exports break at runtime:** Renaming an exported `#[func]` is syntactically valid in GDScript but fails at runtime when the method is invoked. `scripts/check-ffi-surface` cross-checks all calls against the exported GDExtension surface.
- **Library pinning on exit:** Unloading the GDExtension shared library (`dlclose` or `FreeLibrary`) while background tokio worker or PTY reader threads are still running causes immediate segmentation faults. `pin_library()` pins the mapping using `RTLD_NODELETE` on Unix and `GetModuleHandleExW` on Windows.
- **Rebuilding maps and SIGBUS:** Overwriting a mapped `.so` in place with `cp` causes running processes to crash with `SIGBUS` ("Misaligned address error"). `scripts/build` installs extension libraries by staging to a `.new` temporary file and performing an atomic rename over the target path.

## Concurrency, Threads & Tokio

- **SceneTree is strictly single-threaded:** Never invoke Godot engine methods, emit signals, or mutate nodes from background tokio tasks or worker threads. Queue updates in bounded thread-safe channels for GDScript to poll on `_process()`, or invoke `call_deferred()`.
- **Short-lived TermGrid locks:** `TermGrid` is shared across threads via `Arc<Mutex<TermGrid>>`. Acquire the lock briefly to copy cell damage or push input, and release it immediately. Holding the lock during blocking I/O freezes the rendering thread.
- **`std::sync::Mutex` and poisoning:** Use `std::sync::Mutex` throughout. A poisoned lock indicates a thread panic; log and report via `gpty_core::lock::lock_or_warn(mutex, "what")` rather than using bare unwraps or silent ignores.
- **`tokio::pin!` + `reset()` for timeouts:** Re-arming timeouts inside capture loops should use `tokio::pin!(sleep)` and `sleep.as_mut().reset(deadline)` rather than recreating timer instances in every `select!` iteration.
- **`tokio::select!` on closed channels:** When an `mpsc::Receiver` returns `None`, `tokio::select!` disables that branch but continues spinning on remaining branches, pegging CPU at 100%. Bind the receiver explicitly and break when the channel closes.
- **Task handles detach on drop:** Dropping a `tokio::task::JoinHandle` does not abort the task; it continues running in the background. Explicitly call `handle.abort()` in `Drop` implementations when child tasks must terminate.
- **CLI single-thread runtime:** The CLI binary runs on `#[tokio::main(flavor = "current_thread")]`. CLI commands execute single requests and exit immediately; multi-threaded worker pools add process startup overhead and introduce teardown exit races.

## Storage, SQLite & Persistence

- **Process-wide write serialization:** Multiple SQLite writer threads across panes competing for the same database file cause busy timeouts and dropped batches. `store::write_guard` provides process-wide write serialization.
- **Damaged database recovery:** A corrupted database file that begins with SQLite page bytes but lacks a valid schema causes SQLite recovery to fail. `store::open_with_recovery` detects corrupt databases, moves them to `<path>.corrupt`, and initializes fresh, clean stores.
- **Forward-compatible store readers:** Readers for JSON configuration stores (`plugins.json`, etc.) must ignore unknown sibling keys rather than failing as corrupt. Closed validation rules belong on manifest checkers and writers, not on store deserializers.
- **Owner-only file permissions:** Stores containing terminal scrollback, settings, or encryption secrets must be created and repaired to 0700 for directories and 0600 for files using `gpty_core::owner_only`.
