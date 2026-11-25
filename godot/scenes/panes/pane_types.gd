class_name PaneTypes
# Registry of all pane types. Maps _pane_type() discriminator strings
# to display metadata. Consumers access PaneTypes.ALL directly.

static var ALL: Dictionary = {
	"terminal":    {"name": "Terminal",    "icon": ">_", "menu_icon": "\uE47E", "shortcut": "Ctrl+Shift+N", "label_prefix": "T"},
	"code_viewer": {"name": "Code Viewer", "icon": "{}", "menu_icon": "\uE914", "shortcut": "Ctrl+Shift+D", "label_prefix": "C", "receives_content": true},
	"file_tree":   {"name": "File Tree",   "icon": "/>", "menu_icon": "\uE25A", "shortcut": "Ctrl+Shift+T", "label_prefix": "F"},
	"inspector":   {"name": "Inspector",   "icon": "@",  "menu_icon": "\uE0AC", "shortcut": "Ctrl+Shift+O", "label_prefix": "I", "receives_content": true},
	"reasoning":   {"name": "Reasoning",   "icon": "?",  "menu_icon": "\uE74E", "shortcut": "", "label_prefix": "R"},
	"cli_view":    {"name": "CLI View",    "icon": "$_", "menu_icon": "\uE1C4", "shortcut": "", "label_prefix": "V"},
	"wiki":        {"name": "Wiki",        "icon": "[]", "menu_icon": "\uE0E6", "shortcut": "", "label_prefix": "W"},
	"media":       {"name": "Media",       "icon": "|>", "menu_icon": "\uE792", "shortcut": "", "label_prefix": "M"},
}

## Pane types whose body accepts a routed concept capture
## (`can_receive_content`). Single source of truth for the concept graph's
## action target picker — adding a receiver pane means flipping this flag
## beside the implementation, not editing a second list.
static func content_receivers() -> Array[String]:
	var out: Array[String] = []
	for key in ALL:
		if ALL[key].get("receives_content", false) == true:
			out.append(key)
	return out

## Clamp a layout value to [lo, hi]. Non-numeric values yield `lo`.
static func clamp_grid_int(v, lo: int, hi: int) -> int:
	if not (v is int or v is float):
		return lo
	return clampi(int(v), lo, hi)

## Ceiling for a stored pane grid. Mirrors the FFI clamp in
## `crates/gpty-gdext/src/lib.rs` (MAX_ROWS/MAX_COLS): several times the
## largest grid a real window produces, and far below anything that would
## allocate an unusable amount of memory for a saved tile.
const PANE_MAX_ROWS := 500
const PANE_MAX_COLS := 2000

## Caps for the Workspace Trust dialog: value length and total detail lines
## across the dialog. The content is file-supplied.
const TRUST_MAX_VALUE_LEN := 160
const TRUST_MAX_DETAIL_LINES := 24

## What an untrusted tile would run, one labelled fact per line, for the
## Workspace Trust dialog. Empty when the tile matches the caller's defaults.
##
## Consent is only informed if the user sees the program and arguments being
## approved — the summary sentence alone said "a different program" without
## saying which. Environment is deliberately absent: a file cannot supply env
## (restore strips `shell_env` with a notice; per-pane env is the user's own
## `PaneEnvStore`, written by the pane settings UI), so there is nothing to
## show. This is attacker-controlled file content rendered into a dialog, so
## it is escaped and capped.
##
## A launch tile is shown as the runner the spawn will use and the line
## verbatim: those are the two facts a user consents to, and the plan key keeps
## the line whole.
static func untrusted_plan(td: Dictionary, default_program: String) -> PackedStringArray:
	var out := PackedStringArray()
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return out
	var launch := sanitize_launch(settings.get("launch", ""))
	if launch != "":
		out.append("program: " + _trust_text(default_program))
		out.append("launch: " + _trust_text(launch))
		return out
	var program := tile_program(td, default_program)
	if program != "" and program != default_program:
		out.append("program: " + _trust_text(program))
	var args = settings.get("shell_args", [])
	if args is Array and not args.is_empty():
		var rendered: Array[String] = []
		for a in args:
			if a is String:
				rendered.append(_trust_text(a))
		if not rendered.is_empty():
			out.append("arguments: " + ", ".join(rendered))
	return out

## Escape a value for display in the trust dialog. Newlines are the dangerous
## case (they would forge an extra dialog line); the rest keeps a hostile value
## readable rather than invisible.
static func _trust_text(text: String) -> String:
	var escaped := (
		text.replace("\\", "\\\\")
			.replace("\n", "\\n")
			.replace("\r", "\\r")
			.replace("\t", "\\t")
			.replace("\u001b", "\\e")
	)
	if escaped.length() > TRUST_MAX_VALUE_LEN:
		escaped = escaped.left(TRUST_MAX_VALUE_LEN) + "…"
	return escaped

