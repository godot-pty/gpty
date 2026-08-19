class_name MarkdownView
extends RichTextLabel
## Shared, read-only Markdown renderer for Inspector, Reasoning, and code-viewer panes.
##
## Parsing happens in Rust. Streaming callers use set_markdown(), which
## coalesces rapid deltas; completed documents use render_now().

const RENDER_DELAY := 0.075

var _renderer: RefCounted
var _render_timer: Timer
var _pending_markdown := ""

func _ready():
	bbcode_enabled = true
	fit_content = false
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	selection_enabled = true
	# Static documents start at the top; streaming owners opt in.
	scroll_following = false

	_render_timer = Timer.new()
	_render_timer.one_shot = true
	_render_timer.wait_time = RENDER_DELAY
	_render_timer.timeout.connect(_apply_pending)
	add_child(_render_timer)

	_renderer = ClassDB.instantiate("GptyMarkdown")
	if _renderer == null or not _renderer.has_method("render"):
		push_error("GptyMarkdown unavailable; rebuild gpty-gdext and restart Godot")

	meta_clicked.connect(_confirm_link)

func configure_for_accordion():
	scroll_active = false
	# fit_content would force min width to the widest unwrapped line,
	# defeating word wrap at narrow pane widths. The accordion assigns
	# width; the owner syncs height from get_content_height().
	fit_content = false
	scroll_following = false

func set_markdown(markdown: String):
	_pending_markdown = markdown
	if _render_timer == null:
		return
	# Throttle rapid streaming updates; restarting an active timer would never render.
	if _render_timer.is_stopped():
		_render_timer.start()

func render_now(markdown: String):
	_pending_markdown = markdown
	if _render_timer != null:
		_render_timer.stop()
	if not is_node_ready():
		call_deferred("_apply_pending")
		return
	_apply_pending()

func clear_markdown():
	_pending_markdown = ""
	if _render_timer != null:
		_render_timer.stop()
	clear()

func _apply_pending():
	clear()
	if _renderer != null and _renderer.has_method("render"):
		append_text(str(_renderer.render(_pending_markdown)))
	else:
		append_text(_pending_markdown.replace("[", "[lb]"))

func _confirm_link(meta):
	var url := str(meta)
	if not (url.begins_with("https://") or url.begins_with("http://") or url.begins_with("mailto:")):
		return
	var dialog = ConfirmationDialog.new()
	dialog.title = "Open external link?"
	dialog.dialog_text = url
	add_child(dialog)
	dialog.confirmed.connect(func():
		OS.shell_open(url)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()
