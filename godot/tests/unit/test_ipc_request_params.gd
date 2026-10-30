extends GutTest
# The drain loop's `params` guard: one malformed request in a batch costs one
# error response, never the batch.
#
# The defect (found by the October audit, re-run in isolation): the drain
# parsed each request's `params` with `JSON.parse_string` and guarded only the
# `null` result, so valid JSON that is not an object (`[1,2]`, `"x"`, `5`)
# became `params` - and `WorkspaceIpcHandlers.handle(ws, method, params:
# Dictionary)` or `paneWait`'s `params.get(...)` raised a call error that
# aborted the poll function. The requests were already taken off the Rust
# queue (`drain_ipc_requests`), so everything after the bad one was neither
# handled nor answered, and each dropped caller waited out its own timeout.
#
# The loop itself cannot be driven from here - `drain_ipc_requests` has no push
# seam a GDScript test can reach - so this covers the decision it makes per
# request (`WorkspaceIpcHandlers.request_params`), including that the guarded
# value is what a typed handler accepts. The live path (a raw non-object
# `params` over the control socket, then a normal call) is a step in
# `scripts/smoke_pane_api.py`, and the server-edge refusal has its own test in
# `crates/gpty-ipc/src/server.rs`.

const BATCH := [
	{"id": 1, "params": "{\"pane_id\":\"a\"}"},
	{"id": 2, "params": "[1,2]"},
	{"id": 3, "params": "{\"pane_id\":\"c\"}"},
]


func test_a_bad_request_between_two_good_ones_costs_only_itself():
	var handled := []
	var answered := []
	for req in BATCH:
		var parsed := WorkspaceIpcHandlers.request_params(req["params"])
		if parsed.has("error"):
			answered.append(req["id"])
			continue
		var params: Dictionary = parsed["params"]
		# The typed entry point the drain calls. An Array here would raise a
		# call error and abort the loop, which is what the guard prevents.
		var result = WorkspaceIpcHandlers.handle(null, "notAMethod", params)
		assert_true(result is Dictionary and result.has("error"), "the batch must keep dispatching")
		assert_eq(int(result["error"]["code"]), -32601)
		handled.append(req["id"])
	assert_eq(handled, [1, 3], "the two object requests must still be handled")
	assert_eq(answered, [2], "only the malformed request is answered and skipped")


func test_every_non_object_kind_is_refused():
	for raw in ["[1,2]", "\"x\"", "5", "1.5", "true", "[]"]:
		var parsed := WorkspaceIpcHandlers.request_params(raw)
		assert_true(parsed.has("error"), "%s must be refused" % raw)
		assert_true(
			str(parsed["error"]).contains("params"),
			"the refusal must name the field, got: %s" % str(parsed["error"])
		)


func test_absent_and_null_params_mean_no_arguments():
	for raw in ["", "null", null]:
		assert_eq(
			WorkspaceIpcHandlers.request_params(raw),
			{"params": {}},
			"%s must mean no arguments" % str(raw)
		)


func test_an_object_passes_through_unchanged():
	assert_eq(
		WorkspaceIpcHandlers.request_params("{\"pane_id\":\"a\",\"tags\":[\"x\"]}"),
		{"params": {"pane_id": "a", "tags": ["x"]}}
	)
