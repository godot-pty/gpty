# gpty-gdext

Godot 4 GDExtension that bridges the Rust terminal engine to Godot's renderer.

`GptyTerminal` is a headless `Node2D` bridge owning the Rust grid; the visible
terminal is the `Control`-based renderer
`godot/scenes/terminal/terminal_pane.gd`, which polls
`get_grid_updates_packed()` and draws in `_draw()`.

## Building

```bash
# From the workspace root
cargo build -p gpty-gdext && cd godot && godot -e
```

`gpty.gdextension` always loads `res://bin/libgpty_gdext.linux.x86_64.so`.
For editor work, that file should be a symlink to `target/debug/libgpty_gdext.so`
so `cargo build -p gpty-gdext` is enough. Restart Godot after each rebuild.
`./scripts/build` replaces the symlink with a release copy for export.

## GDScript API

The implementation is filed by facet under `src/`, one `#[godot_api(secondary)]` impl block
per file - `lib.rs` holds the class itself (session lifecycle, input, the grid access
helpers), `grid_api.rs`, `history_api.rs`, `vault_api.rs`, `capture_api.rs` and `bridge_api.rs` hold the
rest. The sections below are those facets.

### GptyMarkdown (extends RefCounted)

| Method | Returns | Description |
|--------|---------|-------------|
| `render(markdown: String, wikilinks: bool)` | `String` | Convert untrusted CommonMark/GFM to sanitized `RichTextLabel` BBCode. `wikilinks` renders `[[target]]` / `[[target|alias]]` / `[[target#heading]]` as internal `gpty-note:` links (percent-encoded target, escaped label) - only the wiki pane sets it, and the renderer is the only producer of that scheme; every other caller keeps the literal text. Occurrences are the `gpty_core::links` parser's (fences, inline code and escaped openers stay literal) and are spliced in through a sentinel before parsing, so surrounding Markdown is untouched. JSON: `{text, truncated, shown, size}` - the cut travels with the text (`shown`/`size` are bytes of the source, the shape a pane read answers) because the input is capped and a prefix must not be rendered in silence |

Raw BBCode and HTML are escaped, images render as alt text, and only
`http`, `https`, and `mailto` links become metadata. Godot asks for
confirmation before `MarkdownView` opens an external link; a `gpty-note:`
mention is emitted by this renderer alone under `wikilinks`, and the view
hands it to its owning pane (never to `OS.shell_open`).

The output never uses Godot's list tags: `[ul]`/`[ol]` lay a document out
superlinearly in the item count (measured: 38915 ms to shape 1.7 MiB of
two-item lists against 819 ms for that same rendered text with the tags
stripped, and 146705 ms for a real 1 MiB note), so each item is a `• `/`N. `
line inside one `[indent]` per list - identical on screen and linear to lay
out. The numbering is the renderer's own, which is also why an ordered list
that starts at 3 renders as `3.` rather than `1.`.

The input cap (`MAX_MARKDOWN_BYTES`) is the same 1 MiB the panes read under, so
a document at a pane's read cap renders whole, and a source past it - a pasted
buffer, a routed capture, a long model turn - is what the answer's `truncated`
reports. `MarkdownView` shows that, and a cut its caller made
(`set_source_notice`), as one banner above the body.

### GptyAi (extends Node)

One private Inspector session. There is no process-global subscriber bus.

| Method | Returns | Description |
|--------|---------|-------------|
| `session_open(request_json: String)` | `String` | Open a mock/omp session. JSON: `{backend, system_prompt, cwd, model}` |
| `session_prompt(request_json: String)` | `String` | Submit one turn. JSON: `{session_id, capture, concept_name, source_pane}` |
| `session_poll(request_json: String)` | `String` | Drain correlated envelopes. JSON: `{session_id, max_events}` |
| `session_cancel(request_json: String)` | `String` | Cancel the active turn. JSON: `{session_id}` |
| `session_close(request_json: String)` | `String` | Tear down the backend process. JSON: `{session_id}` |
| `list_backends()` | `String` | JSON array of `{kind, name, available}` |

