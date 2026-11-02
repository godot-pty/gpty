class_name BasePersistenceManager
extends Node

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Before any store is read, so a loose directory is closed first: every
	# autoload extends this class, and the guard makes the engine's start-up
	# pass one repair rather than one per autoload.
	_secure_user_root_once()
	_on_init()

func _on_init():
	pass

## The per-run user directory a test harness may redirect every store to.
##
## Godot resolves `user://` through the OS — on Windows via the Known Folder
## API, which no environment variable redirects — so a suite that writes probe
## vaults, seeds stores or restores a legacy `layout.json` would touch the
## developer's real profile. `scripts/gut-check` (and the live smoke) therefore
## exports `GPTY_TEST_USER_DIR`; the stores and the gdext history database
## (`history_db_path` in Rust) read the same variable, so one sandbox covers
## both halves. Empty or relative values are ignored: a test root must name an
## absolute directory, and the harness creates it.
static func user_root_override() -> String:
	var root := OS.get_environment("GPTY_TEST_USER_DIR")
	if not is_real_absolute_path(root):
		return ""
	return root.trim_suffix("/").trim_suffix("\\")

## Whether `path` names a Godot virtual location rather than a filesystem one.
##
## `String.is_absolute_path()` answers true for `res://` and `user://` too
## (measured on 4.7.2), so it is not the guard at a boundary that hands a path
## to code outside Godot's path resolution — `FileAccess`, `DirAccess` and
## `DirAccess.*_absolute` all accept the schemes, `std::path`, FFmpeg and a
## desktop handler do not.
static func is_virtual_path(path: String) -> bool:
	return path.begins_with("res://") or path.begins_with("user://")

## `path` as a real filesystem path: a virtual path is globalized through
## [`method resolve_store_path`] (so a redirected test root keeps its
## meaning), every other value — absolute or relative — is returned unchanged.
static func real_path(path: String) -> String:
	if path == "" or not is_virtual_path(path):
		return path
	var redirected := resolve_store_path(path)
	if not is_virtual_path(redirected):
		return redirected
	return ProjectSettings.globalize_path(redirected)

## Whether `path` is an absolute *real* path. This is the guard for a value
## that will leave Godot: it rejects an empty or relative path and a
## `res://`/`user://` scheme, which `is_absolute_path()` accepts.
static func is_real_absolute_path(path: String) -> bool:
	return path != "" and path.is_absolute_path() and not is_virtual_path(path)

## Translate a `user://` store path into the test root when one is set.
## Every other path (an absolute path, `res://`) is returned unchanged.
static func resolve_store_path(path: String) -> String:
	var root := user_root_override()
	if root == "" or not path.begins_with("user://"):
		return path
	return root.path_join(path.substr("user://".length()))

## The directory every store lives in, as an absolute path: the test root when
## the harness redirected `user://`, otherwise the engine's own answer.
static func user_root() -> String:
	var root := user_root_override()
	if root != "":
		return root
	return ProjectSettings.globalize_path("user://")

## Mode the `user://` root is kept at: owner only.
##
## The files inside carry `STORE_UNIX_MODE`, but a 0755 directory (measured:
## the engine creates `user://` with the process umask) already names every
## store in it, and a store written by an older build still carries the old
## file's mode until something saves it again. A 0700 root closes that gap for
## every store at once. No-op on Windows.
const USER_ROOT_UNIX_MODE := 0x1C0  # 0700

## Stores whose mode could not be repaired this run, so the warning is printed
## once instead of on every read of the same store.
static var _mode_failure_reported := {}

static var _user_root_secured := false

## Run [`method secure_user_root`] once per process.
static func _secure_user_root_once() -> void:
	if _user_root_secured:
		return
	_user_root_secured = true
	secure_user_root()

## Tighten the directory that holds every store to `USER_ROOT_UNIX_MODE`.
##
## Idempotent, cheap, and never fatal: a directory that refuses the change is
## worth one warning, not a failed launch. Ownership and the symlink refusal
## are the Rust side's (`_restrict_to_owner`) - GDScript cannot read a file's
## owner, and a chmod through a link would change someone else's directory.
static func secure_user_root() -> void:
	if OS.get_name() == "Windows":
		return
	var root := user_root()
	if not DirAccess.dir_exists_absolute(root):
		# The engine would create it on the first write, with the umask's mode.
		# Creating it here means the mode is right before the first store lands.
		var made := DirAccess.make_dir_recursive_absolute(root)
		if made != OK and made != ERR_ALREADY_EXISTS:
			push_warning("[BasePersistenceManager] cannot create %s (%d)" % [root, made])
			return
	var reason := _restrict_to_owner(root, true)
	if reason != "":
		push_warning(
			"[BasePersistenceManager] could not restrict the user directory to its owner (%s)" % reason
		)
	_tighten_log_dir(root.path_join("logs"))

