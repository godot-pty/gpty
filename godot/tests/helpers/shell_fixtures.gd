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
		return _powershell_write(text, hold_seconds)
	return _printf_write(text, hold_seconds)


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


static func _powershell_write(text: String, hold_seconds: int) -> String:
	var parts: PackedStringArray = []
	for i in text.length():
		var code := text.unicode_at(i)
		# Double quotes are excluded as well as the single quote: the script is
		# passed inside a double-quoted cmd argument, so a literal one would
		# end it early.
		if code >= 32 and code < 127 and code != 39 and code != 34:
			parts.append("'%s'" % text[i])
		else:
			parts.append("[char]%d" % code)
	var script := "[Console]::Write(%s)" % " + ".join(parts)
	if hold_seconds > 0:
		script += "; Start-Sleep %d" % hold_seconds
	return 'powershell -NoProfile -Command "%s"' % script