## True when a saved tile would spawn something other than the caller's
## defaults: a different program, or extra arguments. Both change what runs,
## so a restore gate must look at both — a `shell`-only check missed a tile
## that shipped `command` or an argv payload (`shell_args: ["-c", "…"]`).
## Environment is not a file decision: restore strips a tile's `shell_env`
## with a notice and never lets it reach a child, so there is no env clause
## here to trigger. A launch line always counts: it is a shell command line,
## whatever the default program is.
static func tile_spawns_untrusted(td: Dictionary, default_program: String) -> bool:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return false
	if tile_launch_line(td) != "":
		return true
	var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	if program != "" and program != default_program:
		return true
	var args = settings.get("shell_args", [])
	if args is Array and not args.is_empty():
		return true
	return false

## The canonical identity of what a tile would run: program + argv joined
## with U+001F, plus the workspace directory the spawn will start in when
## `cwd` is non-empty. The consent store (TrustedStore) keys approvals on
## this, so a trust approval covers the exact spawn plan — the same
## derivation the gate above uses (`command` > `shell` > tile's legacy
## `shell`, plus `shell_args`), kept adjacent so the two can never drift.
## Empty when the tile names nothing to run.
##
## The directory joins the identity only where the plan is already untrusted:
## an approval for "run `omp update && exec omp` in /srv/repo" must not be
## repointed at another directory by editing a workspace file, while a plain
## shell in a file-supplied directory needs no approval (a directory is not
## executable, and asking at every launch would train the user to dismiss the
## one dialog). It is joined with U+001E rather than the content separator
## because `WorkspaceStore.sanitize_cwd` refuses control bytes: the last
## U+001E in a key always opens the directory, so an argv that ends in an
## absolute path cannot be mistaken for the directory.
static func tile_plan_key(td: Dictionary, cwd: String = "") -> String:
	var key := LAUNCH_KEY_MARK + tile_launch_line(td)
	if key == LAUNCH_KEY_MARK:
		# No launch line: the program + argv form, unchanged.
		var settings = td.get("settings", {})
		if not (settings is Dictionary):
			return ""
		var program := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
		var parts: Array[String] = []
		if program != "":
			parts.append(program)
		var args = settings.get("shell_args", [])
		if args is Array:
			for a in args:
				if a is String:
					parts.append(a)
		if parts.is_empty():
			return ""
		key = "\u001f".join(parts)
	if cwd != "":
		key += "\u001e" + cwd
	return key

## Validate a saved tile dictionary from layout.json / profiles.
## Returns {} when the tile is unusable; otherwise a dictionary with
## sanitized `settings`, `type_name`, and clamped grid geometry.
## Layout grid, in abstract units: a pane's geometry is `col/row/cspan/rspan`
## in these units, and this is the ONLY definition — `TerminalManager`'s drag
## math, `workspace.gd`'s `_apply_layout`, and the sanitizer below all read it.
## A second copy once drifted from its twin and silently clamped every restored
## pane to a sliver (the layout divided by one unit while the tiles were in
## another), so nothing else may define its own.
const GRID := 60
## Smallest pane, in grid units (a tenth of the grid ≈ 100 px at 1000 px).
const MIN_TILE := 6
## The grid unit every layout written before the 60-unit refinement uses. A
## saved layout declares the unit it was written in (see `sanitize_grid_unit`)
## so a coarser store still restores to the same shares.
const GRID_LEGACY := 12

## `raw` as a grid unit this build can scale: `GRID` or `GRID_LEGACY`.
## Anything else is 0 — "unknown" — and `TerminalManager.scale_layout` infers
## the unit from the tiles' own extents instead. A store is user-editable, so a
## declared unit is data, not a fact: a unit this build does not know must not
## reach the scale factor unchecked.
static func sanitize_grid_unit(raw) -> int:
	if raw is int or raw is float:
		var unit := int(raw)
		if unit == GRID or unit == GRID_LEGACY:
			return unit
	return 0

static func sanitize_tile(td, grid_size: int = GRID) -> Dictionary:
	if not (td is Dictionary):
		return {}
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return {}
	settings = migrate_pane_settings(settings)
	var type_name = settings.get("type", "terminal")
	if not (type_name is String) or not ALL.has(type_name):
		return {}
	# A file's settings go through the closed per-type table: unknown keys,
	# wrong-typed values and app-only keys (env, scheme paths) are dropped and
	# reported, instead of reaching `PaneBody.apply_settings`'s property path.
	# The spawn keys are preserved verbatim for `_restore_into`, which validates
	# them itself (the trust gate + sanitize_shell); rows/cols are clamped by
	# the table's int rules now that only a terminal accepts them.
	var filtered := sanitize_settings(type_name, settings, SOURCE_FILE)
	var kept: Dictionary = filtered["settings"]
	# A spawn key is not a property: the restore path consumes it (and reports
	# its own drop for `shell_env`), so it must not count as an ignored setting.
	var dropped := PackedStringArray()
	for key in filtered["dropped"]:
		if not SPAWN_KEYS.has(key):
			dropped.append(key)
	for key in SPAWN_KEYS:
		if settings.has(key) and not kept.has(key):
			kept[key] = settings[key]
	var col: int = clamp_grid_int(td.get("col", 0), 0, grid_size - 1)
	var row: int = clamp_grid_int(td.get("row", 0), 0, grid_size - 1)
	var cspan: int = clamp_grid_int(td.get("cspan", grid_size), 1, grid_size)
	var rspan: int = clamp_grid_int(td.get("rspan", grid_size), 1, grid_size)
	cspan = mini(cspan, grid_size - col)
	rspan = mini(rspan, grid_size - row)
	return {
		"settings": kept, "type_name": type_name,
		"col": col, "row": row, "cspan": cspan, "rspan": rspan,
		"dropped": dropped,
	}

