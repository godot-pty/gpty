extends GutTest
# ExternalLink — one outbound-link path for every URL the app hands to the OS.
# Defends: a press the system refuses never looks dead — the text goes to the
# clipboard and a WARN toast names it (the URL shortened for the one-line toast,
# never for the clipboard), while a reachable link touches nothing else.

var _opened: Array = []
var _copied: Array = []
var _open_result: Error = OK
var _saved_open: Callable
var _saved_copy: Callable

func before_each():
	MockAutoloads.setup()
	# The seams are process-global statics: save what this suite found and put
	# it back, so a later suite never inherits a recorder.
	_saved_open = ExternalLink.open_external
	_saved_copy = ExternalLink.copy_text
	_opened.clear()
	_copied.clear()
	_open_result = OK
	ExternalLink.open_external = _record_open
	ExternalLink.copy_text = _record_copy

func after_each():
	ExternalLink.open_external = _saved_open
	ExternalLink.copy_text = _saved_copy
	MockAutoloads.teardown()

func _record_open(uri: String) -> Error:
	_opened.append(uri)
	return _open_result

func _record_copy(text: String) -> void:
	_copied.append(text)

func _toast() -> Dictionary:
	return get_signal_parameters(ToastManager, "toast_requested")[0]

func test_a_reachable_link_opens_once_and_touches_nothing_else():
	watch_signals(ToastManager)
	var err := ExternalLink.open("https://example.com/a")
	assert_eq(err, OK)
	assert_eq(_opened, ["https://example.com/a"], "one link, one open")
	assert_eq(_copied.size(), 0, "a successful open does not touch the clipboard")
	assert_signal_not_emitted(ToastManager, "toast_requested",
		"nothing to report when the browser took the URL")

func test_a_refused_link_is_copied_and_named_in_a_warning():
	_open_result = ERR_CANT_OPEN
	watch_signals(ToastManager)
	var err := ExternalLink.open("https://example.com/refused")
	assert_eq(err, ERR_CANT_OPEN, "the caller still sees the refusal")
	assert_eq(_copied, ["https://example.com/refused"], "the URL is the fallback text")
	assert_signal_emit_count(ToastManager, "toast_requested", 1)
	var toast := _toast()
	assert_eq(toast["level"], ToastManager.WARN)
	assert_string_contains(str(toast["text"]), "https://example.com/refused",
		"the toast names what was copied")
	assert_eq(str(toast["source"]), ExternalLink.SOURCE)

func test_a_custom_fallback_text_and_message_replace_the_url_default():
	_open_result = ERR_CANT_OPEN
	watch_signals(ToastManager)
	ExternalLink.open("https://example.com/issue", "the whole issue body",
		"paste it at the tracker", "Feedback")
	assert_eq(_copied, ["the whole issue body"],
		"a row that carries more than a URL copies that instead")
	var toast := _toast()
	assert_eq(str(toast["text"]), "paste it at the tracker")
	assert_eq(str(toast["source"]), "Feedback")

func test_a_long_url_is_shortened_only_in_the_toast():
	_open_result = ERR_CANT_OPEN
	var url := "https://example.com/" + "a".repeat(400)
	watch_signals(ToastManager)
	ExternalLink.open(url)
	assert_eq(_copied, [url], "the clipboard gets the whole URL")
	var text := str(_toast()["text"])
	assert_lt(text.length(), 200, "the toast stays one line")
	assert_string_contains(text, "…", "the shortened form is marked")
