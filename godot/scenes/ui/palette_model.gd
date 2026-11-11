class_name PaletteModel
## What the command palette offers, as data: the pane types (one "new <type>"
## per registry entry), then the fixed workspace actions. `CommandPalette`
## renders these; `Workspace._execute_command` matches the `command` string.
##
## `command` is the stable id the workspace dispatches on and must never change
## for display reasons; `label` is the words the row shows (a row whose label
## is its command is not allowed: the palette used to present "close active"
## and "save" as if they were English).
##
## Saved commands are the user's own list, passed in by the caller: the model
## stays store-free, so a palette row can never be a command the UI did not
## hand it. Their entries carry a `section`, a `hint` and the `run` flag, which
## the fixed rows do not have.
##
## Pure: no scene tree, no store, no input. Adding a pane type to `PaneTypes.ALL`
## adds its row here automatically, and a command a caller appends must have a
## `_execute_command` arm in the workspace (the integration test scans for it).

## The dispatcher's prefix for a saved command: `saved: <name>` carries the
## name back exactly, so the workspace looks the entry up in the store instead
## of parsing anything else out of the row.
const SAVED_PREFIX := "saved: "
## The heading the palette draws once above the saved-command rows.
const SAVED_SECTION := "Saved commands"

## Action entries appended after the pane-type entries, in this order.
## glyph     - an `Icons` codepoint, "" when no existing icon means this action
## action    - the ShortcutManager action whose chord the row hints ("" = none)
## keywords  - extra lowercase words the filter matches
## variation - a `UiTheme` label role (destructive actions read as dangerous)
const ACTIONS: Array[Dictionary] = [
	{"command": "close active", "label": "Close Active Pane", "glyph": Icons.DELETE,
		"action": "app:close_pane", "keywords": "close kill active pane", "variation": &""},
	{"command": "settings", "label": "Open Settings", "glyph": Icons.SETTINGS,
		"action": "", "keywords": "settings preferences options appearance", "variation": &""},
	{"command": "shortcuts", "label": "Keyboard Shortcuts", "glyph": Icons.QUESTION,
		"action": "", "keywords": "shortcuts keys bindings help about", "variation": &""},
	{"command": "save command", "label": "Save Command\u2026", "glyph": Icons.ADD,
		"action": "", "keywords": "save command saved commands", "variation": &""},
	{"command": "close all", "label": "Close All Panes", "glyph": Icons.DELETE,
		"action": "app:reset_workspace", "keywords": "close all reset workspace panes",
		"variation": UiTheme.DANGER_LABEL},
	{"command": "save", "label": "Save Workspaces", "glyph": "",
		"action": "", "keywords": "save persist workspaces store disk", "variation": &""},
	{"command": "load", "label": "Reload Saved Workspaces", "glyph": "",
		"action": "", "keywords": "reload load restore workspaces disk",
		"variation": UiTheme.DANGER_LABEL},
]

## Every entry: one per registered pane type in registry order, then ACTIONS,
## then one per saved command in store order.
## A pane type's command keeps the exact spelling the workspace matches
## ("new " + lowercase display name); its glyph is the registry's own, and its
## `action` is the chord the workspace registers for it ("" when the type has
## no shortcut).
##
## `saved` holds the store's entries (`{name, command, run}`), already cleaned
## by the store: a row here is a label and a hint, never a second sanitizing
## step. Order is preserved, so the palette shows the order the user arranged.
static func entries(saved: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in PaneTypes.ALL:
		var info: Dictionary = PaneTypes.ALL[key]
		out.append({
			"command": "new " + str(info["name"]).to_lower(),
			"label": "New " + str(info["name"]),
			"glyph": str(info.get("icon", "")),
			"action": "app:new_" + str(key),
			"keywords": "new pane " + str(key).replace("_", " "),
			"variation": &"",
		})
	for entry in ACTIONS:
		out.append(entry.duplicate())
	for item in saved:
		if not (item is Dictionary):
			continue
		var name := str(item.get("name", ""))
		if name == "":
			continue
		var run := bool(item.get("run", false))
		out.append({
			"command": SAVED_PREFIX + name,
			"label": name,
			"glyph": "",
			"action": "",
			"keywords": "saved command insert run",
			"variation": &"",
			"section": SAVED_SECTION,
			"hint": "Run" if run else "Insert",
			"run": run,
		})
	return out

## The executable commands, in palette order.
static func commands(saved: Array = []) -> Array[String]:
	var out: Array[String] = []
	for entry in entries(saved):
		out.append(str(entry["command"]))
	return out

## Entries matching `query`, case-insensitively, best match first: a label
## prefix, then a label substring, then a command/keyword substring. Within a
## tier the model's order is kept (the pane types, then the actions, then the
## saved commands), so the cursor's first position after a keystroke is
## predictable and a name never reorders the list.
static func filter(query: String, saved: Array = []) -> Array[Dictionary]:
	var all := entries(saved)
	var q := query.strip_edges()
	if q == "":
		return all
	var out: Array[Dictionary] = []
	var taken := {}
	for tier in 3:
		for i in all.size():
			if taken.has(i):
				continue
			var entry: Dictionary = all[i]
			var hit := false
			match tier:
				0: hit = str(entry["label"]).findn(q) == 0
				1: hit = str(entry["label"]).findn(q) != -1
				_:
					hit = (str(entry["command"]).findn(q) != -1
						or str(entry["keywords"]).findn(q) != -1)
			if hit:
				out.append(entry)
				taken[i] = true
	return out
