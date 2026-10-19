class_name MarkdownAnchors
extends RefCounted
## Heading anchors for source-line navigation in a note's preview.
##
## A `[[note#heading]]` fragment names a heading by its text, and a link-panel
## row names a 1-based *source* line. Neither is a rendered line: the preview
## is BBCode whose blank lines and Markdown syntax do not line up with the
## file. The pane's two navigation decisions therefore work in two steps — the
## source scan here finds the heading a fragment (or a source line) means, and
## `MarkdownView` finds that heading's text in what is actually on screen.
##
## This scanner is deliberately the same shape as the index's link parser: a
## leading YAML frontmatter block is skipped, and a fenced code block's `#` is
## literal text, so a note documenting Markdown cannot grow anchors. It is
## presentation only — nothing here resolves a note, reads a file, or executes
## anything, and a heading text is only ever compared with text a caller
## already holds.

## ATX headings in source order: `[{line: int, text: String}]`, 1-based lines.
##
## Setext headings (`Title` over `===`) are not recognized: the preview still
## shows them, but no fragment or source line derives an anchor from one. The
## notes this pane edits are Obsidian-shaped, where ATX is the vocabulary.
static func headings(source: String) -> Array:
	var out: Array = []
	var lines := source.split("\n")
	var index := 0
	# A leading `---`…`---`/`...` block is properties, not content. An
	# unterminated `---` is not frontmatter (it may be a rule), the same rule
	# `gpty_core::vault::note_title` applies.
	if lines.size() > 0 and lines[0].strip_edges() == "---":
		var close := 1
		while close < lines.size():
			var marker := lines[close].strip_edges()
			if marker == "---" or marker == "...":
				break
			close += 1
		if close < lines.size():
			index = close + 1
	var fence := ""
	var fence_length := 0
	while index < lines.size():
		var line := str(lines[index]).trim_suffix("\r")
		if fence != "":
			var trimmed := line.strip_edges()
			if trimmed.length() >= fence_length and trimmed == fence.repeat(trimmed.length()):
				fence = ""
			index += 1
			continue
		var opened := _opens_fence(line)
		if opened.size() == 2:
			fence = str(opened[0])
			fence_length = int(opened[1])
			index += 1
			continue
		var heading := _atx_heading(line)
		if heading != "":
			out.append({"line": index + 1, "text": heading})
		index += 1
	return out

## The text of the last heading at or before `line` (1-based), or "".
##
## A source line with no heading above it has no anchor; the caller scrolls to
## the top, which is that line's nearest derived position.
static func nearest(source: String, line: int) -> String:
	if line <= 0:
		return ""
	var found := ""
	for heading in headings(source):
		if int(heading["line"]) > line:
			break
		found = str(heading["text"])
	return found

## The 1-based source line of the heading `text` names, or 0.
##
## Exact text first, then a case-insensitive match (Obsidian's fragment
## matching is case-insensitive); several matches resolve to the first, which
## is deterministic and inside one document, unlike a note-stem ambiguity.
static func find(source: String, text: String) -> int:
	var needle := text.strip_edges()
	if needle == "":
		return 0
	var scanned := headings(source)
	for heading in scanned:
		if str(heading["text"]) == needle:
			return int(heading["line"])
	var lower := needle.to_lower()
	for heading in scanned:
		if str(heading["text"]).to_lower() == lower:
			return int(heading["line"])
	return 0

## `[marker, length]` when this line opens a fenced code block, else `[]`.
##
## Same test as the index's link parser: a run of three or more backticks or
## tildes after optional leading whitespace. A note is not a conformance
## suite, so the info string and indentation rules stay approximate.
static func _opens_fence(line: String) -> Array:
	var trimmed := line.lstrip(" \t")
	if trimmed.is_empty():
		return []
	var marker := trimmed.substr(0, 1)
	if marker != "`" and marker != "~":
		return []
	var length := 0
	while length < trimmed.length() and trimmed[length] == marker:
		length += 1
	if length < 3:
		return []
	return [marker, length]

## The heading text when `line` is an ATX heading, else "".
static func _atx_heading(line: String) -> String:
	var index := 0
	while index < line.length() and index < 4 and line[index] == " ":
		index += 1
	if index > 3:
		return ""
	var level := 0
	while index + level < line.length() and line[index + level] == "#":
		level += 1
	if level < 1 or level > 6:
		return ""
	var after := index + level
	if after < line.length() and line[after] != " " and line[after] != "\t":
		return ""
	var text := line.substr(after).strip_edges()
	# A closing run of `#` is syntax only when whitespace separates it from
	# the text: `# C#` keeps its sharp, `## Part ##` loses the decoration.
	if text.ends_with("#"):
		var base := text.rstrip("#")
		if base.is_empty() or base.ends_with(" ") or base.ends_with("\t"):
			text = base.strip_edges()
	return text
