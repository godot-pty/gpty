extends SceneTree
## Deterministic UI capture driver for the UI/UX assessment (AGENTS.md).
##
## Stages one named UI state through the real autoloads and the real main
## scene, waits for the pixels to stop changing, and saves the app's own
## rendered viewport as a PNG. This is the committed staging path the audits
## used to rewrite per run: the same state on the same build must come out
## pixel-identical, and `scripts/ui-capture-check` is what proves it.
##
##   scripts/ui-capture <state> <out-dir>          # private sandbox + PNG
##   scripts/ui-capture --list                    # the state names
##   scripts/ui-capture-check                     # determinism + locality test
##
## Raw form (the scripts add the sandbox):
##
##   godot --path godot --disable-vsync -s res://tests/bench/ui_capture.gd -- \
##       --state palette --out /tmp/captures
##
## Flags:
##   --state <name>     the state to stage (required; see STATES)
##   --out <dir>        write <dir>/<state>.png
##   --hold             stage and stay open instead of capturing, so
##                      `scripts/screenshot-gpty --state` can grab the window
##   --ready <path>     write this file once the state is staged and settled
##                      (the desktop grab waits on it; stdout may be buffered)
##   --perturb <name>   shift that one state's topmost overlay (or its first
##                      pane) by 16 px; `scripts/ui-capture-check` uses it to
##                      prove a capture diff is local to one state
##   --audit-focus      stage the state, print what keyboard traversal can
##                      reach (focus owner, every traversal component, the
##                      components/rings/reached totals, focus-none controls)
##                      and exit; `scripts/ui-capture --audit-focus <state>`
##   --audit-accessibility
##                      stage the state, print the accessible surface (names,
##                      descriptions, live modes, recorded values, glyph
##                      buttons with no name) and exit;
##                      `scripts/ui-capture --audit-accessibility <state>`
##   --list             print the state names, one per line, and exit
##   --compare a b      compare two PNGs pixel for pixel and exit 0/1
##
## A real display driver is required: under `--headless` there is no redraw
## pass, `frame_post_draw` never fires, and a script awaiting it hangs.
## `--disable-vsync` keeps a vsync-locked present from blocking on a window
## the compositor never shows.
##
## Determinism, all of it needed:
##   - `GPTY_TEST_USER_DIR` must name an absolute directory (fresh per run):
##     the driver writes through `WorkspaceStore`, and the app binds its
##     control socket at launch. `scripts/ui-capture` owns the whole sandbox
##     (user dir, XDG dirs, HOME, socket); refuse to run without one rather
##     than seed a developer's real profile.
##   - Cursor blink off, so the caret is not mid-blink.
##   - A staged agent-state badge is pinned to its table glyph and its pane's
##     per-frame work is stopped (`_apply_agent_states`): the spinner cycles and
##     the attention pulse are wall-clock driven, so a live badge would never
##     repeat from one run to the next.
##   - The status bar's clock and FPS pinned (`StatusBar.freeze_readouts`);
##     they are the only readouts that move while nothing does.
##   - The capture waits for every terminal grid generation, every pane title
##     and the toast queue to stop changing, then parks the pointer so no
##     hover highlight depends on the desktop's mouse position.
##   - Window size comes from the state table, not the WM: the root viewport
##     is resized and the capture is of that render target, so a desktop that
##     clamps windows cannot change the image.