Inspector omp is launched as `omp --mode rpc --no-session --no-tools --no-extensions --no-skills --no-rules`.

### GptyCliView (extends Node)

One `cli_view` pane's CLI process: a program plus argv, never a shell. The
child's stdout and stderr are merged into one bounded queue of complete lines,
which the pane drains once a frame and renders as plain text. The node strips
the workspace credentials (`GPTY_SECRET`, `GPTY_SOCKET`, …) from the child's
environment, resolves a bare command through `PATH` and holds an absolute one to
`validate_executable`, and kills the child *and its process group* on stop and
on drop.

| Method | Returns | Description |
|--------|---------|-------------|
| `start(config_json: String)` | `String` | Start the CLI. JSON: `{command, args}` - `command` non-empty and ≤1024 chars, `args` ≤32 entries of ≤4096 chars, no U+FFFD in either. `{"ok":true,"pid":N}` or `{"ok":false,"error":"..."}`. An existing process is stopped first |
| `poll_lines()` | `PackedStringArray` | Every complete line since the last call, stdout+stderr merged. Non-blocking |
| `status_json()` | `String` | JSON: `{program, args, pid, running, exit_code, exit_reason}`. `pid` is null once the child is gone; `exit_reason` is `exited`, `killed` (stopped by us) or null while it runs. A pane that never started reports the same fields idle |
| `stop()` | void | Kill the child and its process group. Safe with nothing running |

### GptyMedia (extends Node)

One media pane's decode session, backed by `gpty-media` and a pinned FFmpeg
build. All decode work happens on the session's own OS thread; these methods
only hand over JSON or drain a bounded queue.

| Method | Returns | Description |
|--------|---------|-------------|
| `open(config_json: String)` | `String` | Open a file, replacing the current session. JSON: `{path, sample_rate, channels, max_width, max_height, video, audio}`; `sample_rate` defaults to 48000, `channels` to 2, the box to native size, and both stream flags to true (disable one when the caller will not drain its queue). The path is validated synchronously and returns `{"ok":true,"state":"opening"}`; probing/decoding runs on the session thread, and `status()` then reports `Playing` with `info` (`{container,duration_us,video,audio,streams}`) or `Failed` with an error. A refused path is `{"ok":false,"error":{"code","message"}}` immediately |
| `poll_video()` | `Dictionary` | `{}` when empty, else `{width,height,pts_us,keyframe,data}` with `data` a packed RGBA8 array of `width * height * 4` bytes |
| `poll_audio()` | `Dictionary` | `{}` when empty, else `{sample_rate,channels,pts_us,data}` with `data` interleaved f32 at the requested rate/channels |
| `seek(position_us: int)` | `String` | Acknowledged seek; pre-target frames are dropped. `{"ok":true}` or an error envelope |
| `status()` | `String` | `{ok,state,position_us,duration_us,info,error}`; `state` is `opening`, `playing`, `finished`, `failed` or `closed`. `finished` keeps the worker alive for a replay |
| `close()` | void | Stop the decoder and release the file |

Errors use stable `code` values (`bad_path`, `unsupported_container`,
`unsupported_codec`, `too_large`, `open_failed`, `decode_failed`,
`seek_failed`, `closed`, `io_error`, plus `bad_request`/`panic` at the JSON
edge). Media files are untrusted input: the backend re-validates the path,
checks the demuxer and the selected codec id, caps dimensions/channels/queues,
and compiles no network protocol.

### GptyTerminal (extends Node2D)

#### Terminal lifecycle

