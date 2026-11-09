extends GutTest
# SectionHelp — the shared Help affordance a section header carries.
#
# Defends: one named button (theme, glyph, "Help" as tooltip and accessible
# name), a popup that is a glyph | action | chord table of the caller's rows,
# and rows read at press time rather than snapshotted at attach time.

var _host: Control
var _header: HBoxContainer

const ROWS: Array[Dictionary] = [
	{"glyph": ">_", "action": "Add a Terminal pane", "chord": "Ctrl+Shift+N"},
	{"glyph": "|>", "action": "Add a Media pane", "chord": ""},
]


func before_each():
	UiPalette.use(UiPalette.MODE_DARK)
	_host = Control.new()
	_host.name = "Host"
	# Under the one Theme, as the workspace applies it: the popup's muted chord
	# column resolves only there.
	_host.theme = UiTheme.build()
	_host.custom_minimum_size = Vector2(900, 700)
	add_child(_host)
	_header = HBoxContainer.new()
	_host.add_child(_header)


func after_each():
	UiPalette.use(UiPalette.MODE_DARK)
	# Free before the next test builds its own host: an `AcceptDialog` is an
	# exclusive child window of the root, and one left open from the previous
	# test makes the next popup log "already has another exclusive child".
	if _host:
		remove_child(_host)
		_host.free()
		_host = null


func _attach(rows: Array = ROWS) -> Button:
	return SectionHelp.attach(_header, _host, "Add Pane", "One sentence.", func(): return rows)


func _table() -> GridContainer:
	return _host.find_child(SectionHelp.TABLE_NAME, true, false) as GridContainer


func test_the_button_is_named_help_and_draws_the_question_glyph():
	var btn := _attach()
	assert_eq(btn.name, SectionHelp.BUTTON_NAME)
	assert_eq(btn.accessibility_name, SectionHelp.NAME, "a reader hears the words")
	assert_eq(btn.tooltip_text, SectionHelp.NAME, "and a pointer user reads the same word")
	assert_eq(Icons.glyph(btn), Icons.QUESTION, "the affordance's one glyph")
	assert_eq(btn, _header.get_child(_header.get_child_count() - 1),
		"last in the row, so it sits at the right edge beside a filling heading")


func test_the_popup_lists_one_row_per_entry_in_three_columns():
	var btn := _attach()
	btn.pressed.emit()
	var table := _table()
	assert_not_null(table, "the press opens the table")
	assert_eq(table.columns, 3, "glyph | action | chord")
	assert_eq(table.get_child_count(), ROWS.size() * 3)
	var intro := _host.find_child(SectionHelp.INTRO_NAME, true, false) as Label
	assert_not_null(intro)
	assert_eq(intro.text, "One sentence.")
	assert_ne(intro.autowrap_mode, TextServer.AUTOWRAP_OFF, "the intro wraps")


func test_the_glyph_speaks_the_action_words_not_the_codepoint():
	var btn := _attach()
	btn.pressed.emit()
	var table := _table()
	var glyph := table.get_child(0) as Label
	assert_eq(glyph.text, ">_")
	assert_eq(glyph.accessibility_name, "Add a Terminal pane",
		"the glyph cell publishes the action, so a codepoint never reaches AT")


## The provider's answer, changed between attach and press. A member, not a
## lambda-local: a GDScript lambda captures a local by value, so a counter inside
## one would be invisible here.
var _rows_now: Array[Dictionary] = []

func _live_rows() -> Array[Dictionary]:
	return _rows_now

func test_the_rows_are_read_at_press_time_not_at_attach_time():
	_rows_now = [{"glyph": ">_", "action": "Before", "chord": ""}]
	var btn := SectionHelp.attach(_header, _host, "Add Pane", "Intro", _live_rows)
	# A chord is only known once the workspace has registered its bindings, which
	# can happen after a panel exists: the answer has to be read on press.
	_rows_now = [{"glyph": ">_", "action": "After", "chord": "Ctrl+K"}]
	assert_null(_host.find_child(SectionHelp.TABLE_NAME, true, false),
		"attaching opens nothing")
	btn.pressed.emit()
	var table := _table()
	assert_not_null(table, "the press opens the table")
	assert_eq((table.get_child(1) as Label).text, "After",
		"the press read the current rows, not the ones the attach saw")
	assert_eq((table.get_child(2) as Label).text, "Ctrl+K")

func test_the_popup_frees_itself_when_it_closes():
	# A press per investigation is unbounded, so a popup that only hid would
	# leave one table per press in the tree for the session.
	var btn := _attach()
	btn.pressed.emit()
	var table := _table()
	assert_not_null(table)
	var dialog := table.get_parent().get_parent() as AcceptDialog
	dialog.get_ok_button().pressed.emit()
	await wait_frames(2)
	assert_null(_host.find_child(SectionHelp.TABLE_NAME, true, false),
		"the closed table is freed, not left hidden")
