extends GutTest
# Smoke tests: Workspace instantiation and critical member integrity.
# Catches regressions where a member declaration is accidentally deleted.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_workspace_tm_is_terminal_manager():
	# _tm is initialized at declaration time — no _ready() needed
	var ws = Workspace.new()
	assert_not_null(ws._tm, "_tm should be initialized at declaration")
	assert_true(ws._tm is TerminalManager, "_tm should be a TerminalManager")
	ws.free()
