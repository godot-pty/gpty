extends GutTest
# What a terminal's close guard reads out of one `paneStatus` document.
#
# `running` is not the whole answer: it means "an exit code is still to come",
# which is false for a pane whose terminal task died, and that pane can still
# own a running child (`exit_reason: task_ended`, `child_alive: true`). A close
# kills that process group, so it must ask. These cases pin both halves and
# their precedence, without needing a live child.

func test_a_foreground_command_is_running_work():
	assert_true(TerminalPane.running_work_from_status({
		"running": true, "foreground_job": true, "child_alive": true,
	}))

func test_an_idle_shell_is_not_running_work():
	assert_false(TerminalPane.running_work_from_status({
		"running": true, "foreground_job": false, "child_alive": true,
	}))

func test_a_platform_without_a_foreground_group_is_conservative():
	# Windows/ConPTY cannot report one, so a live shell could be busy.
	assert_true(TerminalPane.running_work_from_status({
		"running": true, "foreground_job": null, "child_alive": true,
	}))
	assert_true(TerminalPane.running_work_from_status({
		"running": true, "child_alive": true,
	}), "a missing foreground_job key reads as unknown, not idle")

func test_a_child_that_outlived_the_task_is_running_work():
	# The regression this file exists for: the task ended without reaping the
	# child, so nothing samples a foreground job any more - and teardown still
	# SIGKILLs that process group.
	assert_true(TerminalPane.running_work_from_status({
		"running": false, "exit_code": null, "exit_reason": "task_ended",
		"foreground_job": false, "child_alive": true,
	}))

func test_a_dead_pane_with_no_child_is_not_running_work():
	# A panicked task kills the child on the way out; nothing is left to stop.
	assert_false(TerminalPane.running_work_from_status({
		"running": false, "exit_code": null, "exit_reason": "task_ended",
		"child_alive": false,
	}))

func test_an_exited_shell_is_not_running_work():
	# A stale foreground sample must not outvote a reap: the shell is gone.
	assert_false(TerminalPane.running_work_from_status({
		"running": false, "exit_code": 0, "exit_reason": "exited",
		"foreground_job": true, "child_alive": false,
	}))

func test_a_malformed_document_is_not_running_work():
	assert_false(TerminalPane.running_work_from_status(null))
	assert_false(TerminalPane.running_work_from_status("{}"))
	assert_false(TerminalPane.running_work_from_status({}))
