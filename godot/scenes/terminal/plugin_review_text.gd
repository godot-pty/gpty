class_name PluginReviewText
## Pure builder for the plugin-install review dialog text, extracted from
## workspace.gd for testability. The summary's strings are untrusted file
## content from the repo being cloned — every field is capped and control
## characters are stripped, so a hostile manifest cannot shape the dialog
## (spoof a line, bloat it, or inject newlines). The dialog is display only:
## the verdict (accepted/declined) is the single output, and nothing here
## executes.

const MAX_LINES := 40
const MAX_FIELD := 96
const MAX_LISTED := 8
## Programs listed per profile before an ellipsis (the CLI caps its own list too).
const MAX_PROGRAMS_SHOWN := 8


static func build(params: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("Plugin: %s (%s)" % [field(params, "name", 64), field(params, "id", 64)])
	lines.append("Version %s  ·  revision %s" % [field(params, "version", 16), field(params, "revision", 64)])
	# The ref the user named on the command line (a tag, branch, or commit
	# SHA — "default branch" for a bare install), resolved to the pinned
	# revision above.
	lines.append("Requested: %s" % field(params, "requested_ref", 96))
	lines.append("Source: %s" % field(params, "source", 96))

	var actions: Array = params.get("actions", [])
	if actions is Array and not actions.is_empty():
		lines.append("")
		lines.append("Actions (gpty CLI commands this plugin can run):")
		var shown := 0
		for entry in actions:
			if shown >= MAX_LISTED or lines.size() >= MAX_LINES:
				break
			if entry is Dictionary:
				var args: Dictionary = entry.get("args", {})
				var arg_text := ""
				if args is Dictionary and not args.is_empty():
					var parts: Array = []
					for key in args:
						parts.append("%s=%s" % [short(str(key), 32), short(str(args[key]), 64)])
					arg_text = " " + " ".join(parts)
				lines.append("  %s: gpty %s%s" % [
					field(entry, "name", 32),
					field(entry, "command", 32),
					arg_text,
				])
				shown += 1
		if shown < actions.size():
			lines.append("  … %d more" % (actions.size() - shown))

	var events: Array = params.get("events", [])
	if events is Array and not events.is_empty():
		lines.append("")
		lines.append("Listens for:")
		var shown_events := 0
		for entry in events:
			if shown_events >= MAX_LISTED or lines.size() >= MAX_LINES:
				break
			if entry is Dictionary:
				lines.append("  %s → %s" % [field(entry, "name", 32), field(entry, "type", 48)])
				shown_events += 1
		if shown_events < events.size():
			lines.append("  … %d more" % (events.size() - shown_events))

	var link_handlers: Array = params.get("link_handlers", [])
	if link_handlers is Array and not link_handlers.is_empty():
		lines.append("")
		lines.append("Link handlers:")
		for entry in link_handlers:
			if lines.size() >= MAX_LINES:
				break
			if entry is Dictionary:
				lines.append("  %s:// → %s" % [
					field(entry, "scheme", 32),
					argv_text(entry.get("command", [])),
				])

	var build_cmd: Array = params.get("build", [])
	if build_cmd is Array and not build_cmd.is_empty():
		lines.append("")
		lines.append("Build command (declared, not run at install): %s" % argv_text(build_cmd))
	var startup_cmd: Array = params.get("startup", [])
	if startup_cmd is Array and not startup_cmd.is_empty():
		lines.append("Startup command (declared, not run at install): %s" % argv_text(startup_cmd))

	# A summary field of the wrong type must not abort the whole dialog: an
	# empty consent dialog is worse than a missing count. Measured while
	# staging a capture — an Array here raised "Nonexistent 'int' constructor"
	# and every line built before it was discarded, so the user was asked to
	# approve a plugin with no information at all.
	var concept_count := _as_int(params.get("concepts", 0))
	var profiles: Array = params.get("profiles", [])
	if concept_count > 0 or (profiles is Array and not profiles.is_empty()):
		lines.append("")
		if concept_count > 0:
			lines.append("Concepts: %d" % concept_count)
		if profiles is Array and not profiles.is_empty():
			lines.append("Profiles -- what each one would start:")
			for entry in profiles:
				if lines.size() >= MAX_LINES:
					break
				if entry is Dictionary:
					lines.append("  %s: %s" % [
						field(entry, "name", 32),
						programs_text(entry.get("programs", [])),
					])

	if lines.size() > MAX_LINES:
		lines.resize(MAX_LINES)
		lines.append("… more not shown")
	lines.append("")
	lines.append("Installing grants this plugin the workspace API — its actions run as you through the gpty CLI. Nothing has executed yet.")
	return "\n".join(lines)


## What a profile's tiles would start, as one capped line.
##
## This is the line that makes the review informed consent rather than a name:
## a profile the user approves here is one `_profile_consented` later activates
## at the pinned revision, and the programs are what the Workspace Trust plan
## key is derived from. A summary without it (an older CLI, a plugin whose
## tiles are pure geometry) says so instead of showing nothing.
static func programs_text(raw: Variant) -> String:
	if not raw is Array or raw.is_empty():
		return "no program (layout only)"
	var parts: Array = []
	for i in mini(raw.size(), MAX_PROGRAMS_SHOWN):
		parts.append(short(str(raw[i]), 64))
	if raw.size() > MAX_PROGRAMS_SHOWN:
		parts.append("…")
	return "starts " + ", ".join(parts)


## A summary field read as an int, or 0 when it is not a number at all.
static func _as_int(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	return 0


## One capped, control-character-free string from a summary field.
static func field(entry: Dictionary, key: String, cap_len: int) -> String:
	return short(str(entry.get(key, "")), cap_len)


static func short(text: String, cap_len: int) -> String:
	var out := ""
	for i in text.length():
		var ch := text[i]
		if ch.unicode_at(0) < 32:
			continue
		out += ch
		if out.length() >= cap_len:
			break
	return out


## An argv array shown as one capped line: a few entries, then an ellipsis.
static func argv_text(argv: Variant, cap_entries := 4) -> String:
	if not argv is Array or argv.is_empty():
		return ""
	var parts: Array = []
	for i in mini(argv.size(), cap_entries):
		parts.append(short(str(argv[i]), 64))
	if argv.size() > cap_entries:
		parts.append("…")
	return " ".join(parts)
