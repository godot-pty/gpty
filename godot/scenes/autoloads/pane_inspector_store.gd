extends BasePersistenceManager
# PaneInspectorStore — the user's own Inspector aim, keyed by attachment_id.
#
# `user://pane_inspector.json` holds the three Inspector settings a *file* must
# never supply: `system_prompt`, `auto_run` and `accept_concept_captures`.
# `PaneTypes.INSPECTOR_SETTINGS` marks them `file: false`, so a profile, layout
# or workspace file cannot aim the pane; they are preferences the user sets in
# the pane settings panel, and this store is where they outlive the session.
#
# The shape is one record per pane id:
#
#   {"pane-id": {"system_prompt": "…", "auto_run": true,
#                "accept_concept_captures": false}}
#
# Written only by the pane settings UI's apply path (the workspace's
# `settings_applied` handler), read by `InspectorPane.apply_user_state` when
# the pane is attached. It follows the `PaneEnvStore` lifecycle: keyed by the
# public id, moved when the user renames the pane, copied when a duplicate id
# is renamed, and never taken from a layout or profile — so an entry is the
# user's own gesture, not file content.
#
# The file is hand-editable like every store, so the loader is the same
# boundary: an id-pattern key check, strict field types, a prompt cap, an entry
# cap, and one bad entry costs itself, not the file.

const STATE_FILE := "user://pane_inspector.json"

## Caps for hand-edited file content. The prompt cap mirrors `text`'s `max`
## for `system_prompt` in `PaneTypes.INSPECTOR_SETTINGS`.
const MAX_ENTRIES := 128
const MAX_PROMPT_CHARS := 65536

var _states: Dictionary = {}

func _on_init():
	reload()

func reload():
	_states = {}
	var d = _read_file(STATE_FILE)
	for key in d:
		if not (key is String) or not _valid_id(key):
			continue
		if _states.size() >= MAX_ENTRIES:
			break
		var entry = d[key]
		if not (entry is Dictionary):
			continue
		var prompt := ""
		if entry.has("system_prompt"):
			if not (entry["system_prompt"] is String):
				continue
			prompt = entry["system_prompt"]
			if prompt.length() > MAX_PROMPT_CHARS:
				prompt = prompt.left(MAX_PROMPT_CHARS)
		var auto_run := false
		if entry.has("auto_run"):
			if not (entry["auto_run"] is bool):
				continue
			auto_run = entry["auto_run"]
		var accept := false
		if entry.has("accept_concept_captures"):
			if not (entry["accept_concept_captures"] is bool):
				continue
			accept = entry["accept_concept_captures"]
		# An all-default entry is absence: `set_state` removes it there, and a
		# hand-edited one has nothing to restore.
		if prompt == "" and not auto_run and not accept:
			continue
		_states[key] = {
			"system_prompt": prompt,
			"auto_run": auto_run,
			"accept_concept_captures": accept,
		}

## The pane's stored aim, or {} when it has none. A copy: the caller applies
## fields, it does not edit the store.
func state_for(id: String) -> Dictionary:
	var state = _states.get(id)
	return state.duplicate() if state is Dictionary else {}

func has_state(id: String) -> bool:
	return _states.has(id)

## The pane settings UI's write path. Returning a pane to its defaults (no
## prompt, auto-send off, captures off) removes the entry, so the store only
## carries decisions the user actually made.
func set_state(id: String, system_prompt: String, auto_run: bool, accept_concept_captures: bool):
	if not _valid_id(id):
		return
	var prompt := system_prompt
	if prompt.length() > MAX_PROMPT_CHARS:
		prompt = prompt.left(MAX_PROMPT_CHARS)
	if prompt == "" and not auto_run and not accept_concept_captures:
		remove_state(id)
		return
	_states[id] = {
		"system_prompt": prompt,
		"auto_run": auto_run,
		"accept_concept_captures": accept_concept_captures,
	}
	_write_file(STATE_FILE, _states)

func remove_state(id: String):
	if _states.has(id):
		_states.erase(id)
		_write_file(STATE_FILE, _states)

## Carry a record to a new id without disturbing the old one: a duplicate-id
## rename creates a second instance of the same logical pane, and the first
## instance keeps its entry (the `PaneEnvStore` rule). An existing record at
## the new id wins — it belongs to the other pane.
func copy_state(old_id: String, new_id: String):
	if old_id == "" or new_id == "" or old_id == new_id:
		return
	if not _states.has(old_id) or _states.has(new_id):
		return
	_states[new_id] = (_states[old_id] as Dictionary).duplicate()
	_write_file(STATE_FILE, _states)

## Follow a user rename: the pane's aim moves to the id it now carries.
func move_state(old_id: String, new_id: String):
	if old_id == "" or new_id == "" or old_id == new_id:
		return
	if not _states.has(old_id):
		return
	var state: Dictionary = _states[old_id]
	_states.erase(old_id)
	_states[new_id] = state
	_write_file(STATE_FILE, _states)

## attachment_id shape — the same `[a-z][a-z0-9_-]{0,31}` the pane sanitizer
## enforces, so an entry can never outlive the ids the panes actually carry.
static func _valid_id(id: String) -> bool:
	var re := RegEx.create_from_string("^[a-z][a-z0-9_-]{0,31}$")
	return re.search(id) != null