## How many log files one start-up pass repairs.
##
## The engine writes one file per run (plus rotated ones), so the list grows;
## the cap keeps a directory someone filled by hand from turning launch into a
## syscall loop. Nothing is lost by stopping: the 0700 root already hides them.
const MAX_LOG_FILES := 32

## Keep the engine's log directory as private as the stores beside it.
##
## Godot writes `user://logs/godot.log` and its rotated siblings with the
## process umask once file logging is on - measured 0644 in a 0755 directory -
## and gPTY's policy is that program text never reaches a log file by default.
## The 0700 root closes the directory to other accounts on its own; this makes
## the modes inside it say the same thing, once per launch, because the engine
## re-creates the files it writes.
static func _tighten_log_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var report := _restrict_to_owner(dir, true)
	var handle := DirAccess.open(dir)
	if report == "" and handle != null:
		var seen := 0
		for entry in handle.get_files():
			if seen >= MAX_LOG_FILES:
				break
			if not entry.ends_with(".log"):
				continue
			seen += 1
			var file_report := _restrict_to_owner(dir.path_join(entry), false)
			if file_report != "":
				report = file_report
				break
	if report != "":
		push_warning(
			"[BasePersistenceManager] could not restrict the log directory to its owner (%s)" % report
		)

## Ask the Rust side for the owner-only mode on `target`; `""` means there was
## nothing to do or the mode is now owner-only, else the diagnostic to log.
##
## The extension is optional here: without it the store loads with whatever
## mode it already has, exactly as before the repair existed, instead of every
## read turning into a hard error. Windows needs no repair at all.
static func _restrict_to_owner(target: String, directory: bool) -> String:
	if OS.get_name() == "Windows":
		return ""
	if not ClassDB.class_exists("GptyTerminal"):
		return ""
	return str(GptyTerminal.secure_store_path(target, directory))

## Repair one store's mode as it is about to be read.
##
## The write path sets `STORE_UNIX_MODE` on every file it lands, but a store
## written by an older build keeps the umask's mode until it is saved again -
## measured: `layout.json` at 0644 beside `concepts.json` at 0600 - so the read
## is where an untouched store is repaired. Best effort: a repair that fails is
## one warning per store per run, and the load continues.
func _tighten_store_mode(target: String) -> void:
	var reason := _restrict_to_owner(target, false)
	if reason == "":
		return
	if not _claim_mode_failure(target):
		return
	push_warning("[%s] could not restrict %s to its owner (%s)" % [name, target, reason])

## True the first time a store's mode cannot be repaired, false afterwards.
static func _claim_mode_failure(target: String) -> bool:
	if _mode_failure_reported.has(target):
		return false
	_mode_failure_reported[target] = true
	return true

func _read_file(path: String) -> Dictionary:
	var target := resolve_store_path(path)
	if not FileAccess.file_exists(target):
		return {}
	_tighten_store_mode(target)
	var f = FileAccess.open(target, FileAccess.READ)
	if not f:
		return {}
	var j = JSON.new()
	if j.parse(f.get_as_text()) != OK:
		push_warning("[%s] Corrupt %s, starting fresh" % [name, path])
		return {}
	var d = j.get_data()
	if not (d is Dictionary):
		return {}
	return d

## Typed reads for persisted data.
##
## A store is user-editable and can be half-written or hand-edited, and one
## value of the wrong type used to abort the loader at that line: GDScript
## raises on `int([1,2])`, on assigning an Array to an `int` variable, and on
## calling `.get()` on a String — so everything *after* the bad key was
## dropped, and the next save wrote the reduced state back, making the loss
## permanent (a whole workspace set, every setting). Each accessor below
## returns `fallback` instead, so a bad value costs one entry, not the file.
func _as_int(d: Dictionary, key: String, fallback: int) -> int:
	var v = d.get(key, fallback)
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is bool:
		return int(v)
	if v is String and v.is_valid_int():
		return v.to_int()
	return fallback

