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

## A `[[wikilink]]` mention was clicked: its target decoded, and the heading
## fragment it named (`[[target#heading]]`) or "" when it had none. The owning
## pane decides what the name means (the wiki pane resolves it against its
## vault and scrolls to the fragment); the view never resolves or opens
## anything itself.
signal note_link_clicked(target: String, fragment: String)

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
## What the label currently shows, so an identical render is skipped instead
## of replacing the body — opening a note schedules the editor's settled
## render a frame later, and that redundant pass used to land 0.4 s after a
## scroll and reset it to the top.
var _last_rendered := ""
var _last_wikilinks := false
var _last_notice := ""
## The caller's own truncation notice (see `set_source_notice`).
var _source_notice := ""
## A pending character offset to scroll to once the label has shaped its text
## (visual lines do not exist before the layout pass).
var _scroll_offset := -1
var _scroll_queued := false
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
	_last_rendered = ""
	_last_wikilinks = wikilinks_enabled
	_last_notice = ""
	_scroll_offset = -1

## Scroll the preview to the line whose text is `heading`, returning whether
## the rendered body contains such a line.
##
## The source scan (`MarkdownAnchors`) finds what a fragment means; this looks
## for that heading in the *rendered* text, so Markdown syntax and blank lines
## cannot make the source line and the visual line disagree. Matching is
## trimmed, exact first and case-insensitive second (Obsidian's fragments are
## case-insensitive). The actual scroll is queued: a `RichTextLabel` computes
## visual lines on its layout pass, one frame after the text lands, and
## `get_character_line` is -1 until then (measured on Godot 4.7.2 headless).
func scroll_to_heading(heading: String) -> bool:
	var needle := heading.strip_edges()
	if needle == "":
		return false
	var offset := _line_offset(get_parsed_text(), needle)
	if offset < 0:
		return false
	_queue_scroll(offset)
	return true

## Scroll to the position a 1-based *source* line derives: the last heading at
## or before it, or the top when it has none. Always answers true — a line
## without a heading is not a missing destination, it is a position with no
## better anchor than the start of the document.
func scroll_to_source_line(source: String, line: int) -> bool:
	var heading := MarkdownAnchors.nearest(source, line)
	if heading != "" and scroll_to_heading(heading):
		return true
	_queue_scroll(0)
	return true

## The character offset where the first line equal to `needle` starts, or -1.
func _line_offset(text: String, needle: String) -> int:
	var offset := 0
	var lower := needle.to_lower()
	var inexact := -1
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed == needle:
			return offset
		if inexact < 0 and trimmed.to_lower() == lower:
			inexact = offset
		offset += line.length() + 1
	return inexact

func _queue_scroll(offset: int) -> void:
	_scroll_offset = offset
	if _scroll_queued or not is_inside_tree():
		return
	_scroll_queued = true
	_apply_scroll()

func _apply_scroll() -> void:
	# One frame is what the layout pass needs; a second covers a label that
	# was still hidden when the request arrived. `_scroll_queued` stays set
	# across both, so a request arriving meanwhile only replaces the offset
	# and the latest one wins.
	for _attempt in 2:
		if get_character_line(0) >= 0:
			break
		if not is_inside_tree():
			return
		await get_tree().process_frame
	var offset := _scroll_offset
	_scroll_offset = -1
	_scroll_queued = false
	if offset < 0 or not is_inside_tree():
		return
	var line := get_character_line(offset)
	if line >= 0:
		scroll_to_line(line)

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
	# An identical render would replace the body for no visible change — and
	# a replacement resets the scroll, so the editor's settled render 0.4 s
	# after a note opens used to undo a fragment scroll.
	if _pending_markdown == _last_rendered \
			and wikilinks_enabled == _last_wikilinks \
			and _source_notice == _last_notice:
		return
	# A render replaces the text a pending scroll was computed for.
	_scroll_offset = -1
	var started := Time.get_ticks_usec()
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
		# it did not parse. One assignment rather than `clear()` +
		# `append_text()`: same parse, and the label's own `text` stays the
		# document (an `append_text` body is reachable only as parsed text).
		text = "[i]%s[/i]\n\n%s" % [notice, body]
	else:
		text = body
	_last_rendered = _pending_markdown
	_last_wikilinks = wikilinks_enabled
	_last_notice = _source_notice
	last_render_usec = Time.get_ticks_usec() - started
	rendered.emit()

func _confirm_link(meta):
	var url := str(meta)
	if url.begins_with(INTERNAL_SCHEME):
		# A mention: the pane that owns the document resolves it. The scheme
		# holds a percent-encoded vault target and, after one literal `#`, an
		# optional percent-encoded heading (the renderer's encoding) — decode
		# both before handing them over. The literal separator is unambiguous
		# because the encoder escapes a `#` inside either part.
		var payload := url.trim_prefix(INTERNAL_SCHEME)
		var hash := payload.find("#")
		var target := payload if hash < 0 else payload.left(hash)
		var fragment := "" if hash < 0 else payload.substr(hash + 1)
		note_link_clicked.emit(target.uri_decode(), fragment.uri_decode())
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
