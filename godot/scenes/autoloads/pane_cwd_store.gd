extends BasePersistenceManager
# PaneCwdStore — the user's own per-pane working directory, keyed by
# `<workspace id>/<attachment id>`.
#
# `user://pane_cwd.json` is the ONLY place a pane's own directory lives, and
# only the pane settings UI writes it (`Workspace`'s settings_applied handler
# is the single write path). A profile, a layout or a plugin tile never carries
# one: the settings table marks `pane_cwd` `file: false` and `ipc: false`, and
# the key's first half is a workspace id this build mints locally
# (`PaneTypes.new_workspace_id`), which no downloaded file can name. That is
# the v0.7.1 rule — a file must not be spawn-time authority — with the
# directory as the user's own grant, the way `PaneEnvStore` holds the env.
#
# The key joins BOTH ids on purpose: attachment ids are unique across the whole
# window, so a builtin such as `agent-terminal` reappears in every workspace
# that activates the profile, and an entry keyed by the pane id alone would
# silently follow the profile into another repository.
#
# A collision rename (`Workspace._on_duplicate_rename`) deliberately does NOT
# copy an entry here, unlike env: the key names a workspace, so the other
# instance keeps its own directory and the renamed tile simply has none.
#
# The file is still hand-editable, so the loader treats it like every other
# store: typed reads, an id-pattern key check, and size caps — a bad entry
# costs itself, not the file.

const DIR_FILE := "user://pane_cwd.json"

## Caps for hand-edited file content. The window's live pane ceiling is 96, so
## 256 entries covers pane churn between workspace deletions.
const MAX_ENTRIES := 256
const MAX_DIR_CHARS := 4096

var _dirs: Dictionary = {}

## Directories already reported as missing this run, so a workspace of panes
## sharing a stale path warns once instead of once per spawn.
static var _warned: Dictionary = {}

func _on_init():
	reload()

func reload():
	_dirs = {}
	var d = _read_file(DIR_FILE)
	for key in d:
		if not (key is String) or not _valid_key(key):
			continue
		if _dirs.size() >= MAX_ENTRIES:
			break
		var value := _as_string(d, key, "")
		var clean := BasePersistenceManager.sanitize_absolute_dir(value, MAX_DIR_CHARS)
		if clean == "":
			continue
		_dirs[key] = clean

## The pane's own directory, or "" when it inherits the workspace's.
func dir_for(ws_id: String, pane_id: String) -> String:
	return str(_dirs.get(key_for(ws_id, pane_id), ""))

func has_dir(ws_id: String, pane_id: String) -> bool:
	return _dirs.has(key_for(ws_id, pane_id))

## The pane settings UI's write path. An empty value removes the entry, so a
## cleared directory falls back to the workspace's. A value the shared
## sanitizer refuses stores nothing (an unset entry is the honest state; a
## relative or virtual path is not).
func set_dir(ws_id: String, pane_id: String, dir: String):
	var key := key_for(ws_id, pane_id)
	if key == "":
		return
	var clean := BasePersistenceManager.sanitize_absolute_dir(dir, MAX_DIR_CHARS)
	if clean == "":
		remove_dir(ws_id, pane_id)
		return
	if str(_dirs.get(key, "")) == clean:
		return  # the debounced panel re-applies on every keystroke
	_dirs[key] = clean
	_write_file(DIR_FILE, _dirs)

func remove_dir(ws_id: String, pane_id: String):
	var key := key_for(ws_id, pane_id)
	if not _dirs.has(key):
		return
	_dirs.erase(key)
	_write_file(DIR_FILE, _dirs)

## A rename the user made in Pane Settings moves the entry: the old id is no
## longer the pane's, so it must not carry a directory any more.
func move_pane(ws_id: String, old_id: String, new_id: String):
	if old_id == "" or new_id == "" or old_id == new_id:
		return
	var old_key := key_for(ws_id, old_id)
	var new_key := key_for(ws_id, new_id)
	if old_key == "" or new_key == "" or not _dirs.has(old_key):
		return
	if not _dirs.has(new_key):
		_dirs[new_key] = _dirs[old_key]
	_dirs.erase(old_key)
	_write_file(DIR_FILE, _dirs)