const DEFAULT_SIZE := Vector2i(1920, 1080)
## Two saved commands, one insert and one run. Shared by the two states that
## show this feature's surfaces: the Commands tab and the palette section.
const COMMAND_FIXTURE := [
	{"name": "Build", "command": "cargo build --workspace", "run": false},
	{"name": "Test", "command": "cargo test --workspace", "run": true},
]
## Pane count before the state's interaction runs. 0 leaves the workspace
## store empty: a first launch now has no workspace and no pane, and the guide
## is the whole view (the first pane creates the "Default" workspace).
const STATES := {
	"first-launch": {"size": DEFAULT_SIZE, "panes": 0},
	"sidebar": {"size": DEFAULT_SIZE, "panes": 4},
	"settings": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings"},
	"pane-settings": {"size": DEFAULT_SIZE, "panes": 1, "open": "pane-settings"},
	# The workspace-directory picker: the app's own header over the engine's
	# picker column (row *A FileDialog still wears Godot's stock grey frame*).
	"file-dialog": {"size": DEFAULT_SIZE, "panes": 1, "open": "file-dialog"},
	"palette": {"size": DEFAULT_SIZE, "panes": 1, "open": "palette"},
	"empty-workspace": {"size": DEFAULT_SIZE, "panes": 1, "close_all": true},
	# The empty guide at the layout floor: the atlas must scroll inside the empty
	# surface instead of clipping. A zero-pane first launch is the store state
	# here; the close-all path is covered by `empty-workspace` at 1920x1080,
	# where the sidebar's trash is inside the synthetic click's reach.
	"empty-workspace-560x340": {"size": Vector2i(560, 340), "panes": 0},
	# The pane inset and the code viewer's empty state, side by side: four panes
	# that each have nothing to show (row *Pane chrome: distinct icons, a compact
	# action menu, padding and consistent empty states*). The measurement is the
	# gap between each pane's first line and its tile's 1 px border on all four
	# sides.
	"pane-empty-states": {"size": Vector2i(1280, 760), "tiles": [
		{"col": 0, "row": 0, "cspan": 30, "rspan": 30,
			"settings": {"type": "code_viewer", "attachment_id": "capture-empty-code"}},
		{"col": 30, "row": 0, "cspan": 30, "rspan": 30,
			"settings": {"type": "cli_view", "attachment_id": "capture-empty-cli"}},
		{"col": 0, "row": 30, "cspan": 30, "rspan": 30,
			"settings": {"type": "reasoning", "attachment_id": "capture-empty-reasoning"}},
		{"col": 30, "row": 30, "cspan": 30, "rspan": 30,
			"settings": {"type": "inspector", "attachment_id": "capture-empty-inspector"}},
	]},
	# The File Tree's two "cannot be listed" states, side by side: it used to
	# render an empty list for both (row *The File Tree shows an empty list when
	# its root cannot be listed, and says nothing*).
	"file-tree-missing-root": {"size": Vector2i(1280, 520), "tiles": [
		{"col": 0, "row": 0, "cspan": 30, "rspan": 60,
			"settings": {"type": "file_tree", "attachment_id": "capture-tree-unset",
				"root_path": ""}},
		{"col": 30, "row": 0, "cspan": 30, "rspan": 60,
			"settings": {"type": "file_tree", "attachment_id": "capture-tree-missing",
				"root_path": "/gpty-capture-missing-root"}},
	]},
	# The size a fresh pane's child is born at: the program prints the PTY's
	# own dimensions, so the image and the grid agree. Row *A fresh pane's
	# child starts at 80x24 and only learns its real size 50 ms later*.
	"pane-spawn-size": {"size": Vector2i(1280, 760), "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "attachment_id": "capture-spawn-size",
				"shell_args": ["-c", 'set -- $(stty size); echo "born at $1 rows, $2 cols"; sleep 600']}},
	]},
	# The scrollback-return affordance: the pane is scrolled back so the
	# floating chevron draws (row *A scrolled-back pane returns to live output
	# in one click*).
	"scrollback-return": {"size": Vector2i(1280, 760), "open": "scrollback-return", "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "attachment_id": "capture-scrollback",
				"shell_args": ["-c", "seq 1 300; sleep 600"]}},
	]},
	# The scrollbar column: the Terminal tab overflows its 540x560 card by
	# 62 px, so its ScrollContainer must show a real bar with a thumb inside a
	# track (row *Every scrollable surface has a 0 px scrollbar*). The 150 %
	# twin proves the same geometry under the window's content scale - the
	# column is layout pixels, so it scales with the rest of the chrome.
	"settings-terminal": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings", "tab": "Terminal"},
	"settings-terminal-150": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings", "tab": "Terminal",
		"ui_scale": 150},
	# The UI scale setting at its 125 % step, on the app's own first-launch
	# workspace. The only visual proof that the setting scales the chrome and
	# the terminal text together; a later release recaptures it.
	"ui-scale-125": {"size": DEFAULT_SIZE, "panes": 0, "ui_scale": 125},
	# The same 125 % request in a small window. It used to be refused - a
	# 640x400 layout under the 540x560 Settings card forced 100 % - and since the
	# small-window work the surfaces clamp to the window, so 640x400 is above the
	# 560x340 floor and the request is honoured. The harness prints both numbers,
	# so the log and the image agree about which scale produced it.
	"ui-scale-125-800x500": {"size": Vector2i(800, 500), "panes": 0, "ui_scale": 125},
	# The light chrome, on the same workspace the dark states capture. Both
	# exist so the light theme is reproducible by name, and so the v0.8.5
	# recapture can use them instead of a scratch driver.
	"light-workspace": {"size": Vector2i(1280, 760), "panes": 4,
		"settings": {"cfg_appearance_mode": 1}},
	"light-settings": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings", "tab": "Appearance",
		"settings": {"cfg_appearance_mode": 1}},
	# The search strip at the pane's top edge with a match count and the two
	# step controls. Filler output comes first so the strip's two rows do not
	# hide the matches themselves; three `alpha` lines then sit in view
	# (`-c` means no echoed command line, so the count is exactly three).
	# Row *Search, toasts and appearance swatches*.
	"search": {"size": Vector2i(1280, 760), "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "attachment_id": "capture-search",
				"shell_args": ["-c",
					'for i in 1 2 3 4 5 6 7 8; do echo "output line $i"; done; '
					+ 'printf "alpha one\\nalpha two\\nbeta three\\nalpha four\\n"; sleep 600']}},
	], "open": "search", "query": "alpha"},
	# The same strip in its History scope: FTS5 hits from this pane's own stored
	# scrollback, the scope reached with a real click on the toggle, and the
	# keyboard cursor on the first hit (Down). Row *The history search results
	# are mouse-only*.
	"search-history": {"size": Vector2i(1280, 760), "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "terminal", "attachment_id": "capture-search-history",
				"shell_args": ["-c",
					'for i in 1 2 3 4 5 6 7 8; do echo "output line $i"; done; '
					+ 'printf "alpha one\\nalpha two\\nbeta three\\nalpha four\\n"; sleep 600']}},
	], "open": "search-history", "query": "alpha"},
	"workspace-1280x760": {"size": Vector2i(1280, 760), "panes": 4},
	# The window's own title bar: `apply_mode` hides it in the default decorated
	# mode, so without this state neither the focus audit nor an image can see
	# the three controls at all.
	"window-chrome-borderless": {"size": DEFAULT_SIZE, "panes": 1,
		"settings": {"cfg_window_mode": 1}},
	# The two view panes' own toolbars. `pane-empty-states` seeds both empty,
	# where the toolbars are hidden, so these two states carry real content -
	# the audit cannot see a control that is not on screen.
	"code-viewer-content": {"size": DEFAULT_SIZE, "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "code_viewer", "attachment_id": "capture-code-content",
				"file_path": VIEWER_FIXTURE, "view_mode": "rendered"}}]},
	"cli-view-content": {"size": DEFAULT_SIZE, "tiles": [
		{"col": 0, "row": 0, "cspan": 60, "rspan": 60,
			"settings": {"type": "cli_view", "attachment_id": "capture-cli-content",
				"command": "/bin/sh", "shell_args": ["-c", "printf 'ready\\n'"]}}]},
	# The small-window row. Four tiles named with titles wider than their own
	# tile, so a title that ran under its three controls would show here: the
	# OSC title is set by the child itself, which is the one part of the title
	# this capture can make independent of the developer's shell.
	"window-800x500": {"size": Vector2i(800, 500), "tiles": [
		{"col": 0, "row": 0, "cspan": 30, "rspan": 30, "settings": {
			"type": "terminal", "attachment_id": "capture-small-1",
			"shell_args": ["-c", "printf '\\033]0;%s\\007' 'cachyos: ~/Projects/godot-pty/gpty'; sleep 600"]}},
		{"col": 30, "row": 0, "cspan": 30, "rspan": 30, "settings": {
			"type": "terminal", "attachment_id": "capture-small-2",
			"shell_args": ["-c", "printf '\\033]0;%s\\007' 'a second title long enough to overrun'; sleep 600"]}},
		{"col": 0, "row": 30, "cspan": 30, "rspan": 30, "settings": {
			"type": "terminal", "attachment_id": "capture-small-3",
			"shell_args": ["-c", "printf '\\033]0;%s\\007' 'vim ~/Projects/godot-pty/gpty/AGENTS.md'; sleep 600"]}},
		{"col": 30, "row": 30, "cspan": 30, "rspan": 30, "settings": {
			"type": "terminal", "attachment_id": "capture-small-4",
			"shell_args": ["-c", "printf '\\033]0;%s\\007' 'cargo test --workspace'; sleep 600"]}},
	]},
	"window-560x340": {"size": Vector2i(560, 340), "panes": 4},
	# The adapt-or-clip row's own surface: the Settings card in a small window,
	# with a pane behind it so the card, a title and the sidebar share a frame.
	"settings-800x500": {"size": Vector2i(800, 500), "panes": 1, "open": "settings"},
	"settings-560x340": {"size": Vector2i(560, 340), "panes": 1, "open": "settings"},
	# The surfaces the October 2026 audit did not reach. Each seeds the real
	# content the surface needs (the bundled vault, a wiki tile, an untrusted
	# spawn plan) instead of a mock, so the capture shows the shipped UI.
	"wiki-vault": {"size": DEFAULT_SIZE, "tiles": [WIKI_TILE]},
	"wiki-graph": {"size": DEFAULT_SIZE, "tiles": [WIKI_TILE], "open": "wiki-graph"},
	"concept-editor": {"size": DEFAULT_SIZE, "panes": 1, "open": "concept-editor"},
	# The divider grab band: a 12 px handle centred on the line between two
	# panes, highlighted on hover (row *Resizing a pane is smooth*). The pointer
	# is left on the band, so this state must not be parked.
	"resize-hover": {"size": DEFAULT_SIZE, "tiles": RESIZE_TILES,
		"open": "resize-hover", "keep_pointer": true},
	# The same divider mid-drag, button still down: the grown pane's text has
	# reflowed and the margin beside it is the terminal's own background.
	"resize-drag": {"size": DEFAULT_SIZE, "tiles": RESIZE_TILES,
		"open": "resize-drag", "keep_pointer": true},
	# The Commands tab with two seeded commands: the list, the Insert/Run hint
	# each row carries, and the seven-tab bar that has to hold it. The entries
	# are written through the store's own API, so the image cannot show a state
	# the app cannot reach.
	"commands": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings", "tab": "Commands",
		"commands": COMMAND_FIXTURE},
	# The same commands in the palette, filtered to their own words: the section
	# heading, the Insert/Run hints and the row order are the half of this
	# feature the Settings tab cannot show, and the unfiltered list would put
	# them below the fold.
	"palette-commands": {"size": DEFAULT_SIZE, "panes": 1, "open": "palette",
		"query": "saved", "commands": COMMAND_FIXTURE},
	# The Settings > About keyboard-shortcut table (row *Discoverability: pane
	# names, shortcuts and the window-mode control*).
	"shortcuts": {"size": DEFAULT_SIZE, "panes": 1, "open": "settings", "tab": "About"},
	# The sidebar's section Help popup: the Add Pane glyph table, opened through
	# the section's own Help button (same row).
	"pane-help": {"size": DEFAULT_SIZE, "panes": 1, "open": "help"},
	"plugin-review": {"size": DEFAULT_SIZE, "panes": 1, "open": "plugin-review"},
	# The Save Profile form, whose command fields are the measured clipping
	# defect (69 px against `/bin/bash`'s 75). Two panes, so the form shows
	# the field widths it is judged on.
	"save-profile": {"size": DEFAULT_SIZE, "panes": 2, "open": "save-profile"},
	# `approve_seeded_plans: false`: the Workspace Trust dialog is this state's
	# subject, so its plan must stay unapproved - see the staging block.
	"workspace-trust": {"size": DEFAULT_SIZE, "tiles": [UNTRUSTED_TILE], "open": "workspace-trust",
		"approve_seeded_plans": false},
	# The running-work confirm at 800x500, the size where the card used to grow
	# past the window and put "Close anyway" below the bottom edge (row *A dialog
	# can grow past the window it opens in*). Four panes, each given a foreground
	# command through the real input path (a `-c` child runs in the shell's own
	# process group, which the foreground-job test correctly reads as no job), and
	# the close goes through the real action, so `_ask_running_then` builds the
	# card: the list of names it wraps is what made it tall.
	"running-work": {"size": Vector2i(800, 500), "open": "running-work", "tiles": [
		{"col": 0, "row": 0, "cspan": 30, "rspan": 30,
			"settings": {"type": "terminal", "attachment_id": "capture-work-1"}},
		{"col": 30, "row": 0, "cspan": 30, "rspan": 30,
			"settings": {"type": "terminal", "attachment_id": "capture-work-2"}},
		{"col": 0, "row": 30, "cspan": 30, "rspan": 30,
			"settings": {"type": "terminal", "attachment_id": "capture-work-3"}},
		{"col": 30, "row": 30, "cspan": 30, "rspan": 30,
			"settings": {"type": "terminal", "attachment_id": "capture-work-4"}},
	]},
	# The four visible agent states side by side. The point of the state is the
	# glyph: `failed` (an X-circle) and `needs-attention` (a warning triangle)
	# differ in shape, so the distinction survives a protan/deutan view, a
	# monochrome screenshot and a greyscale print - red versus amber does not.
	"agent-badges": {
		"size": Vector2i(1280, 420),
		"agent_states": ["working", "completed", "failed", "needs-attention"],
		"tiles": [
			{"col": 0, "row": 0, "cspan": 15, "rspan": 60,
				"settings": {"type": "terminal", "attachment_id": "capture-badge-working"}},
			{"col": 15, "row": 0, "cspan": 15, "rspan": 60,
				"settings": {"type": "terminal", "attachment_id": "capture-badge-completed"}},
			{"col": 30, "row": 0, "cspan": 15, "rspan": 60,
				"settings": {"type": "terminal", "attachment_id": "capture-badge-failed"}},
			{"col": 45, "row": 0, "cspan": 15, "rspan": 60,
				"settings": {"type": "terminal", "attachment_id": "capture-badge-attention"}},
		],
	},
}
## Two side-by-side terminals with one divider between them: the resize states
## only need one line to grab, and each pane prints a line so the drag capture
## shows text in the grown pane rather than an empty prompt. `sleep 600` keeps
## the shells alive while the capture settles.
const RESIZE_TILES := [
	{"col": 0, "row": 0, "cspan": 30, "rspan": 60,
		"settings": {"type": "terminal", "attachment_id": "capture-resize-left",
			"shell_args": ["-c", "printf 'left pane\\n'; sleep 600"]}},
	{"col": 30, "row": 0, "cspan": 30, "rspan": 60,
		"settings": {"type": "terminal", "attachment_id": "capture-resize-right",
			"shell_args": ["-c", "printf 'right pane\\n'; sleep 600"]}},
]
## The bundled wiki is a real vault (notes on disk, indexed by the Rust side),
## so the Wiki and link-graph states need no fixture of their own.
const WIKI_TILE := {
	"col": 0, "row": 0, "cspan": 60, "rspan": 60,
	"settings": {
		"type": "wiki", "attachment_id": "capture-wiki",
		"vault_path": "@knowledge", "view_mode": "split",
		"open_note": "index.md",
	},
}
## A saved tile whose program differs from the configured default: the restore
## gate must ask before it spawns anything. The dialog is the surface; the
## tile is never restored in a capture.
const UNTRUSTED_TILE := {
	"col": 0, "row": 0, "cspan": 60, "rspan": 60,
	"settings": {
		"type": "terminal", "attachment_id": "capture-untrusted",
		"pane_name": "Untrusted Terminal", "command": "/bin/sh",
	},
}
## A Markdown fixture written into the sandbox before the scene exists. A const
## state cannot compute a path and `TextRead` refuses a `res://` scheme, so a
## tile names this token and `_seed_workspace` substitutes the written path.
const VIEWER_FIXTURE := "@viewer-fixture"
## How long a signature must stay unchanged before the state counts as settled.
const SETTLE_MS := 250
## Upper bound on waiting for a state to settle, so a stuck pane fails the run
## instead of hanging it.
const SETTLE_TIMEOUT_MS := 20000
## Upper bound on draining the toast queue (the longest toast lasts 8 s).
const TOAST_TIMEOUT_MS := 15000

