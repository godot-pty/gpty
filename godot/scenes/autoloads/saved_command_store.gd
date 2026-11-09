extends BasePersistenceManager
# SavedCommandStore — the user's own saved commands, in file order.
#
# `user://commands.json` is the only place a saved command lives:
#
#     {"commands": [{"name": "Build", "command": "cargo build", "run": false}]}
#
# A saved command is text, not authority: choosing one in the palette (or
# saving one in Settings → Commands) types its exact characters into the
# *active* terminal pane, and presses Enter only when its `run` flag is set —
# `run` is off by default, so the first action of a new entry is an insert the
# user can read before running. Nothing here reaches a spawn: startup commands
# are a profile/layout `launch` key, and this store is deliberately not one.
#
# The only writer is the settings UI (add / edit / delete / reorder), and the
# only reader is the palette's dispatcher, so a profile, layout, plugin or IPC
# call cannot add a command. The file is still hand-editable, so the loader is
# the same boundary as every other store: typed reads, sanitizing, a name
# uniqueness check and caps — a bad entry costs itself, not the file.

const COMMANDS_FILE := "user://commands.json"

## Caps, for the UI and for hand-edited file content.
const MAX_ENTRIES := 200
const MAX_NAME_CHARS := 64
const MAX_COMMAND_CHARS := 1024

var _entries: Array[Dictionary] = []

func _on_init():
	reload()

func reload():
	_entries = []
	var d := _read_file(COMMANDS_FILE)
	var raw := _as_array(d, "commands", [])
	# Case-insensitive, first one wins: a hand-edited file that repeats a name
	# must not produce two palette rows the dispatcher cannot tell apart.
	var seen := {}
	for item in raw:
		if _entries.size() >= MAX_ENTRIES:
			break
		if not (item is Dictionary):
			continue
		var name := clean_name(_as_string(item, "name", ""))
		var command := clean_command(_as_string(item, "command", ""))
		var key := name.to_lower()
		if name == "" or command == "" or seen.has(key):
			continue
		seen[key] = true
		_entries.append({
			"name": name,
			"command": command,
			"run": _as_bool(item, "run", false),
		})

## Every entry, in file order. Copied, so a caller (the palette, a test) can
## hold the list without mutating the store's own.
func all() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in _entries:
		out.append(entry.duplicate())
	return out

## The entry named exactly `name` (the palette's `saved: <name>` round trip),
## or {} when it is gone.
func find(name: String) -> Dictionary:
	for entry in _entries:
		if str(entry.get("name", "")) == name:
			return entry.duplicate()
	return {}

## Append one command. Returns "" when it was stored, else the sentence to
## show — the caller keeps its dialog open on a refusal.
func add(name: String, command: String, run := false) -> String:
	if _entries.size() >= MAX_ENTRIES:
		return "At most %d saved commands" % MAX_ENTRIES
	var clean_name_value := clean_name(name)
	var clean_command_value := clean_command(command)
	var problem := validation_error(clean_name_value, clean_command_value, _entries)
	if problem != "":
		return problem
	_entries.append({
		"name": clean_name_value,
		"command": clean_command_value,
		"run": run,
	})
	_save()
	return ""

## Replace entry `index` in place, keeping its position.
func update(index: int, name: String, command: String, run := false) -> String:
	if index < 0 or index >= _entries.size():
		return "That command is no longer in the list"
	var clean_name_value := clean_name(name)
	var clean_command_value := clean_command(command)
	# Skipping its own row is what lets an edit keep the name it already has.
	var problem := validation_error(clean_name_value, clean_command_value, _entries, index)
	if problem != "":
		return problem
	_entries[index] = {
		"name": clean_name_value,
		"command": clean_command_value,
		"run": run,
	}
	_save()
	return ""

func remove(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	_entries.remove_at(index)
	_save()

## Move entry `index` by `delta` places, clamped to the list. Returns its index
## afterwards (unchanged when nothing moved), so the UI can keep the row
## selected across the reorder.
func move(index: int, delta: int) -> int:
	if index < 0 or index >= _entries.size():
		return index
	var target := clampi(index + delta, 0, _entries.size() - 1)
	if target == index:
		return index
	var entry := _entries[index]
	_entries.remove_at(index)
	_entries.insert(target, entry)
	_save()
	return target

## A command is one line of shell text. LF, CR and TAB become one space each,
## so pasting a multi-line excerpt can never glue two commands together, and
## every other control character is dropped. Then the ends are trimmed and the
## cap is applied — in that order, so a command at the cap has no trailing
## whitespace.
static func clean_command(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var code := raw.unicode_at(i)
		if code == 0x09 or code == 0x0A or code == 0x0D:
			out += " "
			continue
		if code < 0x20 or code == 0x7F:
			continue
		out += raw[i]
	return out.strip_edges().left(MAX_COMMAND_CHARS)

## A name is a label, never a line: every control character is dropped instead
## of spaced, because a name reaching the palette row and the dispatcher's
## `saved: ` prefix has no line structure to preserve.
static func clean_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var code := raw.unicode_at(i)
		if code < 0x20 or code == 0x7F:
			continue
		out += raw[i]
	return out.strip_edges().left(MAX_NAME_CHARS)

## Why `name`/`command` cannot be stored beside `entries`, or "". Both values
## are expected to be cleaned already (the writers clean before asking).
## `skip_index` is the row an edit is replacing, which may keep its own name.
static func validation_error(name: String, command: String, entries: Array, skip_index := -1) -> String:
	if name == "":
		return "A saved command needs a name"
	if command == "":
		return "A saved command needs a command"
	var key := name.to_lower()
	var index := 0
	for item in entries:
		if index != skip_index and item is Dictionary:
			if str(item.get("name", "")).to_lower() == key:
				return "A saved command named '%s' already exists" % name
		index += 1
	return ""

func _save() -> void:
	_write_file(COMMANDS_FILE, {"commands": _entries})
