extends GutTest
# Integration tests: Workspace palette commands.
# Uses PaneTypes.build_palette_commands() — the single source of truth shared
# with workspace.gd — so adding a pane type or action is reflected here
# automatically.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_palette_commands_include_all_types():
	var cmds = PaneTypes.build_palette_commands()
	assert_true(cmds.has("new terminal"), "should have new terminal")
	assert_true(cmds.has("new code viewer"), "should have new code viewer")
	assert_true(cmds.has("new file tree"), "should have new file tree")
	assert_true(cmds.has("new inspector"), "should have new inspector")
	assert_true(cmds.has("new reasoning"), "should have new reasoning")

func test_palette_commands_include_actions():
	var cmds = PaneTypes.build_palette_commands()
	assert_true(cmds.has("close active"))
	assert_true(cmds.has("settings"))
	assert_true(cmds.has("reset layout"))

func test_pane_types_all_has_five_entries():
	assert_eq(PaneTypes.ALL.size(), 5)
	assert_true(PaneTypes.ALL.has("terminal"))
	assert_true(PaneTypes.ALL.has("code_viewer"))
	assert_true(PaneTypes.ALL.has("file_tree"))
	assert_true(PaneTypes.ALL.has("inspector"))
	assert_true(PaneTypes.ALL.has("reasoning"))
	assert_false(PaneTypes.ALL.has("observer"))