var _workspace: Control = null
## Autoloads are not compile-time identifiers for a `-s` script (measured:
## `Identifier not found: SettingsManager`), so they are resolved as nodes.
var _settings: Node = null
var _store: Node = null


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	if args.has("error"):
		_fail(str(args["error"]))
		return
	if args.get("list", false):
		for state_name in STATES:
			print(state_name)
		quit(0)
		return
	if args.has("compare"):
		var pair: Array = args["compare"]
		quit(_compare(str(pair[0]), str(pair[1])))
		return

	var state_name := str(args.get("state", ""))
	if not STATES.has(state_name):
		_fail("--state %s is not a known state; --list prints them" % state_name)
		return
	var sandbox := OS.get_environment("GPTY_TEST_USER_DIR")
	if not BasePersistenceManager.is_real_absolute_path(sandbox):
		_fail(
			"GPTY_TEST_USER_DIR must name an absolute directory (got %s). "
			% sandbox
			+ "Run scripts/ui-capture, which owns the private sandbox; staging "
			+ "writes through WorkspaceStore and the app binds its control socket.")
		return
	if not args.has("out") and not args.get("hold", false) \
			and not args.get("audit_focus", false) and not args.get("audit_accessibility", false):
		_fail("--out <dir> is required unless --hold, --audit-focus or --audit-accessibility is given")
		return

	await _run(state_name, STATES[state_name], args)


func _run(state_name: String, state: Dictionary, args: Dictionary) -> void:
	var size: Vector2i = state["size"]
	# In-memory settings only: the sandbox already keeps the stores private,
	# and a capture may not rewrite the settings file it is capturing.
	_settings = root.get_node("SettingsManager")
	_store = root.get_node("WorkspaceStore")
	_settings.cfg_cursor_blink = false
	_settings.cfg_show_titlebar = true
	_settings.cfg_window_size = size
	_settings.cfg_check_updates = false
	# Before the scene exists: the workspace lays itself out against the
	# window's content scale on its first frame, so a scale applied later
	# would be a second layout rather than the one captured.
	_settings.cfg_ui_scale = int(state.get("ui_scale", 100))
	# A state may set any SettingsManager field through `settings`. The
	# appearance mode has to land before the scene exists, for the same reason
	# as the UI scale: the workspace builds its Theme on its first frame.
	for key in state.get("settings", {}):
		_settings.set(str(key), state["settings"][key])
	_settings.apply_ui_scale()
	_settings.apply_appearance()
	_seed_workspace(state)

	_workspace = load("res://scenes/main.tscn").instantiate()
	root.add_child(_workspace)
	await _settle_window(size)
	# The scale the window actually got. `ui-scale-125-800x500` exists to prove
	# the cap, and only a number can say which scale the image shows.
	print("ui_capture: window=%dx%d ui_scale requested=%d%% applied=%d%%" % [
		size.x, size.y, _settings.cfg_ui_scale,
		_settings.applied_ui_scale_percent()])
	# A seeded layout restores its panes unfocused; pin the active pane so the
	# status bar and the sidebar accent cannot depend on restore order. The
	# first-launch state keeps the app's own focus — that behaviour is audited.
	if int(state.get("panes", 0)) > 0 or not state.get("tiles", []).is_empty():
		var bodies: Array = _workspace._pane_bodies(_workspace._active_workspace())
		if not bodies.is_empty():
			_workspace.activate_pane(bodies[0])
	await _settle()
	if not await _apply_state(state_name, state):
		return
	_pin_empty_guide()

	if args.get("perturb", "") == state_name:
		_perturb(state_name)

	await _wait_toasts()
	await _settle()
	_workspace._status_bar.freeze_readouts()
	# Freeze last, then settle again: the pinned readout must not be the last
	# thing to change the pixels.
	await _settle()
	# A hover is the subject of `resize-hover`: parking the pointer would erase
	# exactly the state being captured.
	if not state.get("keep_pointer", false):
		_park_pointer()

	if args.get("audit_focus", false):
		# The keyboard half of the audit: this surface's reachability, printed
		# instead of captured. Same staged state, same sandbox.
		await _audit_focus(state_name)
		quit(0)
		return

	if args.get("audit_accessibility", false):
		# The accessible half of the audit: what a screen reader is offered by
		# this surface, printed instead of captured. Same staged state.
		await _audit_accessibility(state_name)
		quit(0)
		return

	if args.get("hold", false):
		_write_ready(str(args.get("ready", "")), state_name, size)
		print("ui_capture: ready state=%s size=%dx%d" % [state_name, size.x, size.y])
		while true:
			await process_frame
		return

	await _capture(state_name, str(args.get("out", "")))
	quit(0)

## The empty guide animates on a wall clock (the keycap press and ripple); pin
## it to the first frame and stop its clock so two runs of the same state are
## pixel-identical. The same rule `_apply_agent_states` applies to AgentBadge.
func _pin_empty_guide() -> void:
	if _workspace._shortcut_guide != null and _workspace._empty_state.visible:
		_workspace._shortcut_guide.pin_animation()


# ── Seeding ────────────────────────────────────────────────────────────