## Convert legacy Observer layouts before type validation. This keeps existing
## user layouts/profiles loadable after Observer becomes two explicit panes.
static func migrate_pane_settings(raw: Dictionary) -> Dictionary:
	var settings: Dictionary = raw.duplicate(true)
	if settings.get("type", "") == "observer":
		settings["type"] = (
			"reasoning" if settings.get("stream", "answer") == "thinking"
			else "inspector"
		)
		settings.erase("stream")
		settings.erase("auto_run")
		settings.erase("label")
		settings.erase("label_name")
	var attachment = settings.get("attachment_id", "")
	settings["attachment_id"] = sanitize_attachment_id(attachment)
	return settings

static var _attachment_id_re: RegEx = null

static func sanitize_attachment_id(v) -> String:
	if not (v is String) or v.length() > 32:
		return ""
	# Compiled once and cached: this runs for every tag and every restored
	# pane, so building the pattern per call was repeated work on the
	# layout-restore and profile-activation paths.
	if _attachment_id_re == null:
		_attachment_id_re = RegEx.new()
		_attachment_id_re.compile("^[a-z][a-z0-9_-]{0,31}$")
	return v if _attachment_id_re.search(v) != null else ""

## Generate a stable public id for panes created without a saved one.
## Matches the attachment_id pattern ([a-z][a-z0-9_-]{0,31}).
static func generate_attachment_id() -> String:
	const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"
	var s := "pane-"
	for _i in 8:
		s += CHARS[randi() % CHARS.length()]
	return s

## Workspace ids: the other half of a per-pane store key (`PaneCwdStore`).
##
## Minted locally and never authored in a file, so a downloaded profile or
## layout cannot name one - which is what keeps a per-pane directory
## unreachable from anything but the user's own pane settings. The grammar
## lives here, beside `attachment_id`, because the two ids are joined into one
## store key and must not drift apart.
const WORKSPACE_ID_PREFIX := "ws-"
const WORKSPACE_ID_HEX := 12

static var _workspace_id_re: RegEx = null

static func sanitize_workspace_id(v) -> String:
	if not (v is String) or v.length() != WORKSPACE_ID_PREFIX.length() + WORKSPACE_ID_HEX:
		return ""
	if _workspace_id_re == null:
		_workspace_id_re = RegEx.new()
		_workspace_id_re.compile("^ws-[0-9a-f]{12}$")
	return v if _workspace_id_re.search(v) != null else ""

## A fresh workspace id. A rename keeps the id; only a new workspace mints one.
static func new_workspace_id() -> String:
	# 6 bytes -> 12 lowercase hex, the length `sanitize_workspace_id` enforces.
	return WORKSPACE_ID_PREFIX + Crypto.new().generate_random_bytes(6).hex_encode()

