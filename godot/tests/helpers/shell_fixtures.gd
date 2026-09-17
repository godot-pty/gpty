class_name ShellFixtures
# Command lines for tests that need a real child process to emit exact bytes.
#
# Some contracts are about bytes reaching the grid from the *child* side — a
# concept declaration, a DECSET mode — and the shell cannot be the thing that
# prints them: an interactive shell's readline sets bracketed paste by itself,
# and cmd.exe has no `printf`. So the command line is built per platform and the
# test never branches on the platform itself.
#
# POSIX: `printf '%b'` with octal escapes, so any byte can be emitted without
# quoting hazards.
# Windows: PowerShell's `[Console]::Write` with `[char]N` for anything
# non-printable (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
# ships with every supported Windows).
#
# `hold_seconds` keeps the child alive afterwards. That matters when the point
# of the bytes is a terminal mode: returning to the shell prompt gives readline
# the chance to set the mode again, which is exactly what the fixture must not
# have happen.

const WINDOWS := "Windows"


static func is_windows() -> bool:
	return OS.get_name() == WINDOWS


## A command line for the configured shell that prints `text` verbatim.
static func print_text(text: String, hold_seconds := 0) -> String:
	if is_windows():
		return 'powershell -NoProfile -Command "%s"' % _powershell_script(text, hold_seconds)
	return _printf_write(text, hold_seconds)

## The same text as an argv plan — `[program, args]` — for a child that is
## spawned directly instead of typed into a shell (a `cli_view` pane).
##
## POSIX keeps the shell (`printf '%b'` is the only portable way to emit exact
## bytes), but Windows must not: `print_text()` returns a *cmd.exe* command
## line, and handing that line to `cmd.exe /c` through argv makes cmd re-parse
## it — `\"` means nothing to cmd, so PowerShell received
## `"[Console]::Write(...)"` as a quoted *string* and printed the script
## instead of running it. Measured on `windows-smoke`: the pane showed the
## code and the marker never arrived. Naming PowerShell here removes the
## second interpreter, so the script reaches `-Command` through the same
## quoting rules every Windows CLI argument goes through.
static func print_text_argv(shell: String, text: String, hold_seconds := 0) -> Array:
	if is_windows():
		return [_powershell_exe(), ["-NoProfile", "-Command", _powershell_script(text, hold_seconds)]]
	return [shell, PaneTypes.shell_run_args(shell, print_text(text, hold_seconds))]


## Arguments that keep the pane's shell from setting terminal modes by itself.
##
## A bracketed-paste test wants the mode to come from the *child* it spawns; an
## interactive shell sets it too, and then the assertion cannot tell whose bytes
## arrived. `bash -i` emits DECSET 2004 around every line readline edits —
## measured: with the fixture's command line replaced by a bare `sleep 30`,
## `test_bracketed_paste.gd` still passed 3/3, because readline had already set
## the mode and cleared it when the line was executed. `bash --noediting -i`
## emits neither, and still prompts and runs what it is given, so the fixture's
## bytes are the only source left. The pane's shell here is bash
## (`SettingsManager.default_shell_command()` on Unix), so these are its flags;
## `cmd.exe` has no line editor and gets none.
static func no_line_editing_args() -> Array:
	if is_windows():
		return []
	return ["--noediting"]


static func _printf_write(text: String, hold_seconds: int) -> String:
	var encoded := ""
	for i in text.length():
		var code := text.unicode_at(i)
		# Printable ASCII goes through as itself; everything else (control
		# bytes, quotes, non-ASCII) becomes an octal escape `%b` expands.
		if code >= 32 and code < 127 and code != 39 and code != 92:
			encoded += text[i]
		else:
			encoded += "\\%03o" % code
	var command := "printf '%%b' '%s'" % encoded
	if hold_seconds > 0:
		command += "; sleep %d" % hold_seconds
	return command


## The bare PowerShell script both Windows forms run: split into single-quoted
## characters (so a marker the fixture prints can never be found verbatim in
## the plan or in a command echo) with `[char]N` for anything non-printable or
## quote-shaped. Operators stay unspaced so the script needs no quoting of its
## own on the way to `-Command`.
static func _powershell_script(text: String, hold_seconds: int) -> String:
	var script := _powershell_expr(text)
	if hold_seconds > 0:
		script += ";Start-Sleep %d" % hold_seconds
	return script


## One element per character: printable ASCII as itself, everything else as
## `[char]N`. Single quotes are escaped out as well as double quotes — the
## script travels inside a double-quoted `cmd` argument, so a literal one would
## end it early.
static func _powershell_parts(text: String) -> PackedStringArray:
	var parts: PackedStringArray = []
	for i in text.length():
		var code := text.unicode_at(i)
		if code >= 32 and code < 127 and code != 39 and code != 34:
			parts.append("'%s'" % text[i])
		else:
			parts.append("[char]%d" % code)
	# `[Console]::Write()` with no arguments is a syntax error, not a no-op.
	if parts.is_empty():
		parts.append("''")
	return parts


## Just the write expression for `text`, without the optional trailing hold —
## the piece `print_text_pair` composes two of.
static func _powershell_expr(text: String) -> String:
	return "[Console]::Write(%s)" % "+".join(_powershell_parts(text))


## Print `first`, hold the shell for `hold_seconds`, then print `second` — one
## typed line that a test can watch a mode go one way and back on.
##
## A fixture that holds the shell cannot be given a second command while it
## holds: a later line sits in the PTY's input buffer until the first one
## finishes. A transition (on, then off) therefore has to be one line, and this
## is that line.
static func print_text_pair(first: String, hold_seconds: int, second: String) -> String:
	if is_windows():
		return 'powershell -NoProfile -Command "%s;Start-Sleep %d;%s"' % [
			_powershell_expr(first), hold_seconds, _powershell_expr(second),
		]
	return "%s; sleep %d; %s" % [_printf_write(first, 0), hold_seconds, _printf_write(second, 0)]

## The PowerShell every supported Windows ships. Absolute: an argv plan is
## spawned without a shell, so there is nothing to resolve a bare name.
static func _powershell_exe() -> String:
	var root := OS.get_environment("SystemRoot")
	if root == "":
		return "powershell.exe"
	return root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
