class_name DocsViewer
extends VBoxContainer
## The Settings > About tab's documentation viewer.
##
## It shows one document from the bundled `res://docs.json` (see `DocsBundle`)
## through the same `MarkdownView` the Inspector, Reasoning, Code Viewer and
## Wiki panes use, and it is the only owner of the `gpty-doc:` links that view
## announces: a click opens the named document in place.
##
## Navigation is a `NavHistory` whose oldest entry is always `README.md`, so
## Back reaches the About tab's home page in a bounded number of steps whatever
## the trail's length. Back and Forward never push a step; following a link
## does, and the history's own cap (64) bounds both lists.
##
## The bundle loads on the first visit - when this control becomes visible
## (the Settings rail shows one section at a time), never at panel construction,
## which happens at application startup. A missing or malformed bundle is a
## sentence above an empty body, not a crash: the rest of Settings still works.
##
## The viewer is display-only. It reads `DocsBundle` and never joins a path,
## opens a file or writes anything; a link naming a document the build did not
## bundle is refused with a toast and the current page stays.

## The nav row's controls and the document, kept for the tests and for state.
var _view: MarkdownView = null
var _back: Button = null
var _forward: Button = null
var _path_label: Label = null
var _notice: Label = null
var _history := NavHistory.new(DocsBundle.ROOT_DOC)
## The document on screen; `""` until the first successful load.
var _current := ""
var _loaded := false

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", UiTokens.SPACE_SM)
	_build_nav()
	_build_body()
	_sync_nav()
	# The About tab is hidden while the panel is built, so this is normally a
	# no-op; it is what makes a bare viewer (a test, a future standalone use)
	# show its home page without waiting for a visibility change.
	if is_visible_in_tree():
		ensure_loaded()

func _notification(what: int):
	# The Settings rail shows one section at a time, so "About was opened"
	# arrives here as a visibility change. Guarded by `_view` because a control
	# can become visible while it is being added, before `_ready` built it.
	if what == NOTIFICATION_VISIBILITY_CHANGED and _view != null \
			and is_visible_in_tree() and not _loaded:
		ensure_loaded()

func _build_nav() -> void:
	var row := HBoxContainer.new()
	row.name = "NavRow"
	row.add_theme_constant_override("separation", UiTokens.SPACE_SM)
	add_child(row)

	_back = Button.new()
	_back.name = "Back"
	Icons.icon_button(_back, Icons.COLLAPSE, "Back")
	_back.tooltip_text = "Back to the previous page"
	_back.pressed.connect(_go_back)
	row.add_child(_back)

	_forward = Button.new()
	_forward.name = "Forward"
	Icons.icon_button(_forward, Icons.EXPAND, "Forward")
	_forward.tooltip_text = "Forward to the next page"
	_forward.pressed.connect(_go_forward)
	row.add_child(_forward)

	_path_label = Label.new()
	_path_label.name = "DocPath"
	_path_label.theme_type_variation = UiTheme.MUTED_LABEL
	_path_label.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_path_label)

func _build_body() -> void:
	_notice = Label.new()
	_notice.name = "DocNotice"
	_notice.theme_type_variation = UiTheme.MUTED_LABEL
	_notice.add_theme_font_size_override("font_size", UiTokens.FS_CAPTION)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.visible = false
	add_child(_notice)

	_view = MarkdownView.new()
	_view.name = "DocBody"
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.add_theme_font_size_override("normal_font_size", UiTokens.FS_BODY)
	_view.add_theme_font_size_override("mono_font_size", UiTokens.FS_BODY)
	_view.doc_links_enabled = true
	_view.doc_link_clicked.connect(_on_doc_link)
	add_child(_view)

## Load the bundle once and show its home page. Safe to call repeatedly; an
## error is shown in place of the document and keeps the viewer inert.
func ensure_loaded() -> void:
	if _loaded or _view == null:
		return
	_loaded = true
	var why := DocsBundle.ensure()
	if why != "":
		_notice.text = why
		_notice.visible = true
		_view.visible = false
		return
	_show(DocsBundle.ROOT_DOC, "")

## Open a bundled document. Answers false (and changes nothing) when the path
## is not in the bundle. Opening the page already on screen only scrolls to the
## fragment, so it adds no history step.
func open(path: String, fragment := "") -> bool:
	if _view == null:
		return false
	ensure_loaded()
	if not DocsBundle.has(path):
		return false
	if path == _current:
		if fragment != "":
			_view.scroll_to_heading(fragment)
		return true
	_history.push(path)
	_show(path, fragment)
	return true

func _show(path: String, fragment: String) -> void:
	_current = path
	_path_label.text = path
	_view.render_now(DocsBundle.text(path))
	if fragment != "":
		_view.scroll_to_heading(fragment)
	_sync_nav()

func _on_doc_link(path: String, fragment: String) -> void:
	if DocsBundle.has(path):
		open(path, fragment)
		return
	ToastManager.warn("That document is not bundled with this build: " + path)

func _go_back() -> void:
	if _history.can_back():
		_show(_history.back(), "")

func _go_forward() -> void:
	if _history.can_forward():
		_show(_history.forward(), "")

func _sync_nav() -> void:
	_back.disabled = not _history.can_back()
	_forward.disabled = not _history.can_forward()