## Write the state's panes through the real store, exactly as a restore would
## find them. Tile settings go through `PaneTypes.sanitize_tile` at restore,
## so a state definition that drifts from the schema fails visibly instead of
## silently spawning something else.
func _seed_workspace(state: Dictionary) -> void:
	if state.has("commands"):
		# The real store API, in the order the state lists: the tab, the palette
		# and a later recapture all read the same file.
		var commands: Node = root.get_node("SavedCommandStore")
		for entry in state["commands"]:
			commands.add(str(entry.get("name", "")), str(entry.get("command", "")),
				bool(entry.get("run", false)))
	var tiles: Array = []
	if state.has("tiles"):
		# A surface state names its exact tiles: the pane type and the settings
		# the real restore path sanitizes (a wiki's vault, an untrusted plan).
		tiles = state["tiles"]
	else:
		var panes := int(state.get("panes", 0))
		if panes <= 0:
			return
		var grid := PaneTypes.GRID
		if panes == 1:
			tiles.append(_tile(1, 0, 0, grid, grid))
		else:
			var half := grid / 2
			var index := 1
			for row in 2:
				for col in 2:
					tiles.append(_tile(index, col * half, row * half, half, half))
					index += 1
	if tiles.is_empty():
		return
	# A tile that names the Markdown fixture gets the path it was just written
	# to; the copy keeps the const state free of a path that depends on the
	# sandbox.
	var resolved: Array = []
	for tile in tiles:
		var copy: Dictionary = (tile as Dictionary).duplicate(true)
		var tile_settings: Dictionary = copy.get("settings", {})
		if str(tile_settings.get("file_path", "")) == VIEWER_FIXTURE:
			tile_settings["file_path"] = _write_viewer_fixture()
			copy["settings"] = tile_settings
		resolved.append(copy)
	# A saved layout carries its panes' public ids; naming them here keeps the
	# Pane Settings capture free of a random `pane-…` handle.
	var workspaces: Array[Dictionary] = [
		{"name": "Workspace 1", "cwd": "", "layout": resolved},
	]
	_store.save(0, workspaces)
	# A state may seed a tile that starts something other than the default
	# shell (this one prints its own PTY size). The restore gate asks before
	# spawning such a tile, and a trust dialog is not the state being captured,
	# so the plans this state itself seeds are recorded as approved under a
	# capture-owned name.
	#
	# `"approve_seeded_plans": false` opts a state out, because for the
	# workspace-trust state the dialog *is* the capture: approving its plan
	# first is exactly what silenced it (measured on the 0.8.0+ tree - the
	# state asked for the "the untrusted tile did not raise the Workspace Trust
	# dialog" failure on every run, including a pristine `git archive HEAD`
	# checkout, because this block approved the very plan the state exists to
	# have reviewed).
	if state.get("approve_seeded_plans", true) == true:
		var plans: Array = []
		for td in tiles:
			if td is Dictionary:
				var key := PaneTypes.tile_plan_key(td)
				if key != "":
					plans.append(key)
		if not plans.is_empty():
			var trusted: Node = root.get_node("TrustedStore")
			trusted.approve_builtin("ui-capture", GptyTerminal.get_app_version(), plans)

func _tile(index: int, col: int, row: int, cspan: int, rspan: int) -> Dictionary:
	return {
		"col": col, "row": row, "cspan": cspan, "rspan": rspan,
		"settings": {"type": "terminal", "attachment_id": "capture-%d" % index},
	}

## The `VIEWER_FIXTURE` tile's document, written before the scene exists so the
## viewer restores its file the way a saved layout would. Returns the absolute
## path `TextRead` accepts (a `res://` path is refused by design).
func _write_viewer_fixture() -> String:
	var path := "user://ui-capture-viewer.md"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("ui_capture: cannot write %s" % path)
		return ProjectSettings.globalize_path(path)
	f.store_string(
		"# Capture fixture\n\n"
		+ "A short Markdown document, so the viewer's toolbar sits over real "
		+ "content.\n\n"
		+ "| Column | Value |\n|---|---|\n| one | 1 |\n| two | 2 |\n")
	f.close()
	return ProjectSettings.globalize_path(path)

## `_chrome.restore_position()` runs deferred at launch and re-applies the
## saved window size through `DisplayServer`, which does not resize the root
## render target on every display server. The root viewport is the authority:
## set it, then wait until it reads back.
func _settle_window(size: Vector2i) -> void:
	for _i in 120:
		if Vector2i(root.size) == size:
			return
		await process_frame
	root.size = size
	for _i in 120:
		if Vector2i(root.size) == size:
			await process_frame
			return
		await process_frame
	_fail("window did not reach %dx%d (root viewport is %s)" % [size.x, size.y, root.size])


# ── The state's interaction ────────────────────────────────────────────

