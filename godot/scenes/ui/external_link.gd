class_name ExternalLink
## The one outbound path: `OS.shell_open`, and when the OS refuses (no browser
## handler, no mime handler for a file, headless, a scheme the platform will not
## take) the text goes to the clipboard and a warning toast names it, so a press
## never looks dead.
## `open_external`/`copy_text` are the replaceable seams: both cross the
## process boundary, so a headless run can only assert what was handed to them.

const SOURCE := "Link"
## The toast is one line; a note's URL can be arbitrarily long.
const MAX_TOAST_URL := 120

static var open_external: Callable = func(uri: String) -> Error: return OS.shell_open(uri)
static var copy_text: Callable = func(text: String) -> void: DisplayServer.clipboard_set(text)

## Open `url`. On `OK` nothing else happens. On any other `Error` the
## `fallback_text` (default: the URL) is copied and a WARN toast says so -
## `message` overrides the sentence (the Feedback row pastes a whole issue body,
## not the URL), `source` is the toast's origin label.
static func open(url: String, fallback_text := "", message := "", source := SOURCE) -> Error:
	var err: Error = open_external.call(url)
	if err == OK:
		return OK
	copy_text.call(fallback_text if fallback_text != "" else url)
	ToastManager.warn(message if message != "" else refused_message(url), 6.0, source)
	return err

## "Couldn't open a browser - copied <url>", with a long URL shortened for the
## toast only: the clipboard always gets the whole thing.
static func refused_message(url: String) -> String:
	return "Couldn't open a browser - copied %s" % shown(url)

## "Couldn't open this file - copied <uri>". A file open hands the path to the
## system's mime handler, which may *run* the target, so its refusal names the
## file rather than a browser; the shortening is the toast's only.
static func refused_file_message(uri: String) -> String:
	return "Couldn't open this file - copied %s" % shown(uri)

static func shown(url: String) -> String:
	return url if url.length() <= MAX_TOAST_URL else url.left(MAX_TOAST_URL - 1) + "…"
