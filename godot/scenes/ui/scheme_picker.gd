class_name SchemePicker
extends OptionButton
## One colour-scheme chooser: the library's schemes, an empty slot with the
## caller's own wording, and an Import entry.
##
## The first item is the reset - `(built-in palette)` for a global slot,
## `(follow Settings)` for a pane - so the row needs no separate reset button.
## A stored path that is not in the library (an old `settings.json` value)
## keeps a `(custom)` entry rather than silently showing the built-in palette.
##
## `setup` is safe before the node enters the tree: it connects the signal once
## and fills the items, and `select_path` moves the selection without emitting,
## so a caller restores a value without re-saving it.

signal scheme_chosen(path: String)

const IMPORT_ITEM := "Import scheme file…"

var _empty_label := "(built-in palette)"
var _current := ""

func setup(current: String, empty_label: String) -> void:
	_empty_label = empty_label
	_current = current
	if not item_selected.is_connected(_on_item_selected):
		item_selected.connect(_on_item_selected)
	_refresh()

## Move the selection to `path` without emitting `scheme_chosen`.
func select_path(path: String) -> void:
	_current = path
	_sync()

func get_selected_path() -> String:
	return _current

func _refresh() -> void:
	clear()
	add_item(_empty_label)
	set_item_metadata(item_count - 1, "")
	for entry in SchemeLibrary.list():
		add_item(str(entry.label))
		set_item_metadata(item_count - 1, str(entry.path))
	if _current != "" and not _has_path(_current):
		add_item("%s (custom)" % _current.get_file())
		set_item_metadata(item_count - 1, _current)
	add_separator()
	add_item(IMPORT_ITEM)
	set_item_metadata(item_count - 1, null)
	_sync()

func _sync() -> void:
	for index in item_count:
		var meta = get_item_metadata(index)
		if meta is String and str(meta) == _current:
			selected = index
			return
	selected = 0

func _has_path(path: String) -> bool:
	for index in item_count:
		var meta = get_item_metadata(index)
		if meta is String and str(meta) == path:
			return true
	return false

func _on_item_selected(index: int) -> void:
	var meta = get_item_metadata(index)
	if meta == null:
		_import()
		return
	_current = str(meta)
	scheme_chosen.emit(_current)

func _import() -> void:
	var dlg := AppDialog.picker(self, "Import colour scheme", FileDialog.FILE_MODE_OPEN_FILE)
	dlg.add_filter("*.json, *.toml, *.yaml, *.yml, *.itermcolors, *.txt, *.csv", "Colour schemes")
	dlg.file_selected.connect(func(path: String):
		var result := SettingsManager.import_scheme(path)
		dlg.queue_free()
		if result.get("ok", false):
			_current = str(result.get("path", ""))
			_refresh()
			scheme_chosen.emit(_current)
		else:
			# A refusal the user cannot see is a control that did nothing.
			var alert := AppDialog.alert(self, "Colour scheme not imported")
			AppDialog.set_text(alert, str(result.get("error", "")))
			AppDialog.popup(alert)
			alert.confirmed.connect(alert.queue_free)
			_sync())
	dlg.canceled.connect(func():
		dlg.queue_free()
		_sync())
	AppDialog.popup(dlg)