## Sanitize a pane-tag list from untrusted layout/profile/IPC data.
## Each tag follows the attachment_id pattern; oversize/foreign values drop.
##
## A value that is not an array has no tags in it, so it is `[]` — the way
## `sanitize_shell_args` treats the same input. A typed parameter would raise
## instead, and this is called from the IPC drain loop, where one raise aborts
## every request in the batch (GDScript has no try/catch).
static func sanitize_tags(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for t in raw:
		if t is String and out.size() < 16:
			var clean := sanitize_attachment_id(t)
			if clean != "" and not out.has(clean):
				out.append(clean)
	return out

## The sides an explicit split can name, in the order `--split` accepts them.
## `""` (no preference) is not one of them: the target tile's aspect decides.
const SPLIT_SIDES := ["left", "right", "top", "bottom"]

## Longest display title accepted; a title is a label, not a document.
const TITLE_MAX_LENGTH := 64

## Sanitize a pane's display title from untrusted IPC or file data.
##
## Control characters (a newline would break the title bar's single line) are
## dropped and the result is cut at `TITLE_MAX_LENGTH`; the U+FFFD that a
## decoded NUL becomes means the value was never a title, so the whole string
## falls back to the pane type's default name (`""`).
static func sanitize_title(v) -> String:
	if not (v is String):
		return ""
	var out := ""
	for ch in v:
		if ch == "\uFFFD":
			return ""
		if out.length() >= TITLE_MAX_LENGTH:
			break
		var code: int = ch.unicode_at(0)
		if code >= 0x20 and code != 0x7f:
			out += ch
	return out.strip_edges()

## Validate a shell command from layout/profile data. Non-strings,
## empty, oversized, or invalid-Unicode values fall back to `fallback`.
## Godot replaces decoded NUL bytes with U+FFFD before GDScript can inspect
## them, so reject that replacement marker instead of embedding `\u0000`.
static func sanitize_shell(v, fallback: String) -> String:
	if v is String and v != "" and v.length() <= 1024 and not v.contains("\uFFFD"):
		return v
	return fallback


## Arguments that make `program` run `command` and exit.
##
## `cmd.exe` — the Windows default `cfg_shell_command` — spells the "run this
## and exit" flag `/c` and rejects the POSIX `-c`; every other shell gpty
## targets takes `-c`. The pane API runs commands through the user's configured
## shell, so this is the one place that difference lives.
static func shell_run_args(program: String, command: String) -> Array:
	var base := program.get_file().to_lower()
	if base == "cmd" or base == "cmd.exe":
		return ["/c", command]
	return ["-c", command]


## A launch line is one shell command line a tile runs through the user's own
## configured shell at spawn — the portable spelling of a startup program:
## `omp update && exec omp` needs a shell, and the flag that runs a line
## differs by shell family (`shell_run_args`), so a tile cannot name the argv
## itself. One line, capped, without control characters: the same contract
## `plugin_manifest::validate_tile` enforces.
const LAUNCH_MAX_LENGTH := 1024

## The first character of a launch tile's spawn-plan key. U+FFFD is the one
## character every sanitizer here refuses, so no program or argv entry can
## produce a key that begins with it: a launch plan can never collide with a
## program+argv plan. The runner is deliberately absent — it is the user's
## configured shell, not the file's choice, and the plugin review runs before a
## shell could be known (`plugin.rs::tile_launch_line` mirrors this).
const LAUNCH_KEY_MARK := "\uFFFD"

## `v` as a launch line, or "" when it is not one. Trimmed; empty means
## "inherit the pane's program". A control character (a newline would smuggle a
## second line into a field that promises one), U+FFFD, or more than
## `LAUNCH_MAX_LENGTH` characters is refused whole rather than truncated: a
## truncated command is a different command.
static func sanitize_launch(v) -> String:
	if not (v is String):
		return ""
	var line: String = v.strip_edges()
	if line == "" or line.length() > LAUNCH_MAX_LENGTH:
		return ""
	for ch in line:
		var code: int = ch.unicode_at(0)
		if code < 0x20 or (code >= 0x7f and code <= 0x9f) or ch == "\uFFFD":
			return ""
	return line

## The launch line a tile names (its `settings.launch`), sanitized; "" when it
## names none.
static func tile_launch_line(td: Dictionary) -> String:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return ""
	return sanitize_launch(settings.get("launch", ""))

## The program and argv one spawn uses. A launch line expands through `runner`
## (the user's configured shell) and wins over the program field and argv,
## because it is the plan. Sanitized here so every caller gets the same answer.
static func spawn_argv(program: String, args: Array, launch: String, runner: String) -> Dictionary:
	var line := sanitize_launch(launch)
	if line != "":
		var shell := runner if runner != "" else program
		return {"program": shell, "args": shell_run_args(shell, line), "launch": line}
	return {"program": program, "args": sanitize_shell_args(args), "launch": ""}

## The program a tile starts, sanitized: `command` > `settings.shell` > the
## tile's legacy `shell` > `default_program`. The derivation the restore path,
## the trust dialog and the profile editor read. The plan key and the trust
## gate keep their raw comparison, so a stored approval stays byte-identical.
static func tile_program(td: Dictionary, default_program: String) -> String:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		settings = {}
	var raw := str(settings.get("command", settings.get("shell", td.get("shell", ""))))
	return sanitize_shell(raw, default_program)

## The Save Profile dialog's write path: the launch field is the only key the
## dialog owns, and an empty field is erased (inherit) rather than written as
## "". Never writes `shell`/`shell_args` — one spelling.
static func apply_launch_field(td: Dictionary, line: String) -> void:
	var settings = td.get("settings", {})
	if not (settings is Dictionary):
		return
	var clean := sanitize_launch(line)
	if clean == "":
		settings.erase("launch")
	else:
		settings["launch"] = clean
	td["settings"] = settings

## Sanitize program arguments from untrusted layout/profile data: array of
## non-empty strings ≤4096 chars without U+FFFD, capped at 32 entries.
static func sanitize_shell_args(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for a in raw:
		if a is String and a != "" and a.length() <= 4096 and not a.contains("\uFFFD"):
			out.append(a)
		if out.size() >= 32:
			break
	return out

# ── Pane settings a file may set ───────────────────────────────────────
#
# A tile's `settings` dictionary is attacker-controlled: it comes from
# workspaces.json, profiles.json and the JSON a plugin ships. It used to reach
# every exported property through `PaneBody._set_typed` (any String/int/float/
# bool), so a file could set `font_bold_path` and the next font reload ran
# `load()` on it - a `.tres` with an embedded script executes during load(),
# which Workspace Trust never saw because a font is not a spawn plan.
#
# The vocabulary is now closed per pane type. A key that is not in its table
# is dropped (and counted for the restore notice), a known key is coerced and
# clamped by its rule, and a rule marked `file: false` is refused to files: the
# user's own settings, the pane panel and the app's spawn options still set it
# through SOURCE_RUNTIME. A rule marked `ipc: false` is refused to the control
# surface (`paneSet`, `new-pane --setting`): those values are the user's own
# record, the pane's identity, or state a restore consumes rather than a
# setting. The values are the pane's *saved* vocabulary
# (`_get_layout_state`) plus what the app itself applies; a new pane property
# meant to survive a layout must be added here, and
# `test_pane_settings.gd` fails when a saved key is not accepted.

const SOURCE_FILE := 0     ## workspaces.json / profiles.json / plugin JSON
const SOURCE_RUNTIME := 1  ## global settings, pane panel, spawn options

## A control-surface caller (`paneSet`, `new-pane --setting`): a live program
## with the socket's authority, not a file, and not the user's own gesture.
## It may set what the pane settings panel may, minus the values whose owner is
## the user (env, the Inspector's aim), the pane's identity and its geometry -
## each carries `ipc: false` in the table below.
const SOURCE_IPC := 2

## The font-size range, shared by the settings rule and the pane panel's
## spinbox so the two cannot disagree.
const FONT_SIZE_MIN := 8
const FONT_SIZE_MAX := 32

## The terminal grid's inner padding, per side in logical pixels: the global
## appearance default, and the ceiling a hand-edited store or a caller may
## reach. The fit spends `2 x padding` before it divides by the cell, so the
## row and column count stay the count the pane actually shows.
const TERMINAL_PADDING_DEFAULT := 4
const TERMINAL_PADDING_MAX := 24

## Shared by every pane type.
##
## `type` and `attachment_id` are `ipc: false`: the discriminator is read, never
## set (a type swap is its own gesture with its own path), and the id is the
## pane's address - renaming it re-keys the user's per-pane stores, retargets
## companions and strands every pending wait, so the pane settings panel stays
## its only writer.
const COMMON_SETTINGS := {
	"type": {"kind": "text", "max": 32, "ipc": false},  # discriminator; read, never set
	"pane_name": {"kind": "text", "max": 128},
	"attachment_id": {"kind": "id", "ipc": false},
	"tags": {"kind": "tags"},
	"font_size": {"kind": "int", "min": FONT_SIZE_MIN, "max": FONT_SIZE_MAX},
}

## Extensions the terminal font loader will read. Anything else - notably
## `.tres`/`.res`, which can carry a script - falls back to the bundled font.
const FONT_EXTENSIONS := ["ttf", "otf", "ttc", "woff", "woff2"]

## Keys `Workspace._restore_into` consumes itself instead of applying them as
## properties: the spawn program, its argv source and the env block it strips
## with its own notice. Kept verbatim by `sanitize_tile`; each is validated
## where it is used (the trust gate + `sanitize_shell`).
const SPAWN_KEYS := ["shell", "command", "shell_env"]

## The pane's own directory: user-owned (`PaneCwdStore`), so a file cannot
## choose it and no IPC caller can set it. A terminal and a `cli_view` both
## spawn a child, so both tables carry it.
const PANE_DIR_RULE := {"kind": "dir_path", "max": 4096, "file": false, "ipc": false}

const TERMINAL_SETTINGS := {
	# Geometry is the tile's: a stored size seeds a restore, and a live grid
	# never resizes from these (`test_apply_settings_rows_cols_never_resizes_a_live_grid`),
	# so an IPC caller setting one would change nothing it could see.
	"rows": {"kind": "int", "min": 1, "max": PANE_MAX_ROWS, "ipc": false},
	"cols": {"kind": "int", "min": 1, "max": PANE_MAX_COLS, "ipc": false},
	# A shell line (the portable spelling of a startup program): the spawn
	# expands it through the user's configured shell. `shell_args` is the
	# explicit argv form, and a launch line wins over it.
	"launch": {"kind": "launch"},
	"shell_args": {"kind": "argv"},
	"shell_command": {"kind": "shell", "file": false},
	# Env is the user's own store (`PaneEnvStore`, keyed by the pane's id and
	# written only by the pane settings UI), never a caller's block.
	"shell_env": {"kind": "text", "max": 65536, "file": false, "ipc": false},
	# The pane's own directory (`PaneCwdStore`): read at attach, resolved at
	# spawn, and written only by the pane settings UI.
	"pane_cwd": PANE_DIR_RULE,
	"font_path": {"kind": "font_path"},
	# The inset between the tile edge and the grid. This is the user's window
	# fit, not pane content: the global appearance setting broadcasts it, and
	# a shared layout cannot carry it.
	"terminal_padding": {"kind": "int", "min": 0, "max": TERMINAL_PADDING_MAX, "file": false},
	# The global effect table's id and intensity, broadcast by
	# `apply_to_terminal` like `terminal_padding`. A file cannot name one: the
	# shaders are code (`UiEffects`), so only the closed ids can arrive. The
	# literal list is the `-s` entry-point-safe copy; `test_ui_effects.gd`
	# asserts it against `UiEffects.AMBIENT_IDS`.
	"effect": {"kind": "text", "max": 16, "values": ["crt", "grain", "vignette", "aurora", "dither"], "file": false, "ipc": false},
	"effect_intensity": {"kind": "int", "min": 0, "max": 2, "file": false, "ipc": false},
	# The Appearance tab's terminal backdrop (Flat/Gradient), broadcast by
	# `apply_to_terminal` like the effect: a shared layout must not restyle a
	# pane, and no IPC caller may reach it.
	"backdrop": {"kind": "int", "min": 0, "max": 1, "file": false, "ipc": false},
	# The global dark/light pair's resolved member, pushed by
	# `apply_to_terminal` on every save. A file must not name it: appearance
	# paths are the user's, not a shared layout's.
	"color_scheme_path": {"kind": "scheme_path", "file": false},
	# The pane's own scheme (`PaneSchemeStore`, keyed by the pane's id and
	# written only by the pane settings UI): a layout or an IPC caller cannot
	# style a pane.
	"pane_scheme": {"kind": "scheme_path", "file": false, "ipc": false},
	"cursor_shape": {"kind": "int", "min": 0, "max": 2},
	"cursor_blink": {"kind": "bool"},
	"cursor_blink_speed": {"kind": "float", "min": 0.1, "max": 2.0},
	"cursor_color": {"kind": "color"},
	"scroll_lines": {"kind": "int", "min": 1, "max": 10},
	"max_fps": {"kind": "int", "min": 0, "max": 240},
	"default_fg": {"kind": "color"},
	"default_bg": {"kind": "color"},
	"beam_cursor_width": {"kind": "int", "min": 1, "max": 8},
	"underline_cursor_height": {"kind": "int", "min": 1, "max": 8},
	"focus_border_color": {"kind": "color", "file": false},
	"selection_color": {"kind": "color", "file": false},
	"scrollback_indicator_color": {"kind": "color", "file": false},
}

## The code viewer's two closed vocabularies, shared by its settings UI and its
## rules so the dropdown and the table cannot disagree. `""` is "(auto)", which
## renders by the file's extension.
const CODE_VIEWER_LANGUAGES := ["", "md", "gd", "py", "rs", "c", "cpp", "h", "js", "ts"]
const CODE_VIEWER_VIEW_MODES := ["auto", "source", "rendered"]

## The file tree's two activation routes: the in-app viewer when `ViewableFiles`
## supports the path, or the system handler.
const FILE_TREE_OPEN_MODES := ["viewer", "system"]
const FILE_TREE_DEFAULT_OPEN_MODE := "viewer"

## The wiki pane's note-view modes, shared with `paneView`'s `mode` parameter.
const WIKI_VIEW_MODES := ["edit", "split", "preview"]

## The wiki pane's link-map presentations. `auto` resolves from the adapter
## (`VaultGraph3D` on hardware, the planar canvas on a software rasterizer);
## an explicit value is the user's choice. Labels live beside the list so the
## Pane Settings picker and the graph's own mode button cannot drift.
const WIKI_GRAPH_MODES := ["auto", "3d", "2d"]
const WIKI_GRAPH_MODE_LABELS := {
	"auto": "Auto",
	"3d": "Orbital",
	"2d": "Planar",
}

## The wiki link-map themes. The registry owns the ids and labels so the Pane
## Settings picker and the layout schema cannot drift.
const WIKI_GRAPH_THEMES := GraphTheme.IDS
const WIKI_GRAPH_THEME_LABELS := GraphTheme.LABELS

const CODE_VIEWER_SETTINGS := {
	"file_path": {"kind": "text", "max": 4096},
	"language": {"kind": "text", "max": 64, "values": CODE_VIEWER_LANGUAGES},
	"view_mode": {"kind": "text", "max": 32, "values": CODE_VIEWER_VIEW_MODES},
}

const FILE_TREE_SETTINGS := {
	"root_path": {"kind": "text", "max": 4096},
	"open_in": {"kind": "text", "max": 32, "values": FILE_TREE_OPEN_MODES},
}

const INSPECTOR_SETTINGS := {
	# The backend is a domain vocabulary, not free text: `BackendChoice` folds
	# the parser's aliases (`oh-my-pi`, `pi`) into their kind and keeps a name
	# it does not know verbatim, so Pane Settings can show that value as
	# `Custom:` instead of resetting a user's file. `values` is the canonical
	# set they fold into - the one `pane-settings` publishes.
	"backend": {"kind": "backend", "max": 32, "values": BackendChoice.KINDS},
	"command": {"kind": "argv"},
	# A file may not aim the pane. The prompt decides what the model is asked,
	# and the two switches decide whether a concept capture is sent with no
	# gesture at all - a shared profile plus a routing concept is otherwise an
	# untrusted-instruction channel. The pane panel (SOURCE_RUNTIME) sets all
	# three for the live pane; a restored pane starts from its own defaults
	# (auto-send off, no prompt), and none of them is layout state. `ipc: false`
	# for the same reason as the panel: the aim is the user's own record
	# (`PaneInspectorStore`), and a live-only aim would vanish at the next
	# restart with nothing to show for it.
	"auto_run": {"kind": "bool", "file": false, "ipc": false},
	"accept_concept_captures": {"kind": "bool", "file": false, "ipc": false},
	"system_prompt": {"kind": "text", "max": 65536, "file": false, "ipc": false},
	"model": {"kind": "text", "max": 128},
}

const REASONING_SETTINGS := {
	"source_attachment_id": {"kind": "id"},
}

const CLI_VIEW_SETTINGS := {
	"command": {"kind": "shell"},
	"shell_args": {"kind": "argv"},
	"pane_cwd": PANE_DIR_RULE,
}

const WIKI_SETTINGS := {
	"vault_path": {"kind": "text", "max": 4096},
	"view_mode": {"kind": "text", "max": 32, "values": WIKI_VIEW_MODES},
	"graph_mode": {"kind": "text", "max": 8, "values": WIKI_GRAPH_MODES},
	"graph_theme": {"kind": "text", "max": 16, "values": WIKI_GRAPH_THEMES},
	# Restore-only state: both are replayed at attach and ignored on a live pane
	# (`WikiPane.apply_settings` clears them once it is in the tree), and the
	# gestures themselves belong to `pane-view --note` / `--graph`.
	"open_note": {"kind": "text", "max": 512, "ipc": false},
	"graph": {"kind": "bool", "ipc": false},
	# Saved link-map geometry: a bounded `{id: [x, y]}` block. `max` is its
	# entry cap here, not a string length; `positions` owns the value rules.
	# It is display state only, so a file may carry it and an IPC caller may
	# not (the same rule as `open_note`/`graph`).
	"graph_positions": {
		"kind": "positions", "ipc": false,
		"max": VaultGraphModel.MAX_POSITION_ENTRIES,
	},
}

const MEDIA_SETTINGS := {
	"file_path": {"kind": "text", "max": 4096},
	"volume_db": {"kind": "float", "min": -40.0, "max": 6.0},
	"muted": {"kind": "bool"},
	"loop": {"kind": "bool"},
}

const PANE_SETTINGS := {
	"terminal": TERMINAL_SETTINGS,
	"code_viewer": CODE_VIEWER_SETTINGS,
	"file_tree": FILE_TREE_SETTINGS,
	"inspector": INSPECTOR_SETTINGS,
	"reasoning": REASONING_SETTINGS,
	"cli_view": CLI_VIEW_SETTINGS,
	"wiki": WIKI_SETTINGS,
	"media": MEDIA_SETTINGS,
}

## The closed key table for one pane type (common + its own).
static func settings_schema(type_name: String) -> Dictionary:
	var schema: Dictionary = COMMON_SETTINGS.duplicate()
	var own = PANE_SETTINGS.get(type_name)
	if own is Dictionary:
		schema.merge(own)
	return schema

## Filter a settings dictionary through `type_name`'s table.
##
## Returns `{"settings": Dictionary, "dropped": PackedStringArray}`. `dropped`
## names every key that was refused - unknown to the type, wrong-typed, out of
## range, or reserved to the app when `source` is SOURCE_FILE - so the caller
## can tell the user once per load instead of silently changing their pane.
static func sanitize_settings(type_name: String, raw: Dictionary, source: int = SOURCE_RUNTIME) -> Dictionary:
	var schema := settings_schema(type_name)
	var out := {}
	var dropped := PackedStringArray()
	for key in raw:
		if not (key is String):
			continue
		var rule = schema.get(key)
		if not (rule is Dictionary):
			dropped.append(str(key))
			continue
		if source == SOURCE_FILE and rule.get("file", true) == false:
			dropped.append(key)
			continue
		if source == SOURCE_IPC and rule.get("ipc", true) == false:
			dropped.append(key)
			continue
		var value = _value_for_rule(rule, raw[key])
		if value == null:
			dropped.append(key)
			continue
		out[key] = value
	return {"settings": out, "dropped": dropped}

## Coerce one value through its rule, or null when it must be dropped.
static func _value_for_rule(rule: Dictionary, v) -> Variant:
	match str(rule.get("kind", "")):
		"text":
			if not (v is String):
				return null
			var text: String = v
			if text.length() > int(rule.get("max", 128)) or text.contains("\uFFFD"):
				return null
			# A closed set: no pane re-derives one at apply time, so a member
			# the table does not know must be refused here or it becomes a
			# silent no-op that the read-back reports as a set that never moved.
			var values = rule.get("values", null)
			if values is Array and not values.has(text):
				return null
			return text
		"int":
			if not (v is int or v is float):
				return null
			var f := float(v)
			if not is_finite(f):
				return null
			var lo := int(rule.get("min", 0))
			var hi := int(rule.get("max", lo))
			return clampi(int(clampf(f, float(lo), float(hi))), lo, hi)
		"float":
			if not (v is int or v is float):
				return null
			var f := float(v)
			if not is_finite(f):
				return null
			return clampf(f, float(rule.get("min", 0.0)), float(rule.get("max", 0.0)))
		"bool":
			return v if v is bool else null
		"color":
			# Colors saved to JSON are "(r, g, b, a)" strings; the pane parses
			# them (`TerminalPane._restore_color_strings`). Both forms pass.
			if v is Color:
				return v
			if v is String and _is_color_string(v):
				return v
			return null
		"id":
			if not (v is String):
				return null
			if v == "":
				return ""  # `ensure_attachment_id` fills it
			var clean := sanitize_attachment_id(v)
			return clean if clean != "" else null
		"tags":
			return sanitize_tags(v) if v is Array else null
		"positions":
			# Saved canvas geometry: the model owns the id/entry caps, the
			# finite-pair check and the clamp, so `graph_positions` cannot
			# carry a value the canvas would have to defend against later.
			if not (v is Dictionary):
				return null
			return VaultGraphModel.sanitize_positions(v)
		"argv":
			return sanitize_shell_args(v) if v is Array else null
		"launch":
			if not (v is String):
				return null
			var cleaned := sanitize_launch(v)
			# "" is the cleared field ("inherit"); a non-empty value the
			# sanitizer refused is dropped and named, never silently erased.
			if cleaned == "" and str(v).strip_edges() != "":
				return null
			return cleaned
		"dir_path":
			# The pane's own directory. "" is the cleared field ("inherit the
			# workspace's"), and the sanitizer owns absolute-only, the length
			# cap and control bytes - the same check every store applies.
			if not (v is String):
				return null
			var dir: String = v
			if dir.strip_edges() == "":
				return ""
			var clean_dir := BasePersistenceManager.sanitize_absolute_dir(
				dir, int(rule.get("max", 4096)))
			return clean_dir if clean_dir != "" else null
		"shell":
			if not (v is String):
				return null
			var program := sanitize_shell(v, "")
			return program if program != "" else null
		"font_path":
			if not (v is String):
				return null
			var path: String = v
			if path == "":
				return ""
			if path.length() > 4096 or path.contains("\uFFFD"):
				return null
			# A data value may only name a real filesystem file, never a Godot
			# scheme — and `is_absolute_path()` alone calls `res://`/`user://`
			# absolute. The bundled fonts are `res://` constants no file ever
			# supplies.
			if not BasePersistenceManager.is_real_absolute_path(path) \
					or not font_extension_ok(path):
				return null
			return path
		"scheme_path":
			if not (v is String):
				return null
			var scheme: String = v
			if scheme.length() > 4096 or scheme.contains("\uFFFD"):
				return null
			return scheme
		"backend":
			# The Inspector's vocabulary: an alias folds to its canonical kind,
			# an empty value means the pane default, and a name the parser does
			# not know stays verbatim (the dropdown shows it as `Custom:`).
			if not (v is String):
				return null
			var named: String = v
			if named.length() > int(rule.get("max", 32)) or named.contains("\uFFFD"):
				return null
			return BackendChoice.selected_kind(named)
	return null

static func _is_color_string(v: String) -> bool:
	var s := v.strip_edges()
	if not (s.begins_with("(") and s.ends_with(")")):
		return false
	var parts := s.substr(1, s.length() - 2).split(",", false)
	if parts.size() < 3:
		return false
	for part in parts:
		if not part.strip_edges().is_valid_float():
			return false
	return true

## True when `path` names a font file the loader may read (by extension).
static func font_extension_ok(path: String) -> bool:
	return FONT_EXTENSIONS.has(path.get_extension().to_lower())

## A `FileDialog` filter string for every extension the font loader reads, so
## the pickers and the loader cannot drift apart.
static func font_filter() -> String:
	var parts := PackedStringArray()
	for ext in FONT_EXTENSIONS:
		parts.append("*." + ext)
	return ", ".join(parts)