| Method | Returns | Description |
|--------|---------|-------------|
| `start_shell(cmd: String, rows: int, cols: int, envs: String, pane_id: String, history_lines: int, args_json: String, cwd: String)` | void | Start a PTY session (injects per-PTY event capability, `GPTY_ENV=1`, `GPTY_PANE_ID`); attaches the SQLite history store keyed by `pane_id` and restores the newest `history_lines` rows into scrollback. `args_json` is a JSON array of program arguments (≤32 entries, ≤4096 chars each) - `["-c", cmd]` runs through a shell. An absolute `cmd` must name a regular file that is not group/other-writable and is owned by this user or root; bare names resolve through `PATH`. `cwd` is the workspace's directory: empty inherits gpty's own, and a non-absolute or missing path is ignored rather than failing the pane |
| `send_text(text: String)` | void | Send raw text to PTY (no newline) |
| `send_line(text: String)` | void | Send a line to PTY (appends `\n`) |
| `resize_grid(rows: int, cols: int)` | `bool` | Resize grid + send SIGWINCH. `false` = refused (grid lock poisoned) and nothing moved, PTY included; a pane with no shell answers `true` |
| `set_palette(hex_csv: String)` | void | Load color scheme (16 hex colors, CSV) |
| `get_terminal_session_id()` | `String` | Opaque id for the current PTY lifetime |

#### App metadata

