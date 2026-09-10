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

func _write_file(path: String, data: Dictionary):
	# Write a sibling temp file and rename it into place. FileAccess.WRITE
	# truncates the target the moment it opens, so a crash or power loss
	# during the write leaves a partial or empty file — and _read_file treats
	# that as "no data", silently resetting settings, profiles, workspaces and
	# concepts at once. A rename either happens or does not.
	var text := JSON.stringify(data)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[%s] cannot open %s for writing" % [name, tmp])
		return
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)
	)
	if err == OK:
		return
	# Some platforms refuse to replace an existing file by rename. Losing the
	# update would be worse than a non-atomic write, so fall back and say so.
	push_warning("[%s] atomic replace of %s failed (%d); writing directly" % [name, path, err])
	var direct := FileAccess.open(path, FileAccess.WRITE)
	if direct:
		direct.store_string(text)
		direct.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