func _apply_state(state_name: String, state: Dictionary) -> bool:
	if state.has("agent_states"):
		if not await _apply_agent_states(state["agent_states"]):
			return false
	match str(state.get("open", "")):
		"settings":
			# At a 340 px window the sidebar's column overflows, so the button
			# must be scrolled into the column before a real click can land on it.
			var settings_btn := _button_with_label(_workspace._sidebar, "Settings")
			var stack: ScrollContainer = _workspace._sidebar._content_scroll
			if stack != null and settings_btn != null:
				stack.ensure_control_visible(settings_btn)
				await _wait_frames(2)
			await _click(settings_btn)
			await _wait_frames(3)
			if _workspace._settings_panel == null or not _workspace._settings_panel.visible:
				_fail("clicking Settings did not open the Settings panel")
				return false
			# `"tab": "<name>"` opens the panel on that tab instead of System.
			# The Appearance tab is where the release's own controls live (the
			# appearance mode and the UI scale), so a capture of the theme that
			# cannot show them would be a picture of a card.
			if state.has("tab"):
				var tab_title := str(state["tab"])
				var tab_body: Node = _workspace._settings_panel.find_child(tab_title, true, false)
				if tab_body == null:
					_fail("the Settings panel has no '%s' tab" % tab_title)
					return false
				var tab_container := tab_body.get_parent() as TabContainer
				if tab_container == null:
					_fail("the '%s' tab is not inside a TabContainer" % tab_title)
					return false
				tab_container.current_tab = tab_container.get_tab_idx_from_control(tab_body as Control)
				await _wait_frames(2)
		"file-dialog":
			var more_button := _button_with_accessible_name(_workspace._sidebar,
				"More workspace actions")
			if more_button == null:
				_fail("the sidebar has no workspace More button")
				return false
			await _click(more_button)
			await _wait_frames(2)
			var menu := _workspace.find_child("WorkspaceActionsMenu", true, false) as PopupMenu
			if menu == null:
				_fail("clicking the workspace More button did not open its menu")
				return false
			# Set Directory is item 1 (Rename Workspace is item 0); emitting the
			# press is what a click on the item sends (the modal dialogs use the
			# same seam).
			menu.index_pressed.emit(1)
			await _wait_frames(3)
			var picker := _visible_dialog(_workspace) as FileDialog
			if picker == null:
				_fail("the workspace menu's Set Directory did not open a picker")
				return false
			# A fixed directory: the picker opens in the sandbox's HOME, whose
			# per-run path made two captures differ in the path field. The root
			# listing is the same on both runs of one machine.
			picker.current_dir = "/"
			await _wait_frames(3)
		"help":
			var help_btn := _button_with_accessible_name(_workspace._sidebar, SectionHelp.NAME)
			if help_btn == null:
				_fail("the sidebar's Add Pane header has no Help button")
				return false
			await _click(help_btn)
			await _wait_frames(3)
			# The popup is parented to the sidebar's background rect (the sidebar
			# clips its content), so that is where the table lives.
			if _workspace._sidebar_bg.find_child(SectionHelp.TABLE_NAME, true, false) == null:
				_fail("clicking Help did not open the glyph table")
				return false
		"pane-settings":
			var wrapper: Control = _workspace._tm.tiles[0].wrapper
			var button := _button_with_tooltip(wrapper, "Pane settings")
			if button == null:
				_fail("the first pane has no Pane settings button")
				return false
			await _click(button)
			await _wait_frames(3)
			var panel: Control = _workspace._tm._pane_settings_panel
			if panel == null or not panel.visible:
				_fail("clicking Pane settings did not open the panel")
				return false
		"palette":
			await _press_key(KEY_P, true, true)
			await _wait_frames(3)
			if _workspace._palette == null or not _workspace._palette.visible:
				_fail("Ctrl+Shift+P did not open the command palette")
				return false
			# `"query": "<text>"` filters the list the way typing does, so a state
			# can show a section at the bottom of a long list without capturing
			# the list's top instead.
			if state.has("query"):
				var field: LineEdit = _workspace._palette._field
				field.text = str(state["query"])
				field.text_changed.emit(field.text)
				await _wait_frames(3)
		"search":
			var opened_live: bool = await _open_search(state_name, state, false)
			if not opened_live:
				return false
		"search-history":
			var opened_history: bool = await _open_search(state_name, state, true)
			if not opened_history:
				return false
		"wiki-graph":
			var wiki: Control = _workspace._tm.tiles[0].wrapper
			var list: ItemList = wiki.find_child("NoteList", true, false) as ItemList
			if list == null or list.item_count == 0:
				_fail("the bundled vault produced no notes for the wiki pane")
				return false
			var graph_button := _button_with_label(wiki, "Graph")
			if graph_button == null:
				_fail("the wiki pane has no Graph button")
				return false
			await _click(graph_button)
			await _wait_frames(3)
			var graph: Node = _find_script(wiki, "res://scenes/ui/vault_graph_view.gd")
			if graph == null or not (graph as Control).visible:
				_fail("clicking Graph did not show the link graph")
				return false
		"concept-editor":
			await _click(_button_with_label(_workspace._sidebar, "Settings"))
			await _wait_frames(3)
			var panel: Control = _workspace._settings_panel
			if panel == null or not panel.visible:
				_fail("clicking Settings did not open the Settings panel")
				return false
			var tab_scroll: Node = panel.find_child("Concepts", true, false)
			if tab_scroll == null:
				_fail("the Settings panel has no Concepts tab")
				return false
			var tabs := tab_scroll.get_parent() as TabContainer
			if tabs == null:
				_fail("the Concepts tab is not inside a TabContainer")
				return false
			tabs.current_tab = tabs.get_tab_idx_from_control(tab_scroll as Control)
			await _wait_frames(2)
			var editor_button := _button_with_label(panel, "Open Visual Editor")
			if editor_button == null:
				_fail("the Concepts tab has no Open Visual Editor button")
				return false
			await _click(editor_button)
			await _wait_frames(3)
			if _workspace._concept_graph == null or not _workspace._concept_graph.visible:
				_fail("Open Visual Editor did not open the concept graph")
				return false
		"resize-hover":
			var band: Control = _divider_band()
			if band == null:
				return false
			await _send_motion(root.get_final_transform() * _band_center(band))
			await _wait_frames(3)
			var layer: DividerHandles = _workspace._grid.get_node("DividerHandles")
			if layer._hovered != 0:
				_fail("the pointer did not land on the divider handle")
				return false
		"resize-drag":
			var band: Control = _divider_band()
			if band == null:
				return false
			var at: Vector2 = root.get_final_transform() * _band_center(band)
			await _send_motion(at)
			await _send_button(at, true)
			await _send_motion(at + Vector2(60, 0))
			await _settle()
			if not _workspace._tm.drag_active():
				_fail("the press on the divider did not start a drag")
				return false
		"save-profile":
			var save_btn := _workspace._sidebar.find_child("SaveProfileBtn", true, false) as Button
			if save_btn == null:
				_fail("the sidebar has no save-profile button")
				return false
			await _click(save_btn)
			await _wait_frames(3)
			if _dialog_titled(_workspace, "Save Profile") == null:
				_fail("the save-profile dialog did not open")
				return false
		"plugin-review":
			# There is no in-app install button: the CLI sends the summary and
			# this is the handler's own seam (the IPC dispatch lands here). The
			# dialog is the surface; nothing is installed in a capture.
			_workspace._show_plugin_review(1, _plugin_review_params(), 60000)
			await _wait_frames(3)
			if _dialog_titled(_workspace, "Plugin Install Review") == null:
				_fail("the plugin install review did not open")
				return false
		"workspace-trust":
			# The restore gate asks before it builds anything, so the dialog is
			# the whole state. Missing means the untrusted tile never tripped it.
			if _dialog_titled(_workspace, "Workspace Trust") == null:
				_fail("the untrusted tile did not raise the Workspace Trust dialog")
				return false
		"running-work":
			# The reported path: several busy panes in one workspace and the
			# workspace closed, so the card carries the intro and one line per
			# pane - the longest text the app wraps in a dialog.
			var work_bodies: Array = _workspace._pane_bodies(_workspace._active_workspace())
			if work_bodies.size() < 4:
				_fail("the running-work state needs four panes (got %d)" % work_bodies.size())
				return false
			# The child starts on the first layout pass, and `send_line` before
			# that would be buffered, not run: wait for the engine handle.
			var child_deadline := Time.get_ticks_msec() + 5000
			while Time.get_ticks_msec() < child_deadline:
				if work_bodies.all(func(b): return b._terminal != null):
					break
				await process_frame
			for b in work_bodies:
				if b._terminal == null:
					_fail("a capture pane never started its child")
					return false
				b._terminal.send_line("sleep 600")
			# `has_running_work` reads the engine's status sample, refreshed by
			# its own 200 ms child poll, and job control promotes the command to
			# the foreground group only once the shell has started it.
			var deadline := Time.get_ticks_msec() + 5000
			while Time.get_ticks_msec() < deadline:
				if work_bodies.all(func(b): return b.has_running_work()):
					break
				await process_frame
			if not work_bodies.all(func(b): return b.has_running_work()):
				var seen := []
				for b in work_bodies:
					seen.append(str(b._terminal.get_status()) if b._terminal != null else "no child")
				_fail("the capture panes never reported a foreground job: %s" % str(seen))
				return false
			# A workspace close needs a second workspace to exist, and the ask
			# is the workspace-scoped one (it qualifies every pane line only
			# through the intro, which is the wrap under test).
			_workspace._add_workspace()
			await _wait_frames(2)
			_workspace._close_workspace(0)
			await _wait_frames(4)
			if _dialog_titled(_workspace, "Stop running processes?") == null:
				_fail("closing a workspace of busy panes did not raise the running-work confirm")
				return false
		"scrollback-return":
			var scroll_body = _workspace._tm._find_body(_workspace._tm.tiles[0].wrapper)
			if not _is_terminal(scroll_body) or scroll_body._terminal == null:
				_fail("the scrollback-return state needs a terminal pane")
				return false
			# The wheel is measured against a fixed amount of output: wait for
			# it to finish, or a line arriving after the scroll would move the
			# offset this image is about.
			var filled := false
			var last_history := -1
			var quiet := 0
			for _i in 200:
				var size_now: int = scroll_body._terminal.get_history_size()
				if size_now > 40:
					filled = true
					# The wheel is measured against the whole program's fixed
					# output: stop once the history has stopped growing, or a
					# line arriving between the scroll and the frame would move
					# the offset this image is about.
					if size_now == last_history:
						quiet += 1
						if quiet >= 5:
							break
					else:
						quiet = 0
				last_history = size_now
				await process_frame
			if not filled:
				_fail("the capture pane never produced scrollback (history %d)"
					% scroll_body._terminal.get_history_size())
				return false
			await _send_wheel(scroll_body, MOUSE_BUTTON_WHEEL_UP, 5)
			await _wait_frames(4)
			var up_visible: bool = scroll_body._scroll_hints.top_button.visible
			var down_visible: bool = scroll_body._scroll_hints.bottom_button.visible
			if scroll_body._terminal.get_scroll_offset() <= 0 \
					or not down_visible or not up_visible:
				_fail("the chevrons did not both show (offset %d, up %s, down %s)" % [
					scroll_body._terminal.get_scroll_offset(), up_visible, down_visible])
				return false
	if state.get("close_all", false):
		# The panes title row's trash opens the inline check/cross; its check
		# is what asks about running work. A live shell counts as running work,
		# so the modal appears and is its own OS window: press its OK button's
		# signal, which is what a click on it emits.
		await _click(_button_with_accessible_name(
			_workspace._sidebar, "Close all panes in this workspace"))
		await _wait_frames(2)
		await _click(_button_with_accessible_name(
			_workspace._sidebar, "Confirm closing all panes"))
		await _wait_frames(2)
		var dialog := _workspace.get_node_or_null("RunningWorkConfirm")
		if dialog != null:
			dialog.get_ok_button().pressed.emit()
		await _wait_frames(4)
		if not _workspace._tm.tiles.is_empty():
			_fail("the panes title row's close-all left %d panes"
				% _workspace._tm.tiles.size())
			return false
	return true

