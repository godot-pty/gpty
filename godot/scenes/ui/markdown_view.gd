class_name MarkdownView
extends RichTextLabel
## Shared, read-only Markdown renderer for Inspector, Reasoning, and code-viewer panes.
##
## Parsing happens in Rust. Streaming callers use set_markdown(), which
## coalesces rapid deltas; completed documents use render_now().
##
## The renderer caps its input at the same 1 MiB a pane reads under, so the
## view is the one place a reader learns that the screen holds less than the
## document: the render answer carries `truncated`/`shown`/`size`, and the view
## shows a notice above the body when that cap bit — plus the caller's own
## notice (`set_source_notice`) when *it* cut the source, which the renderer
## cannot know about.

const RENDER_DELAY := 0.075

## The scheme this renderer gives a `[[wikilink]]` mention when
## `wikilinks_enabled` is on. Only the view interprets it: it is announced as a
## click, never handed to `OS.shell_open`.
const INTERNAL_SCHEME := "gpty-note:"

## Render `[[target]]` / `[[target|alias]]` as internal links. Off by default —
## the vault vocabulary must not change how Inspector output, a reasoning turn
## or a code preview displays — and the wiki pane turns it on.
var wikilinks_enabled := false

## A `[[wikilink]]` mention was clicked, with its target decoded. The owning
## pane decides what the name means (the wiki pane resolves it against its
## vault); the view never resolves or opens anything itself.
signal note_link_clicked(target: String)

## How long an editor's buffer must be quiet before its preview renders — see
## `set_markdown_settled`. A var rather than a const so a test can shorten the
## window it is not testing (the pane's `_scratch_timer.wait_time` is poked
## the same way). Chosen to outlast the pauses *inside* a typing run: a
## preview update on a large document costs a full render plus the label's
## shape pass, so firing between words would put that cost back under the
## user's fingers.
var settle_delay := 0.4

## Emitted after a pending render is applied. Streaming owners (the Reasoning
## accordion) use it to re-sync layout once the coalesced text has landed.
signal rendered

var _renderer: RefCounted
var _render_timer: Timer
var _pending_markdown := ""
## The caller's own truncation notice (see `set_source_notice`).
var _source_notice := ""
## Wall-clock cost of the last applied render (Rust render + BBCode parse +
## append), read by the Reasoning pane's `GPTY_REASONING_DEBUG` line. The
## label's shape pass lands on the next frame and is not part of this number.
var last_render_usec := 0

func _ready():
	bbcode_enabled = true
	fit_content = false
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	selection_enabled = true
	# The right-click Copy / Select All menu: a selection is only useful if it
	# can be taken out of the pane.
	context_menu_enabled = true
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
	_render_timer.wait_time = RENDER_DELAY
	if _render_timer.is_stopped():
		_render_timer.start()

## An editor's buffer: render once the source *settles*.
##
## `set_markdown`'s timer is a throttle — an active timer is not restarted, so
## a long stream (a model's tokens) still renders regularly — while this
## restarts it on every call: nothing renders while typing continues, and one
## render lands when it stops. That is what a live preview of a large document
## wants, because the expensive thing is the render plus the label's shape
## pass, not the keystroke — see the module docs of `GptyMarkdown` for the
## measured shape cost of the markup that used to make it superlinear. The
## quiet window is [`settle_delay`].
func set_markdown_settled(markdown: String):
	_pending_markdown = markdown
	if _render_timer == null:
		return
	_render_timer.wait_time = settle_delay
	_render_timer.start()

func render_now(markdown: String):
	_pending_markdown = markdown
	if _render_timer != null:
		_render_timer.stop()
	if not is_node_ready():
		call_deferred("_apply_pending")
		return
	_apply_pending(false)

func clear_markdown():
	_pending_markdown = ""
	if _render_timer != null:
		_render_timer.stop()
	clear()

## Tell the view that the markdown it will be given is itself a prefix, and what
## to say about it — `TextRead.truncation_notice(cap, total)` from the caller's
## own read. A pane that read at its cap hands the notice here instead of
## appending it to the source: a source at the renderer's cap would push an
## appended notice past the cut, which is exactly the case it exists for.
##
## Applies from the next render (set it around `render_now`/`set_markdown`);
## the empty string clears it, and a render cut the renderer reports overrides
## it (the narrower claim — with the caps aligned the two cannot disagree).
func set_source_notice(notice: String) -> void:
	_source_notice = notice

func _apply_pending(from_timer := true):
	# A streaming re-render replaces the whole body, which drops whatever the
	# user has selected. While a selection is held, leave the pending text and
	# try again after the delay — the live view pauses under the user's cursor
	# instead of erasing it every RENDER_DELAY. Explicit `render_now` (opening
	# a note, a settled turn) is not deferred.
	if from_timer and get_selected_text() != "":
		if _render_timer != null:
			_render_timer.start()
		return
	var started := Time.get_ticks_usec()
	clear()
	# Fail soft: without the renderer the source is shown escaped, and a
	# caller-supplied notice still describes what is missing.
	var body := _pending_markdown.replace("[", "[lb]")
	var notice := _source_notice
	if _renderer != null and _renderer.has_method("render"):
		var answer = JSON.parse_string(str(_renderer.render(_pending_markdown, wikilinks_enabled)))
		if answer is Dictionary and answer.has("text"):
			body = str(answer["text"])
			if bool(answer.get("truncated", false)):
				notice = TextRead.truncation_notice(
					int(answer.get("shown", 0)), int(answer.get("size", 0))
				)
	if notice != "":
		# Our own line, never the document's: `truncation_notice` is
		# bracket-free, and this is the only BBCode the view wraps around text
		# it did not parse.
		append_text("[i]%s[/i]\n\n" % notice)
	append_text(body)
	last_render_usec = Time.get_ticks_usec() - started
	rendered.emit()

func _confirm_link(meta):
	var url := str(meta)
	if url.begins_with(INTERNAL_SCHEME):
		# A mention: the pane that owns the document resolves it. The scheme
		# holds a percent-encoded vault target (the renderer's encoding), so
		# decode before handing it over.
		note_link_clicked.emit(url.trim_prefix(INTERNAL_SCHEME).uri_decode())
		return
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
