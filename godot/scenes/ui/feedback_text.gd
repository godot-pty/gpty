class_name FeedbackText
## The sidebar's Feedback row: the issue title and body it prefills, and the URL
## that carries them. Pure, so the privacy and length contract is testable
## without a browser: `body` takes four strings and nothing else, so no pane
## output, command, captured text, path, environment value or log can reach the
## form.

const ISSUE_URL := "https://github.com/godot-pty/gpty/issues/new"
## The bug form's own prefix, so a prefilled issue reads like a filed one.
const TITLE_PREFIX := "Feedback: "
## The whole URL, not just the query: GitHub answers 414 above its limit and a
## browser truncates silently, so the body is trimmed to fit.
const MAX_URL := 8000
const MAX_FIELD := 96
const TRUNCATED := "\n\n[truncated by gPTY]"
## What `trimmed` measures its budget against; the marker also splits a body
## into its editable prompts and its build block, which must survive a cut.
const BLOCK_MARKER := "\n\n---\nAbout this build\n"

## The prefilled issue body. The three prompts come first so the editor's
## cursor starts where the user types; the build block is last and every field
## is one line, so an odd `OS.get_version()` cannot shape the form's structure.
static func body(about: Dictionary) -> String:
	var prompts := PackedStringArray([
		"What happened:",
		"",
		"What I expected:",
		"",
		"Steps to reproduce:",
		"1.",
		"2.",
		"3.",
	])
	var os_line := "- %s %s" % [
		_line(about, "os", "unknown OS"), _line(about, "os_version", "")]
	var block := PackedStringArray([
		"- gPTY %s" % _line(about, "version", "unknown"),
		os_line.strip_edges(),
		"- Window: %s" % _line(about, "window_mode", "unknown"),
	])
	return trimmed("\n".join(prompts) + BLOCK_MARKER + "\n".join(block))

## The URL the browser opens: the blank issue editor, because a YAML issue form
## ignores the generic `body=` parameter (it prefills its own field ids), and
## the body is what carries the build facts. No `labels=`, `assignees=`,
## `template=` or `projects=`: the first two are dropped for users without write
## access, and `template=` would route into a form that discards the body.
static func url(about: Dictionary) -> String:
	return _url_of(body(about))

## `raw` when the URL it produces fits GitHub's limit, otherwise the same body
## cut down to fit with `TRUNCATED` at the end. The build block is kept whole:
## the cut only ever removes the tail of the prompts above it (§1.3's field caps
## normally keep the body far under the limit, so this is the guard, not the
## path).
static func trimmed(raw: String) -> String:
	var budget: int = MAX_URL - _url_head().length()
	if raw.uri_encode().length() <= budget:
		return raw
	var parts := raw.split(BLOCK_MARKER, false, 1)
	var head: String = parts[0] if parts.size() > 0 else ""
	var block: String = parts[1] if parts.size() > 1 else ""
	var block_cost := block.uri_encode().length() + BLOCK_MARKER.uri_encode().length() \
		+ TRUNCATED.uri_encode().length()
	head = _fit(head, budget - block_cost).strip_edges()
	var out := head + (BLOCK_MARKER + block if not block.is_empty() else "")
	out = out.strip_edges(false, true) + TRUNCATED
	# The field caps keep a real body far under the limit, so this only fires if
	# those caps are raised: never hand out a URL the server answers 414 for.
	return _fit(out, budget) if out.uri_encode().length() > budget else out

## The longest prefix of `text` whose encoded form fits `limit` characters.
## Encoding cost per character varies (`+` and spaces differ), so the fit is
## found by bisection over a monotone length rather than by encoding every cut.
static func _fit(text: String, limit: int) -> String:
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if text.substr(0, mid).uri_encode().length() <= limit:
			lo = mid
		else:
			hi = mid - 1
	return text.substr(0, lo)

## One build-block value: control characters folded to spaces (a newline in a
## version string would otherwise forge a second block line), edges stripped, a
## placeholder when empty, and a hard cap with an ellipsis.
static func _line(about: Dictionary, key: String, fallback: String) -> String:
	var text := str(about.get(key, ""))
	var out := ""
	for i in text.length():
		var c := text.unicode_at(i)
		out += (" " if (c < 0x20 or c == 0x7f) else String.chr(c))
	out = out.strip_edges()
	if out.is_empty():
		return fallback
	if out.length() > MAX_FIELD:
		return out.substr(0, MAX_FIELD - 1) + "\u2026"
	return out

static func _url_head() -> String:
	return ISSUE_URL + "?title=" + TITLE_PREFIX.uri_encode() + "&body="

static func _url_of(raw: String) -> String:
	return _url_head() + raw.uri_encode()