## Put each pane into its named agent state through the real Tier 1 entry point
## (the same `set_agent_state` the capability event socket calls), wait for the
## badge to paint it, then freeze the badge's clock.
##
## The freeze is what makes the image repeat: the badge owns the animation (the
## `working` ring turns its notch, `needs-attention` pulses its alpha, both from
## wall-clock time), so two runs of the same state would differ. Re-applying the
## state pins the badge's phase to 0 - the frame a user sees when the badge
## appears - and stopping the badge's own per-frame work keeps it from moving
## that frame again. Stopping the pane alone no longer does this.
func _apply_agent_states(states: Array) -> bool:
	var tiles: Array = _workspace._tm.tiles
	if tiles.size() < states.size():
		_fail("this state needs %d panes, the restore built %d" % [states.size(), tiles.size()])
		return false
	var bodies: Array = []
	for i in states.size():
		var body = _workspace._tm._find_body(tiles[i].wrapper)
		if not _is_terminal(body) or body._terminal == null:
			_fail("pane %d is not a terminal" % i)
			return false
		body._terminal.set_agent_state(str(states[i]))
		bodies.append(body)
	var deadline := Time.get_ticks_msec() + 5000
	var painted := false
	while Time.get_ticks_msec() < deadline and not painted:
		await process_frame
		painted = true
		for i in states.size():
			var badge: AgentBadge = tiles[i].wrapper.get_node_or_null("BodyVBox/TitleBar/StateBadge")
			# The state is what is painted; the tooltip alone would not prove
			# which silhouette is on the tile.
			if badge == null or not badge.visible or badge.state() != str(states[i]):
				painted = false
	if not painted:
		_fail("the badges did not paint their declared states within 5 s")
		return false
	for i in states.size():
		# The pane polls its terminal on a tick, so the badge on screen now is
		# the polled one. `_apply_badge` pins the badge's phase to 0; the badge
		# also stops its own frame work, because it animates on its own clock
		# and stopping the pane no longer stops it.
		var badge: AgentBadge = tiles[i].wrapper.get_node_or_null("BodyVBox/TitleBar/StateBadge")
		bodies[i]._apply_badge(str(states[i]))
		if badge != null:
			badge.set_process(false)
		bodies[i].set_process(false)
	return true

## Shift the one control that only this state shows, so a diff is attributable.
func _perturb(state_name: String) -> void:
	var target: Control = null
	if _workspace._settings_panel != null and _workspace._settings_panel.visible:
		target = _workspace._settings_panel
	elif _workspace._tm._pane_settings_panel != null and _workspace._tm._pane_settings_panel.visible:
		target = _workspace._tm._pane_settings_panel
	elif _workspace._palette != null and _workspace._palette.visible:
		target = _workspace._palette
	elif not _workspace._tm.tiles.is_empty():
		target = _workspace._tm.tiles[0].wrapper
	if target != null:
		target.offset_left += 16.0
		print("ui_capture: perturbed %s by 16 px" % target.name)
	else:
		_fail("state '%s' has no overlay or pane to perturb" % state_name)


# ── Input ──────────────────────────────────────────────────────────────