func _as_float(d: Dictionary, key: String, fallback: float) -> float:
	var v = d.get(key, fallback)
	if v is float or v is int:
		return float(v)
	if v is String and v.is_valid_float():
		return v.to_float()
	return fallback

func _as_bool(d: Dictionary, key: String, fallback: bool) -> bool:
	var v = d.get(key, fallback)
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	return fallback

func _as_string(d: Dictionary, key: String, fallback: String) -> String:
	var v = d.get(key, fallback)
	return v if v is String else fallback

func _as_array(d: Dictionary, key: String, fallback: Array) -> Array:
	var v = d.get(key, fallback)
	return v if v is Array else fallback

func _as_dict(d: Dictionary, key: String, fallback: Dictionary) -> Dictionary:
	var v = d.get(key, fallback)
	return v if v is Dictionary else fallback

## Mode every store file is written with: owner read/write only.
##
## A store holds per-pane environments, shell commands and window geometry, and
## the umask decides the mode otherwise — a 0644 store in a `user://` directory
## another account can read exposes all of it. No-op on Windows.
const STORE_UNIX_MODE := 0x180  # 0600

## Suffix for the temp file the store is built in.
##
## The name is the protection, not a lock: GDScript's FileAccess has no
## `O_EXCL`, and `FileAccess.open(path, WRITE)` *follows a symlink*, so with a
## fixed `<store>.tmp` name anything able to write in `user://` could plant a
## link and have the next save write through it. 64 random bits cannot be
## pre-planted, so the temp file is created fresh every time.
##
## Overridden in tests that need the creation to fail deterministically.
func _temp_suffix() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()

## Read a text asset (not a JSON store). Empty when it is missing or
## unreadable; callers that need to distinguish the two own the check.
func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(resolve_store_path(path))

## Write a text asset atomically, owner-only on Unix. This is the text sibling
## of `_write_file`: stores hold JSON dictionaries, while a seeded vault is a
## tree of Markdown files. Returns false when the write could not land.
func _write_text(path: String, text: String) -> bool:
	var target := resolve_store_path(path)
	var tmp := "%s.%s.tmp" % [target, _temp_suffix()]
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[%s] cannot open %s for writing" % [name, tmp])
		return false
	f.store_string(text)
	f.close()
	FileAccess.set_unix_permissions(abs_tmp, STORE_UNIX_MODE)
	var err := DirAccess.rename_absolute(abs_tmp, ProjectSettings.globalize_path(target))
	if err == OK:
		return true
	# Same fallback as `_write_file`: a non-atomic write beats losing the file,
	# and the warning names it so the platform's rename limitation is visible.
	push_warning("[%s] atomic replace of %s failed (%d); writing directly" % [name, target, err])
	var direct := FileAccess.open(target, FileAccess.WRITE)
	if direct:
		direct.store_string(text)
		direct.close()
		FileAccess.set_unix_permissions(ProjectSettings.globalize_path(target), STORE_UNIX_MODE)
	DirAccess.remove_absolute(abs_tmp)
	return direct != null

func _write_file(path: String, data: Dictionary):
	# Write a sibling temp file and rename it into place. FileAccess.WRITE
	# truncates the target the moment it opens, so a crash or power loss
	# during the write leaves a partial or empty file — and _read_file treats
	# that as "no data", silently resetting settings, profiles, workspaces and
	# concepts at once. A rename either happens or does not, and it replaces
	# the target itself rather than writing through whatever a symlink at that
	# path points at.
	var text := JSON.stringify(data)
	var target := resolve_store_path(path)
	var tmp := "%s.%s.tmp" % [target, _temp_suffix()]
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[%s] cannot open %s for writing" % [name, tmp])
		return
	f.store_string(text)
	f.close()
	FileAccess.set_unix_permissions(abs_tmp, STORE_UNIX_MODE)
	var err := DirAccess.rename_absolute(abs_tmp, ProjectSettings.globalize_path(target))
	if err == OK:
		return
	# Some platforms refuse to replace an existing file by rename. Losing the
	# update would be worse than a non-atomic write, so fall back and say so.
	push_warning("[%s] atomic replace of %s failed (%d); writing directly" % [name, target, err])
	var direct := FileAccess.open(target, FileAccess.WRITE)
	if direct:
		direct.store_string(text)
		direct.close()
		FileAccess.set_unix_permissions(ProjectSettings.globalize_path(target), STORE_UNIX_MODE)
	DirAccess.remove_absolute(abs_tmp)