## A workspace that went away takes its entries with it.
func drop_workspace(ws_id: String):
	var prefix := ws_id + "/"
	var kept := {}
	for key in _dirs:
		if not str(key).begins_with(prefix):
			kept[key] = _dirs[key]
	if kept.size() == _dirs.size():
		return
	_dirs = kept
	_write_file(DIR_FILE, _dirs)

## Keep only the entries of workspaces in `ids`: what a restore knows survived
## (a hand-edited store, or a workspace closed while the GUI was not running).
func retain_workspaces(ids: PackedStringArray):
	var kept := {}
	for key in _dirs:
		if ids.has(str(key).get_slice("/", 0)):
			kept[key] = _dirs[key]
	if kept.size() == _dirs.size():
		return
	_dirs = kept
	_write_file(DIR_FILE, _dirs)

## The directory a child of this pane starts in: the pane's own directory when
## it is a usable one, else the workspace's, else the user's home directory,
## else "" (the child inherits gpty's own directory).
##
## The home fallback is the point: a terminal child already defaulted there
## (portable-pty's own choice) while a `cli_view` inherited the GUI process's
## directory - gpty's installation or project directory. Both backends now
## receive the same explicit directory. Resolved at the moment of the spawn,
## not stored in the pane, so a `cli_view` Restart re-checks it. A path that
## has gone missing — a moved repository, an unmounted disk — warns once per
## key and falls through to the next layer rather than reaching the PTY layer,
## which would drop it silently and leave the child somewhere else with no
## explanation.
func resolve(ws_id: String, pane_id: String, override: String, workspace_cwd: String) -> String:
	var home := home_dir()
	var home_usable := home != "" and DirAccess.dir_exists_absolute(home)
	var own := BasePersistenceManager.sanitize_absolute_dir(override, MAX_DIR_CHARS)
	if own != "":
		if DirAccess.dir_exists_absolute(own):
			return own
		_warn_once("pane:" + key_for(ws_id, pane_id),
			"Pane '%s' starts in the workspace directory: its own directory no longer exists (%s)"
			% [pane_id, own])
	var inherited := BasePersistenceManager.sanitize_absolute_dir(workspace_cwd, MAX_DIR_CHARS)
	if inherited != "":
		if DirAccess.dir_exists_absolute(inherited):
			return inherited
		_warn_once("workspace:" + ws_id,
			"Workspace directory no longer exists (%s); its panes start in %s"
			% [inherited, home if home_usable else "gpty's own directory"])
	if home_usable:
		return home
	return ""

## The user's home directory, or "" when the environment names none.
##
## Godot has no home-directory query of its own, so this is the same pair the
## workspace picker opens on (`HOME`, then `USERPROFILE`) plus the older
## Windows split. Sanitized like every other directory value: a relative or
## virtual path is not a spawn directory.
func home_dir() -> String:
	var raw := OS.get_environment("HOME")
	if raw == "":
		raw = OS.get_environment("USERPROFILE")
	if raw == "":
		var drive := OS.get_environment("HOMEDRIVE")
		var path := OS.get_environment("HOMEPATH")
		if drive != "" and path != "":
			raw = drive + path
	return BasePersistenceManager.sanitize_absolute_dir(raw, MAX_DIR_CHARS)

static func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	ToastManager.warn(message)

## `<workspace id>/<attachment id>`, or "" when either half is not an id this
## build could have minted (`PaneTypes.sanitize_workspace_id` /
## `PaneTypes.sanitize_attachment_id`).
static func key_for(ws_id: String, pane_id: String) -> String:
	if PaneTypes.sanitize_workspace_id(ws_id) == "":
		return ""
	if PaneTypes.sanitize_attachment_id(pane_id) == "":
		return ""
	return ws_id + "/" + pane_id

## A loaded key must be exactly the two ids joined, so an entry can never
## outlive the shapes the panes and workspaces actually carry.
static func _valid_key(key: String) -> bool:
	var parts := key.split("/")
	if parts.size() != 2:
		return false
	return key_for(parts[0], parts[1]) == key
