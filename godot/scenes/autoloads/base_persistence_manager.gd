class_name BasePersistenceManager
extends Node

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_on_init()

func _on_init():
	pass

func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f = FileAccess.open(path, FileAccess.READ)
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

func _write_file(path: String, data: Dictionary):
	# Write a sibling temp file and rename it into place. FileAccess.WRITE
	# truncates the target the moment it opens, so a crash or power loss
	# during the write leaves a partial or empty file — and _read_file treats
	# that as "no data", silently resetting settings, profiles, workspaces and
	# concepts at once. A rename either happens or does not, and it replaces
	# the target itself rather than writing through whatever a symlink at that
	# path points at.
	var text := JSON.stringify(data)
	var tmp := "%s.%s.tmp" % [path, _temp_suffix()]
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[%s] cannot open %s for writing" % [name, tmp])
		return
	f.store_string(text)
	f.close()
	FileAccess.set_unix_permissions(abs_tmp, STORE_UNIX_MODE)
	var err := DirAccess.rename_absolute(abs_tmp, ProjectSettings.globalize_path(path))
	if err == OK:
		return
	# Some platforms refuse to replace an existing file by rename. Losing the
	# update would be worse than a non-atomic write, so fall back and say so.
	push_warning("[%s] atomic replace of %s failed (%d); writing directly" % [name, path, err])
	var direct := FileAccess.open(path, FileAccess.WRITE)
	if direct:
		direct.store_string(text)
		direct.close()
		FileAccess.set_unix_permissions(ProjectSettings.globalize_path(path), STORE_UNIX_MODE)
	DirAccess.remove_absolute(abs_tmp)