| Method | Returns | Description |
|--------|---------|-------------|
| `get_app_version()` | `String` | App version from `CARGO_PKG_VERSION` (static - call as `GptyTerminal.get_app_version()`) |
| `get_ipc_protocol_version()` | `String` | Static - the control-IPC protocol version (`gpty_ipc::protocol::PROTOCOL_VERSION`), the single definition the server's `version` method reports and the CLI prints; the About tab reads it so the label cannot drift from the wire |
| `installed_plugin_profiles()` | `String` | Static - JSON array of `{plugin_id, revision, name, tiles}`, one entry per profile of every **enabled** installed plugin, in store order (`tiles` are the manifest's raw tile dictionaries; the caller sanitizes each field). Reads `<state_dir>/plugins.json`; a missing or broken store is `[]` plus one warn, never an error. Plugins installed before the profiles migration, and profile entries without a string `name` or a `tiles` list, contribute nothing |
| `omp_event_stats()` | `String` | Static - the OMP event pipeline's counters: cumulative `accepted`/`accepted_bytes`/`drained_events`/`drained_bytes`, `rejected_queue_full`/`rejected_oversized`, and the live `queued_events`/`queued_bytes` against `max_queued_bytes`/`max_session_events`. The Reasoning pane's `GPTY_REASONING_DEBUG` line reads it to separate a slow renderer from a lossy input stream |

#### Vault index

| Method | Returns | Description |
|--------|---------|-------------|
| `vault_index(vault_path: String)` | `String` | Static - walk a vault directory, refresh its index and answer the note list. JSON: `{notes: ["note.md", "sub/other.md", …], truncated, added, updated, removed, unreadable}` (notes sorted by path, hidden entries skipped, bounded at 2000 notes / depth 16). `error` is present only when the path cannot be used or the store cannot be opened |
| `vault_search(vault_path: String, pattern: String, limit: int)` | `String` | Static - FTS5 search within one vault, best rank first. JSON: `{results: [{path, title, snippet}], total}`; free text sanitised into quoted, ANDed terms, notes porter-stemmed, `limit` clamped 1–500. `error` only when the query could not run, so a caller can tell "no match" from "not indexed" |
| `vault_links(vault_path: String, rel_path: String)` | `String` | Static - every `[[wikilink]]` of one note, as the index pass stored it: `{"outgoing": [{"target", "resolved", "line", "seq"}, …]` (one row per occurrence; `resolved` is null while the target does not resolve), `"backlinks": [{"src", "line", "target"}, …]` (the same edges read in reverse), `"unresolved": [{"target", "line", "candidates": […]}, …]` (candidates name the notes an ambiguous stem could not be chosen between)`. `error` only when the vault or the store cannot be used |
| `vault_graph(vault_path: String)` | `String` | Static - the vault's link graph as a canvas reads it. JSON: `{"nodes": [{"id", "label", "ghost"}, …], "edges": [{"src", "dst", "count", "ghost"}, …], "truncated"}`. Nodes are the indexed notes (`id` = vault-relative path, `label` = indexed title) plus one `ghost:<target>` node per distinct unresolved target; edges aggregate one row per ordered `(src, dst)` pair with its mention count - resolved rows first, then unresolved ones, each ordered by count DESC then names. Caps: 10,000 edges per class and 2,000 ghost nodes (`truncated` says a cap cut the answer). `error` only when the vault or the store cannot be used |
| `vault_link_resolve(vault_path: String, target: String)` | `String` | Static - resolve one `[[target]]` against the vault's note set with the index's own rules (exact case, then a unique case-insensitive match; a `/` names a path; an ambiguous stem is never picked). Answers `{resolved: "sub/note.md", candidates: []}`, or `resolved: null` with the sorted `candidates` for an ambiguous stem, or `resolved: null` with no candidates when nothing matched. The follow path for a mention - including one typed but not yet saved; `error` only when the vault or the store cannot be used |
| `vault_note_read(vault_path: String, rel_path: String)` | `String` | Static - load one note for the editor. JSON: `{text, truncated, crlf, mtime, size}` (the text at the 1 MiB cut, `truncated` when that cut hit a larger file, `crlf` when the file uses CRLF endings, and the stamp a save checks), or `{error, code}`. Only a regular file at a vault-relative `.md` path the walk could have produced is read |
| `vault_note_write(vault_path: String, rel_path: String, content: String, expected_mtime: int, expected_size: int, force: bool)` | `String` | Static - replace an existing note atomically (hidden sibling temp, renamed over the target, keeping the note's own mode) and re-index the vault. The resolved path must stay inside the root (a symlink escaping it is refused, one pointing at a sibling note is written through); the file must exist - this edits, never creates. A stamp different from `expected_mtime`/`expected_size` answers `code: "changed_on_disk"` unless `force` is true. JSON: `{mtime, size, indexed}` - `indexed: false` means saved but not searchable yet - or `{error, code}` |
| `vault_note_create(vault_path: String, rel_path: String, content: String)` | `String` | Static - create one note and re-index the vault. The path follows the save vocabulary and its directory must already exist inside the vault (never created, never through a directory symlinked out); the file is claimed with `create_new`, so an existing note answers `code: "exists"` and nothing is ever replaced. JSON: `{mtime, size, indexed}` or `{error, code}` |
| `vault_note_rename(vault_path: String, rel_path: String, new_rel_path: String)` | `String` | Static - move one note within the vault and re-index it. Both paths follow the vocabulary, the destination's directory must exist inside the vault, and the destination is claimed before the rename (`code: "exists"` instead of an overwrite). The vault **entry** moves: a symlinked note moves as a link, its target untouched. A rename preserves the file's mtime/size, so the caller's stamp stays valid. JSON: `{path, indexed}` or `{error, code}` |
| `vault_link_rewrite_preview(vault_path: String, rel_path: String, new_rel_path: String, include_renamed: bool)` | `String` | Static - what a rename's reference update would touch, writing nothing. `rel_path` is the old name and `new_rel_path` the current one: the pass reads the vault after the move and reconstructs the old note set, so only occurrences that resolved to the old name are considered (an ambiguous stem is not one). `include_renamed` adds the renamed note itself - the pane passes its buffer's cleanliness, because a dirty buffer must never be written under. JSON: `{files, mentions, skipped, truncated}` - notes and occurrences that still name the old target, notes that could not be examined (unreadable or over the read cap), and whether the walk's note cap cut the vault. Answers `{error, code}` for a vault, path or new name that cannot be used - a new name a `[[link]]` cannot spell is `bad_path` |
| `vault_link_rewrite(vault_path: String, rel_path: String, new_rel_path: String, include_renamed: bool)` | `String` | Static - apply the planned reference update and re-index the vault. Only the targets that resolved to the old name are respelled, alias and `#` fragment are preserved, line endings and every other byte stay as they were, and fenced code and code spans are untouched. `include_renamed` makes the renamed note itself a candidate when its buffer is clean; with it, the answer carries `renamed_note: {text, crlf, mtime, size}` - the body that landed and its fresh stamp, for the editor to adopt in place instead of reading the file again. Each write is `vault_note_write`'s, and the pass re-plans and writes in one call, so an edit made while the question was open is read fresh; a note that changes between that plan and its write answers `changed_on_disk` and counts as `skipped`. JSON: `{files, mentions, skipped, truncated, indexed, renamed_note?}` or `{error, code}` |
| `vault_note_delete(vault_path: String, rel_path: String)` | `String` | Static - delete one note and re-index the vault. Only an existing note can be deleted; the operation acts on the vault **entry** (a symlinked note is unlinked, its target untouched). JSON: `{indexed}` or `{error, code}` |
| `vault_scratch_read(vault_path: String, rel_path: String)` | `String` | Static - the recovery copy of one note's unsaved buffer, written by the editor so a crash cannot take it. JSON: `{found: false}` when there is none (the normal state, and the answer for a copy that cannot be trusted) or `{found: true, text, mtime, size}` - the buffer, and the stamp of the file revision it was typed against, so a save restored from it still checks the file the user saw. `error` only when the vault or the note path cannot be used |
| `vault_scratch_write(vault_path: String, rel_path: String, text: String, expected_mtime: int, expected_size: int)` | `String` | Static - snapshot one note's unsaved buffer as its recovery copy. Goes to gpty's own state directory (`state_dir()/scratch`, owner-only) and never to the vault - this is not a note write - and is atomic (hidden random temp, renamed over the previous copy). Each write also prunes the directory: a copy whose own record names a vault that is gone is reclaimed, as is a temp file older than an hour; a vault that cannot be read and a record that cannot be interpreted are left alone. `expected_mtime`/`expected_size` are the stamp the buffer was loaded from, recorded so a restore after the file moved on still asks. JSON: `{ok: true}` or `{error, code}` |
| `vault_scratch_clear(vault_path: String, rel_path: String)` | `String` | Static - drop one note's recovery copy: its buffer either reached the file or was deliberately discarded. An absent copy is not an error. JSON: `{ok: true}` or `{error, code}` |

#### Pane API & status

| Method | Returns | Description |
|--------|---------|-------------|
| `get_plain_text(limit: int)` | `String` | Plain-text snapshot of screen + scrollback, newline-joined, capped 1–2000 lines (backs `paneRead`) |
| `get_status()` | `String` | JSON: `{pid, running, exit_code, exit_reason, idle_ms, agent_state, agent_state_tier}` (backs `paneStatus`). `running` requires a live terminal task *and* no exit code; `exit_reason` is `exited`, `task_ended` (the task died without recording one - a panic, or a child that closed its pty and outlived the pane) or `null` while it runs |
| `search_history(pattern: String, limit: int)` | `String` | JSON `{"results": [[line_num, text], ...]}` - FTS5 search of the pane's persisted scrollback, newest-first (limit 1–500; free text as a user typed it, sanitised into quoted terms, so punctuation such as `main.rs` is searchable) |
| `check_lines(pattern: String)` | `String` | First recent line matching the Rust-regex pattern, or empty (backs `waitForOutput`) |
| `emit_event(json: String)` | void | Static - fan a JSON event out to event-socket subscribers |

#### Grid & rendering

| Method | Returns | Description |
|--------|---------|-------------|
| `get_grid_updates_packed(force_full: bool)` | `Dictionary` | Grid update in packed arrays - see [Grid Update Dictionary](#grid-update-dictionary) |
| `get_grid_generation()` | `int` | Monotonic counter, changes on grid update |
| `get_cursor_row()` | `int` | Cursor row (0-based, -1 if none) |
| `get_cursor_col()` | `int` | Cursor column (0-based) |
| `get_cursor_shape()` | `int` | 0=Block, 1=Underline, 2=Beam |
| `get_title()` | `String` | Terminal window title (OSC) |
| `get_rows()` | `int` | Grid row count |
| `get_cols()` | `int` | Grid column count |

#### Scrollback & search

| Method | Returns | Description |
|--------|---------|-------------|
| `scroll_up(lines: int)` | void | Scroll back in history |
| `scroll_down(lines: int)` | void | Scroll forward in history |
| `scroll_reset()` | void | Reset scroll to follow output |
| `get_scroll_offset()` | `int` | Lines above visible viewport |
| `get_history_size()` | `int` | Total scrollback lines available |
| `search_grid(pattern: String)` | `Dictionary` | Search scrollback for regex pattern |
| `key_to_bytes(keycode, shift, alt, ctrl, meta)` | `PackedByteArray` | Convert key event to terminal byte sequence |

#### Concept engine

| Method | Returns | Description |
|--------|---------|-------------|
| `set_global_concepts(concepts_json: String)` | void | Static - replace all concepts in the engine (JSON array of concept objects with `name`, `trigger`, optional `conditions` regex array, `enabled`, `capture_mode`, and `actions`; parse caps and timeout clamp in `gpty_core::concept::concepts_from_json`) |
| `validate_regex(pattern: String)` | `String` | Static - validate a user-authored regex against the engine's dialect: `""` when accepted, else the error. GDScript's `RegEx` is PCRE2 and accepts look-around the Rust `regex` crate rejects, which `concepts_from_json` silently drops |
| `get_global_concepts()` | `Array` | Static - get all concepts as Dict array (each carries `conditions`, possibly empty) |
| `drain_concept_events()` | `Array` | Drain completed capture events from this terminal |
| `drain_concept_notices()` | `Array` | Drain notify-only concept matches (`capture_mode: "single_line"`); returns `[{concept_name}]`. Metadata only - the matched line is never published |
| `acknowledge_capture(event_id: int)` | void | Discard captured bytes (receiver consumed output) |
| `flush_capture(event_id: int)` | void | Feed captured bytes to grid (no receiver) |

#### IPC bridge (static methods)

| Method | Returns | Description |
|--------|---------|-------------|
| `drain_ipc_requests()` | `Array` | Drain queued **control** IPC requests as `[{id, method, params, timeout_ms}]`. `timeout_ms` is the request's remaining fallback deadline (0 once it has passed); the deferred-answer dialogs arm their expiry timer from it, so a dialog cannot outlive the request that asked for it |
| `respond_ipc(id, success, result_json)` | void | Respond to a drained IPC request |
| `take_shutdown_request()` | `bool` | Whether a client asked the GUI to quit (true once, then false). Polled each frame; the quit runs through the scene tree so `_exit_tree` still saves |
| `take_startup_failure()` | `String` | Why this instance is quitting itself, when it could not serve the pane API (a refusal to replace a live socket or pipe) - empty when the quit came from a client. Taken once, for the toast the GUI shows as it goes |
| `drain_agent_events()` | `String` | Drain bounded OMP extension events (JSON array) from `gpty-events.sock` on Unix or `\\.\pipe\gpty-events` on Windows - see [OMP event socket](#omp-event-socket-reasoning-pane) |

The control server registers `version`/`shutdown` locally, and the vault's `vaultSearch`/`vaultRead` natively in `vault_ipc.rs` (a vault is a directory, not workspace state, and the walk plus SQLite run on the blocking pool instead of the GUI thread); the vault's declared-weight write (`vaultWeight`) is the exception - its store is Godot's `user://link_weights.json`, so it is routed to GDScript like every other stateful method. Every other method (`newPane`, `paneRead`, `paneStatus`, `paneRun`, `paneWait`, `broadcast`, layout, concepts) is listed in `ipc.rs` `gdscript_methods` and routed to GDScript - `workspace.gd` delegates dispatch to `WorkspaceIpcHandlers` (`ipc_handlers.gd`). New pane-API methods must be added to **both** the registration list and the handler module, unless they are directory-scoped like the vault pair.

#### Grid Update Dictionary

`get_grid_updates_packed()` returns one of two shapes. Both carry flat
per-cell arrays: `fg`/`bg` are `PackedColorArray`, `attrs` is
`PackedInt32Array` (bit flags: 1 bold, 2 italic, 4 underline, 8 inverse,
16 wide), and `chars` is an `Array` of strings.

`fg`/`bg` are **paint-ready**: `CellInfo::paint_colors` has already applied
SGR 7 (inverse), so `fg` is always the glyph color and `bg` always the
background. Draw them as they are - do not swap an inverse cell in GDScript.
The `8 inverse` bit stays in `attrs` as cell information, not as a drawing
instruction; swapping only the text color is what painted a bracketed paste
(readline echoes it inside `ESC[7m`) in its own background.

Full update (`is_full = true`, first fetch or `force_full`):
```gdscript
{
    "is_full": true,
    "rows": 24, "cols": 80,          # int - grid dimensions
    "chars": ["line0", "line1", …],  # Array[String] - one string per row
    "fg": PackedColorArray(…),       # len = rows × cols
    "bg": PackedColorArray(…),
    "attrs": PackedInt32Array(…),
}
```

Partial update (`is_full = false`, damaged cells only):
```gdscript
{
    "is_full": false,
    "indices": PackedInt32Array(…),  # cell index = row * cols + col
    "chars": ["A", "B", …],          # Array[String] - one string per cell
    "fg": PackedColorArray(…),
    "bg": PackedColorArray(…),
    "attrs": PackedInt32Array(…),
}
```

## OMP event socket (Reasoning pane)

Passive OMP observability uses a **second** local IPC listener beside the
workspace-control socket: `gpty.sock` → `gpty-events.sock` on Unix,
`\\.\pipe\gpty` → `\\.\pipe\gpty-events` on Windows. Implementation:
`src/omp_events.rs`. Protocol details: `crates/gpty-ipc/README.md`.

| Platform | Control IPC | OMP event socket |
|----------|-------------|------------------|
| Linux / macOS (Unix) | Unix domain socket, `gpty.sock` | Unix domain socket, `gpty-events.sock` - `ompEvent` JSON-RPC |
| Windows | Named pipe, `\\.\pipe\gpty` | Named pipe, `\\.\pipe\gpty-events` - `ompEvent` JSON-RPC |

The listener runs on every platform, and it is started unconditionally: every
PTY spawn calls `ensure_server_started()` and `register_terminal()` - no
`cfg` branch stands between the two - and the shell is given `GPTY_EVENT_*`
when registration succeeds. `@gpty/omp-events` then forwards semantic events
and `workspace.gd` polls `drain_agent_events()` into the Reasoning pane, so
Terminal, Inspector and Reasoning behave the same way on Windows. The
`windows-smoke` job runs the extension inside a real pane there and asserts the
pane reports Tier 1 `working`, which observes the whole chain - env injection,
transport, capability check, translation, drain - on the platform.

The shipped extension needs no platform branch to reach either transport:
`net.connect(path)` opens a Unix socket for a socket path and a named pipe for
a pipe path. The only branch is validation - a Windows path must be a
`\\.\pipe\` name, answered from the path alone because a pipe cannot be
`stat`ed, while on Unix the socket must be owned by this user and inaccessible
to group/other.

The event code carries no `#[cfg(unix)]` gates at all: `omp_events.rs` is
platform-neutral, which is what lets the `rust-windows` job compile this crate
under `RUSTFLAGS: -Dwarnings`.

### Tips

- Use `get_grid_generation()` to skip redundant grid polls when idle
- The renderer uses `get_grid_updates_packed()` to fetch only damaged cells, merging into `_cell_cache`
- If the grid mutex is held by the background task, or no shell has started yet,
  `get_grid_updates_packed()` returns an empty `Dictionary` and `get_rows()` /
  `get_cols()` answer `0`