func _click(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		_fail("cannot click an invalid control")
		return
	# `Input.parse_input_event` takes window coordinates while a Control's global
	# rect is in viewport (layout) coordinates. At a content scale other than
	# 100 % the two differ - measured 2026-11-08: the `settings-terminal-150`
	# state's click on the sidebar's Settings landed 2/3 of the way to its target
	# and the panel never opened, because the views are 1280x720 layout space in
	# a 1920x1080 window. The viewport's final transform is the one mapping
	# between them (identity at 100 %, so every 100 % capture is unchanged).
	var pos := root.get_final_transform() * control.get_global_rect().get_center()
	await _send_motion(pos)
	await _send_button(pos, true)
	await process_frame
	await _send_button(pos, false)
	await process_frame

func _send_motion(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame

func _send_button(pos: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = pos
	event.global_position = pos
	Input.parse_input_event(event)
	await process_frame

## Scroll a control with the wheel the way a pointer does: the same
## window-coordinate mapping as `_click`, one notch per press.
func _send_wheel(control: Control, button: MouseButton, times: int) -> void:
	if control == null or not is_instance_valid(control):
		_fail("cannot scroll an invalid control")
		return
	var pos := root.get_final_transform() * control.get_global_rect().get_center()
	for _i in times:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = true
		event.factor = 1.0
		event.position = pos
		event.global_position = pos
		Input.parse_input_event(event)
		await process_frame

func _press_key(keycode: Key, ctrl := false, shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	down.pressed = true
	Input.parse_input_event(down)
	await process_frame
	var up: InputEventKey = down.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	await process_frame

## Leave the pointer somewhere inert: a hover highlight must not depend on
## where the desktop happened to leave the mouse before the run.
func _park_pointer() -> void:
	await _send_motion(Vector2(root.size) - Vector2(4, 4))
	await _wait_frames(2)

## The first divider band a resize state grabs, or null after failing the run.
func _divider_band() -> Control:
	var layer: DividerHandles = _workspace._grid.get_node_or_null("DividerHandles")
	if layer == null or layer._pool.is_empty():
		_fail("the workspace grid has no divider handle")
		return null
	return layer._pool[0]

## A band's centre in the workspace viewport's coordinates.
func _band_center(band: Control) -> Vector2:
	return band.global_position + band.size * 0.5

func _button_with_label(node: Node, text: String) -> Button:
	if node is Button and _has_label(node, text):
		return node as Button
	for child in node.get_children():
		var found := _button_with_label(child, text)
		if found != null:
			return found
	return null

## An icon-only button has no text to match (its glyph is a child Label), so a
## state that clicks one names it the way a screen reader does.
func _button_with_accessible_name(node: Node, accessible_name: String) -> Button:
	if node is Button and (node as Button).accessibility_name == accessible_name:
		return node as Button
	for child in node.get_children():
		var found := _button_with_accessible_name(child, accessible_name)
		if found != null:
			return found
	return null


func _has_label(node: Node, text: String) -> bool:
	if node is Label and (node as Label).text == text:
		return true
	# A plain Button draws its own text (the sidebar's action buttons carry
	# Label children instead), so both spellings name the same control.
	if node is Button and (node as Button).text == text:
		return true
	for child in node.get_children():
		if _has_label(child, text):
			return true
	return false

func _button_with_tooltip(node: Node, tip: String) -> Button:
	if node is Button and (node as Button).tooltip_text == tip:
		return node as Button
	for child in node.get_children():
		var found := _button_with_tooltip(child, tip)
		if found != null:
			return found
	return null

func _wait_frames(count: int) -> void:
	for _i in count:
		await process_frame


# ── Settling ───────────────────────────────────────────────────────────

## Everything that can still change without user input: terminal grid
## generations, pane titles (the shell's OSC title lands after the prompt) and
## the status bar's left label.
func _settle() -> void:
	var last := "?"
	var changed_at := Time.get_ticks_msec()
	var deadline := changed_at + SETTLE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var signature := _ui_signature()
		if signature != last:
			last = signature
			changed_at = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - changed_at >= SETTLE_MS:
			return
	_fail("the UI did not settle within %d ms (last signature %s)" % [SETTLE_TIMEOUT_MS, last])

func _ui_signature() -> String:
	var parts := PackedStringArray()
	for tile in _workspace._tm.tiles:
		var body = _workspace._tm._find_body(tile.wrapper)
		var generation := -1
		if _is_terminal(body) and body._terminal != null:
			generation = body._terminal.get_grid_generation()
		var title := ""
		var label = tile.wrapper.get_node_or_null("BodyVBox/TitleBar/TitleLabel")
		if label is Label:
			title = (label as Label).text
		parts.append("%d/%s" % [generation, title])
	return "|".join(parts)

## The toast queue drains on its own timers; a spawn or restore notice left
## on screen would otherwise land in whichever capture raced it.
func _wait_toasts() -> void:
	var overlay: Node = _find_script(_workspace, "res://scenes/ui/toast_overlay.gd")
	if overlay == null:
		return
	var deadline := Time.get_ticks_msec() + TOAST_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if overlay.get_child_count() == 0 and not overlay._active:
			await process_frame
			return
	_fail("toasts did not clear within %d ms" % TOAST_TIMEOUT_MS)

## The visible dialog with this window title. A ConfirmationDialog is an
## embedded subwindow, so it is in the captured viewport but is not part of
## the Control tree a button lookup walks.
func _dialog_titled(node: Node, title: String) -> AcceptDialog:
	if node is AcceptDialog:
		var dialog := node as AcceptDialog
		if dialog.title == title and dialog.visible:
			return dialog
	for child in node.get_children():
		var found := _dialog_titled(child, title)
		if found != null:
			return found
	return null

## The summary `gpty plugin install` sends for its review. It is display data
## only (the dialog is the surface under audit); the fields exercise every
## section the builder can render.
func _plugin_review_params() -> Dictionary:
	return {
		"id": "example/omp-events",
		"name": "OMP Events",
		"version": "0.2.0",
		"revision": "6a1f0c9e3b7d",
		"requested_ref": "v0.2.0",
		"source": "github.com/example/omp-events",
		"actions": [
			{"name": "start", "command": "new-pane", "args": {"type": "terminal"}},
			{"name": "inspect", "command": "pane-read", "args": {"pane": "omp"}},
		],
		"events": [{"name": "turns", "type": "agent.*"}],
		"link_handlers": [{"scheme": "omp", "command": ["omp", "--open"]}],
		"build": ["npm", "install"],
		"startup": ["node", "dist/index.js"],
		"concepts": [
			{"name": "Test failures", "enabled": true, "targets": ["reasoning"]},
			{"name": "Build errors", "enabled": false, "notify_only": true},
		],
		"profiles": [
			{"name": "OMP Workspace", "tiles": 3, "programs": ["omp"], "plans": ["omp"]},
			{"name": "OMP", "tiles": 1, "programs": ["omp"], "plans": ["omp"]},
		],
	}

## Find a node by its script path. `is <Class>` would compile the script (and
## its autoload identifiers) into this one; see `_is_terminal`.
func _find_script(node: Node, path: String) -> Node:
	var script = node.get_script()
	if script != null and script.resource_path == path:
		return node
	for child in node.get_children():
		var found := _find_script(child, path)
		if found != null:
			return found
	return null

## A terminal body without naming the class: `is TerminalPane` would pull
## `terminal_pane.gd` into this script's compile, and that script reads the
## `PaneEnvStore` autoload by name — which is not an identifier yet when a
## `-s` script is first compiled (measured: `Identifier not found`).
func _is_terminal(body) -> bool:
	return body != null and is_instance_valid(body) and "_terminal" in body


# ── Keyboard reachability ──────────────────────────────────────────────

## Print what keyboard traversal reaches in the staged state: who owns focus,
## which visible controls are focusable, which interactive controls are
## FOCUS_NONE (mouse-only), and every traversal component — the first as
## `tab-order`, the rest as `ring[n]` (closed) or `flow[n]` (runs into a claimed
## control), plus the totals. A mouse-only control is declared with
## `KeyboardFocus.declare_mouse_only` when its action has a keyboard path
## elsewhere (the palette's rows, the search strip's step buttons); the report
## prints that reason and counts only the undeclared ones as `unaccounted`. An
## open overlay is snapshotted before the Escape that closes it, or its own rows
## would be counted as zero.
func _audit_focus(state_name: String) -> void:
	print("focus-audit: state=%s" % state_name)
	var owner: Control = _workspace.get_viewport().gui_get_focus_owner()
	print("focus-audit: focus-owner=%s" % ("<none>" if owner == null else _short_path(owner)))
	# An embedded dialog is its own viewport, so its focus is not the root
	# viewport's. Report both; otherwise "the dialog took focus" is unverifiable.
	var dialog := _visible_dialog(_workspace)
	if dialog != null:
		var dialog_owner: Control = dialog.get_viewport().gui_get_focus_owner()
		print("focus-audit: dialog=%s focus-owner=%s"
			% [dialog.title, "<none>" if dialog_owner == null else _short_path(dialog_owner)])
	# Does Escape close the surface the state opened? The overlay's own
	# mouse-only controls have to be snapshotted *before* it: a dialog
	# queue-frees itself and the palette hides, so a count taken afterwards is
	# blind to exactly the surface the state staged (the palette's rows were
	# reported as `focus-none-buttons=0`).
	var overlay = _visible_overlay(dialog)
	var mouse_only: Array[Dictionary] = []
	if overlay != null:
		mouse_only.append_array(_mouse_only_entries(overlay, "overlay"))
		var overlay_name := str(overlay.name)
		await _press_key(KEY_ESCAPE)
		await _wait_frames(3)
		# A canceled dialog queue_frees itself, so validity is part of "closed".
		var closed: bool = not is_instance_valid(overlay) or not overlay.visible
		print("focus-audit: escape overlay=%s closed=%s" % [overlay_name, closed])
	var controls := _all_controls(_workspace)
	var focusable: Array[Control] = []
	var canvases: Array[Control] = []
	for c in controls:
		if not c.is_visible_in_tree():
			continue
		if c.focus_mode != Control.FOCUS_NONE:
			focusable.append(c)
			continue
		if c is BaseButton:
			continue
		elif c.get_script() != null and (c.get_script() as Script).resource_path == "res://scenes/ui/vault_graph_view.gd":
			canvases.append(c)
	# The workspace's own mouse-only buttons, after the escape. A control that is
	# still visible was already snapshotted from the overlay walk.
	var seen := {}
	for entry in mouse_only:
		seen[entry["path"]] = true
	for entry in _mouse_only_entries(_workspace, "workspace"):
		if not seen.has(entry["path"]):
			mouse_only.append(entry)
	var declared := 0
	for entry in mouse_only:
		if str(entry["reason"]) != "":
			declared += 1
			print("focus-audit: mouse-only button scope=%s text=%s tooltip=%s reason=%s path=%s"
				% [entry["scope"], entry["text"], entry["tooltip"], entry["reason"], entry["path"]])
		else:
			print("focus-audit: unaccounted button scope=%s text=%s tooltip=%s path=%s"
				% [entry["scope"], entry["text"], entry["tooltip"], entry["path"]])
	print("focus-audit: controls=%d focusable=%d focus-none-buttons=%d declared=%d unaccounted=%d"
		% [controls.size(), focusable.size(), mouse_only.size(), declared, mouse_only.size() - declared])
	for canvas in canvases:
		print("focus-audit: mouse-only canvas path=%s" % _short_path(canvas))
	# Every component, not just the one ring a single start sits inside: a
	# `focus_next` ring caps a walk, so walking from one control reported 5 of
	# this state's 178 controls. The focus owner goes first, so `tab-order` is
	# still the component the keyboard starts in.
	var ordered: Array[Control] = []
	if owner != null and is_instance_valid(owner) and owner.is_visible_in_tree():
		ordered.append(owner)
	for c in focusable:
		if c.is_visible_in_tree() and not ordered.has(c):
			ordered.append(c)
	var components := KeyboardFocus.tab_components(ordered)
	var reached := 0
	var rings := 0
	for index in components.size():
		var component: Array = components[index]["controls"]
		var closed: bool = components[index]["closed"]
		reached += component.size()
		if closed:
			rings += 1
		var paths: Array[String] = []
		for c in component:
			paths.append(_short_path(c))
		var key := "tab-order"
		if index > 0:
			key = "ring[%d]" % index if closed else "flow[%d]" % index
		print("focus-audit: %s=%s" % [key, ", ".join(paths)])
	print("focus-audit: components=%d rings=%d reached=%d"
		% [components.size(), rings, reached])

## Print the accessible surface the staged state exposes: every Control that
## carries a name, a description, a live mode or a recorded value, the count of
## live regions, and every glyph-only button that would be announced as its
## private-use codepoint instead of a word.
##
## A driver is not needed for this half — the editor build has none, so
## `A11y.screen_reader()` is false and no value reaches an element server; the
## recorded value meta is what this reads. The exposed tree itself is
## `scripts/accessibility-probe`'s job, against a rebuilt export.
func _audit_accessibility(state_name: String) -> void:
	print("a11y-audit: state=%s" % state_name)
	print("a11y-audit: support=%s driver=%s screen-reader-active=%d" % [
		str(ProjectSettings.get_setting("accessibility/general/accessibility_support")),
		str(ProjectSettings.get_setting("accessibility/general/accessibility_driver")),
		DisplayServer.accessibility_screen_reader_active()])
	var controls := _all_controls(_workspace)
	var live_regions := 0
	var glyph_buttons := 0
	var unnamed := 0
	for c in controls:
		if not c.is_visible_in_tree():
			continue
		var name_text: String = c.accessibility_name
		var desc: String = c.accessibility_description
		var live: int = c.accessibility_live
		var value := str(c.get_meta(A11y.VALUE_META, ""))
		if name_text != "" or desc != "" or live != 0 or value != "":
			var line := "a11y-audit: %s name=%s desc=%s live=%d" % [
				c.get_class(), name_text, desc, live]
			if value != "":
				line += " value=%s" % value.left(80).replace("\n", "\\n")
			line += " path=%s" % _short_path(c)
			print(line)
		if live != 0:
			live_regions += 1
		if c is BaseButton:
			var glyph := _button_glyph(c as BaseButton)
			if glyph != "":
				glyph_buttons += 1
				if name_text == "" or name_text == glyph:
					unnamed += 1
					print("a11y-audit: unnamed-glyph text=%s tooltip=%s path=%s"
						% [glyph, (c as BaseButton).tooltip_text, _short_path(c)])
	print("a11y-audit: controls=%d live-regions=%d glyph-buttons=%d unnamed=%d"
		% [controls.size(), live_regions, glyph_buttons, unnamed])


## The private-use glyph a button renders: its own text, or a child Label's
## (the window controls paint the codepoint into a Label). "" for a text button.
func _button_glyph(button: BaseButton) -> String:
	if _is_glyph(button.text):
		return button.text
	for child in button.get_children():
		if child is Label and _is_glyph((child as Label).text):
			return (child as Label).text
	return ""


static func _is_glyph(text: String) -> bool:
	if text.length() != 1:
		return false
	var c := text.unicode_at(0)
	return c >= 0xE000 and c <= 0xF8FF


## Open the search strip through the pane's own chord and type the state's query
## the way a keystroke does. The History scope is reached with a real click on
## the strip's toggle; its results need the pane's scrollback committed (the
## writer flushes on its own interval), so the commit is asked for and then
## waited for rather than assumed.
func _open_search(state_name: String, state: Dictionary, history_scope: bool) -> bool:
	var body = _workspace._tm._find_body(_workspace._tm.tiles[0].wrapper)
	if not _is_terminal(body):
		_fail("the %s state's first tile is not a terminal" % state_name)
		return false
	# The child's output has to reach the grid before the search runs, or the
	# image would show 0/0 for a pane that does match.
	for _i in 300:
		if "alpha four" in str(body._terminal.get_plain_text(200)):
			break
		await process_frame
	# The pane answers `term:search` from its own `_gui_input`, so it has to own
	# the keyboard: `grab_focus()` (not a click) is what the harness can do
	# without depending on where the grid's centre lands.
	body.grab_focus()
	await _press_key(KEY_F, true, true)
	await _wait_frames(3)
	if not body._search_visible:
		_fail("Ctrl+Shift+F did not open the search strip")
		return false
	if history_scope:
		await _click(body._scope_btn)
		await _wait_frames(3)
		if not body._scope_history:
			_fail("clicking the scope toggle did not switch to the History scope")
			return false
		body._terminal.flush_history()
		var committed: bool = await _wait_for_history(body)
		if not committed:
			return false
	body._search_bar.text = str(state.get("query", ""))
	body._search_bar.text_changed.emit(body._search_bar.text)
	await _wait_frames(2)
	if history_scope:
		if body._history_results.is_empty():
			_fail("the History search returned no rows for '%s'"
				% str(state.get("query", "")))
			return false
		# One Down puts the cursor on the first hit, so the capture shows the
		# selected treatment instead of an empty list.
		await _press_key(KEY_DOWN)
	else:
		# One Enter selects the first match past the view, so the capture shows
		# `1/3` and the active highlight instead of `0/3`.
		await _press_key(KEY_ENTER)
	await _wait_frames(3)
	return true

## The scrollback writer commits on its own interval (200 ms), and a search can
## miss output still queued; `flush_history` asks for the commit, this waits for
## it to be visible to the store.
func _wait_for_history(body) -> bool:
	for _i in 300:
		var parsed = JSON.parse_string(str(body._terminal.search_history("alpha", 1)))
		if parsed is Dictionary and int(parsed.get("stored_lines", 0)) > 0:
			return true
		await process_frame
	_fail("the pane's scrollback never reached the history store")
	return false

## The topmost visible dialog the state opened, if any.
func _visible_dialog(node: Node) -> AcceptDialog:
	if node is AcceptDialog and (node as AcceptDialog).visible:
		return node as AcceptDialog
	for child in node.get_children():
		var found := _visible_dialog(child)
		if found != null:
			return found
	return null

## The overlay the rest of the state opened (dialog, concept editor, settings,
## pane settings or palette), or null for an ordinary workspace.
func _visible_overlay(dialog: AcceptDialog):
	if dialog != null:
		return dialog
	for candidate in [
		_workspace._concept_graph,
		_workspace._settings_panel,
		_workspace._tm._pane_settings_panel,
		_workspace._palette,
	]:
		if candidate is CanvasItem and (candidate as CanvasItem).visible:
			return candidate
	return null

func _all_controls(node: Node) -> Array[Control]:
	var out: Array[Control] = []
	if node is Control:
		out.append(node as Control)
	for child in node.get_children():
		out.append_array(_all_controls(child))
	return out

## The visible, enabled `FOCUS_NONE` buttons under `node`, as report lines. Every
## field is snapshotted as text: the audit must be able to name a control inside
## an overlay after the Escape that closes it has queue-freed it.
func _mouse_only_entries(node: Node, scope: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c in _all_controls(node):
		if not c.is_visible_in_tree():
			continue
		if c.focus_mode != Control.FOCUS_NONE or not (c is BaseButton):
			continue
		var button := c as BaseButton
		if button.disabled:
			continue
		out.append({
			"scope": scope,
			"text": button.text,
			"tooltip": button.tooltip_text,
			"reason": KeyboardFocus.mouse_only_reason(button),
			"path": _short_path(button),
		})
	return out

func _short_path(node: Node) -> String:
	return str(_workspace.get_path_to(node))


# ── Capture ────────────────────────────────────────────────────────────

func _capture(state_name: String, out_dir: String) -> void:
	var focused: Control = _workspace._tm.last_body
	if _is_terminal(focused):
		focused._cursor_visible = true
		focused.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	if image == null:
		_fail("the root viewport produced no image (a display driver is required)")
		return
	if not out_dir.is_absolute_path():
		_fail("--out must be an absolute directory (got %s)" % out_dir)
		return
	var err := DirAccess.make_dir_recursive_absolute(out_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		_fail("cannot create %s (error %d)" % [out_dir, err])
		return
	var path := out_dir.path_join("%s.png" % state_name)
	err = image.save_png(path)
	if err != OK:
		_fail("cannot write %s (error %d)" % [path, err])
		return
	print("ui_capture: wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])

func _write_ready(path: String, state_name: String, size: Vector2i) -> void:
	if path == "":
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write ready file %s" % path)
		return
	file.store_line("state=%s size=%dx%d" % [state_name, size.x, size.y])
	file.close()


# ── PNG comparison (scripts/ui-capture-check) ──────────────────────────

func _compare(a: String, b: String) -> int:
	var left: Image = Image.load_from_file(a)
	var right: Image = Image.load_from_file(b)
	if left == null or right == null:
		printerr("ui_capture: cannot load %s" % (a if left == null else b))
		return 2
	if left.get_size() != right.get_size():
		print("ui_capture: differ sizes %s=%s %s=%s" % [a, left.get_size(), b, right.get_size()])
		return 1
	var ldata := left.get_data()
	var rdata := right.get_data()
	if ldata == rdata:
		print("ui_capture: identical %s %s" % [a, b])
		return 0
	var width := left.get_width()
	var channels := maxi(ldata.size() / maxi(width * left.get_height(), 1), 1)
	var pixels := 0
	var first := Vector2i(-1, -1)
	var last := Vector2i.ZERO
	for i in ldata.size():
		if ldata[i] == rdata[i]:
			continue
		var pixel := i / channels
		var point := Vector2i(pixel % width, pixel / width)
		if pixels == 0:
			first = point
		last = point
		pixels += 1
	print("ui_capture: differ %s %s pixels=%d first=%s last=%s"
		% [a, b, pixels, first, last])
	return 1


# ── Usage ──────────────────────────────────────────────────────────────

func _parse_args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		match raw[i]:
			"--state":
				i += 1
				if i >= raw.size():
					return {"error": "--state needs a value"}
				out["state"] = raw[i]
			"--out":
				i += 1
				if i >= raw.size():
					return {"error": "--out needs a value"}
				out["out"] = raw[i]
			"--ready":
				i += 1
				if i >= raw.size():
					return {"error": "--ready needs a value"}
				out["ready"] = raw[i]
			"--perturb":
				i += 1
				if i >= raw.size():
					return {"error": "--perturb needs a state name"}
				out["perturb"] = raw[i]
			"--hold":
				out["hold"] = true
			"--audit-focus":
				out["audit_focus"] = true
			"--audit-accessibility":
				out["audit_accessibility"] = true
			"--list":
				out["list"] = true
			"--compare":
				if i + 2 >= raw.size():
					return {"error": "--compare needs two image paths"}
				out["compare"] = [raw[i + 1], raw[i + 2]]
				i += 2
			_:
				return {"error": "unknown argument %s" % raw[i]}
		i += 1
	return out

func _fail(message: String) -> void:
	printerr("ui_capture: " + message)
	quit(2)
