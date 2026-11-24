extends GutTest
# ToastOverlay — a toast is an opaque card, not bare ink over the terminal.
# Defends: the message has its own surface with padding, the level is a leading
# edge (not only the label's colour), and the text is published to assistive
# tech.

var _overlay: ToastOverlay

func before_each():
	MockAutoloads.setup()
	SettingsManager.cfg_appearance_mode = SettingsManager.APPEARANCE_DARK
	SettingsManager.apply_appearance()
	_overlay = ToastOverlay.new()
	_overlay.theme = UiTheme.build()
	add_child(_overlay)

func after_each():
	SettingsManager.cfg_motion = UiMotion.SUBTLE
	_overlay.free()
	MockAutoloads.teardown()

func _panel_of() -> PanelContainer:
	# The newest toast is the last panel child: an older panel is queue_free'd
	# but still a child until the frame that frees it ends.
	for i in range(_overlay.get_child_count() - 1, -1, -1):
		var c := _overlay.get_child(i)
		if c is PanelContainer:
			return c
	return null

func test_a_toast_is_an_opaque_padded_panel():
	ToastManager.info("Copied line 3")
	var panel := _panel_of()
	assert_not_null(panel, "a toast is a panel, not a bare Label")
	var box := panel.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(box)
	assert_eq(box.bg_color.a, 1.0, "the message must not read over the terminal's text")
	assert_gt(box.content_margin_top, 0.0, "the card has padding")
	var lbl := panel.get_child(0) as Label
	assert_eq(lbl.text, "Copied line 3")
	assert_eq(lbl.accessibility_name, "Copied line 3", "a screen reader gets the message")
	assert_eq(lbl.accessibility_live, A11y.LIVE_POLITE)

func test_the_level_is_a_leading_edge_not_only_ink():
	var p := UiPalette.active()
	# One toast at a time: the levels are checked in sequence, each after the
	# previous message's own lifetime (the queue serializes them now).
	ToastManager.warn("Careful", 0.0)
	var warn_box := _panel_of().get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(warn_box.border_color, p.WARNING)
	assert_eq(warn_box.border_width_left, 3, "the level has a leading edge, not only ink")
	await wait_seconds(0.9)
	ToastManager.error("Broken", 0.0)
	var err_box := _panel_of().get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(err_box.border_color, p.DANGER)
	assert_eq(err_box.border_width_left, 3)

func test_a_second_message_waits_for_the_first():
	ToastManager.info("first")
	ToastManager.info("second")
	assert_eq(_overlay._toast_count, 1, "the burst shows one toast, not one per message")
	assert_eq(_overlay._queue.size(), 1, "the second message is queued")
	assert_eq((_panel_of().get_child(0) as Label).text, "first",
		"the visible message keeps its lifetime")

func test_the_dismissal_starts_the_queued_message():
	ToastManager.info("first", 0.0)
	ToastManager.info("second")
	# A zero-length message still fades in and out (0.2 s + 0.5 s).
	await wait_seconds(0.9)
	assert_true(_overlay._active, "the queued message is showing, not dropped")
	assert_eq(_overlay._queue.size(), 0)
	var panel := _panel_of()
	assert_not_null(panel)
	assert_eq((panel.get_child(0) as Label).text, "second")

func test_the_queue_is_bounded_and_keeps_the_newest():
	ToastManager.info("first", 60.0)
	for i in 100:
		ToastManager.info("m%d" % i)
	assert_eq(_overlay._queue.size(), ToastOverlay.MAX_QUEUE,
		"a caller in a loop must not grow the queue without bound")
	assert_eq(str(_overlay._queue[-1]["text"]), "m99", "the newest message is kept")
	assert_eq(str(_overlay._queue[0]["text"]), "m92", "the oldest queued message is dropped")
	assert_eq((_panel_of().get_child(0) as Label).text, "first",
		"the visible message was not replaced")

## Motion Off reduces a toast to its hold time: it is opaque on the frame it is
## enqueued (no fade in), keeps its message legible for the whole hold, and the
## queue still serializes.
func test_motion_off_is_a_hold_without_fades():
	SettingsManager.cfg_motion = UiMotion.OFF
	ToastManager.info("hold only", 0.15)
	var panel := _panel_of()
	assert_not_null(panel)
	assert_almost_eq(panel.modulate.a, 1.0, 0.001, "no fade in")
	assert_eq((panel.get_child(0) as Label).text, "hold only")
	ToastManager.info("second", 0.15)
	var started := false
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		if _overlay._toast_count == 2:
			started = true
			break
		await get_tree().process_frame
	assert_true(started, "the queued message starts once the hold ends")
	assert_false(_overlay._queue.has({"text": "second"}),
		"the message left the queue when its hold started")
