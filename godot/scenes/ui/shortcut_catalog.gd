class_name ShortcutCatalog
## The Settings > About keyboard-shortcut list, as data. Chords are never
## literals here: `rows` takes the registry reader, so a rebound action prints
## the chord it actually has and an unbound one drops out of the list instead of
## claiming a key that does nothing.
##
## Pure - no scene tree, no InputMap. `PaneTypes` is the only dependency, which
## is why the "New panes" group cannot drift from the pane registry.
##
## Order is the reading order: what acts on the workspace, how panes are created,
## what acts on a pane, how the keyboard reaches a pane, and what the terminal
## itself owns.

## `from_registry` marks the group `new_pane_entries()` fills from
## `PaneTypes.ALL` (the types that declare a spawn shortcut).
const GROUPS: Array[Dictionary] = [
	{"title": "Workspace", "entries": [
		{"action": "app:toggle_palette", "label": "Command palette"},
		{"action": "app:toggle_sidebar", "label": "Show or hide the sidebar"},
		{"action": "app:next_workspace", "label": "Next workspace"},
		{"action": "app:prev_workspace", "label": "Previous workspace"},
		{"action": "app:toggle_fullscreen", "label": "Toggle fullscreen"},
		{"action": "app:toggle_fullscreen_alt", "label": "Toggle fullscreen (second binding)"},
		{"action": "app:reset_workspace", "label": "Close all panes in this workspace"},
	]},
	{"title": "New Panes", "from_registry": true},
	{"title": "Panes", "entries": [
		{"action": "app:close_pane", "label": "Close the active pane"},
		{"action": "app:focus_pane_chrome", "label": "Focus the active pane's toolbar"},
		{"action": "app:focus_note_toolbar", "label": "Focus the wiki note toolbar"},
	]},
	{"title": "Keyboard Focus", "entries": [
		{"action": "focus:left", "label": "Focus the pane to the left"},
		{"action": "focus:right", "label": "Focus the pane to the right"},
		{"action": "focus:up", "label": "Focus the pane above"},
		{"action": "focus:down", "label": "Focus the pane below"},
	]},
	{"title": "Terminal", "entries": [
		{"action": "term:search", "label": "Open the scrollback search bar"},
		{"action": "term:copy", "label": "Copy the selection"},
		{"action": "term:paste", "label": "Paste the clipboard"},
	]},
]

## The "New panes" group: one entry per pane type that declares a spawn
## shortcut. The chord is read from the registry later, so a type whose binding
## was never registered drops out in `rows`.
static func new_pane_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in PaneTypes.ALL:
		var info: Dictionary = PaneTypes.ALL[key]
		if str(info.get("shortcut", "")).strip_edges() == "":
			continue
		out.append({"action": "app:new_" + str(key), "label": "New %s pane" % info["name"]})
	return out

## The groups with their entries, the registry group materialized in place.
static func groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for group in GROUPS:
		var entries: Array = new_pane_entries() if group.get("from_registry", false) == true else group["entries"]
		out.append({"title": str(group["title"]), "entries": entries})
	return out

## Flat rows in reading order: `{group, label, chord}`, one per bound action.
## `chord_of` is the registry reader (`ShortcutManager.chord`); an action it
## answers `""` for is omitted, so a group with no bindings contributes no
## heading either.
static func rows(chord_of: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for group in groups():
		for entry in group["entries"]:
			var chord := str(chord_of.call(str(entry["action"])))
			if chord == "":
				continue
			out.append({"group": str(group["title"]), "label": str(entry["label"]), "chord": chord})
	return out
