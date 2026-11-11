class_name WorkspaceIpcHandlers
## IPC method dispatch extracted from workspace.gd.
##
## Every handler receives the Workspace instance and stays side-effect
## compatible with the inline version it replaced. New pane-API methods
## land here; keep the smoke script (scripts/smoke_pane_api.py) as the
## end-to-end contract check.


## The JSON-RPC error codes a refusal may carry (`JsonRpcError`'s, in
## `crates/gpty-ipc/src/protocol.rs`). Every arm names one through
## `bad_param`/`refused`; `error()` itself has no default so no arm can inherit
## a code it never decided.
const CODE_INVALID_PARAMS := -32602
const CODE_SERVER_ERROR := -32000
const CODE_METHOD_NOT_FOUND := -32601


static func error(msg: String, code: int) -> Dictionary:
	return {"error": {"code": code, "message": msg}}


## The request body named a value this handler cannot accept: a missing
## required key, an unknown enum member, a wrong JSON type, a string over its
## cap. JSON-RPC `-32602` - the caller fixes this by changing the call.
static func bad_param(msg: String) -> Dictionary:
	return error(msg, CODE_INVALID_PARAMS)


## The request was well formed and names app state this handler cannot
## satisfy: an unknown, gone or ambiguous pane, a pane of the wrong kind, a
## full grid, a pane that cannot start, an unsaved pane, a profile the user
## has not approved. JSON-RPC `-32000` - the call was right, the world is not.
static func refused(msg: String) -> Dictionary:
	return error(msg, CODE_SERVER_ERROR)


## `Workspace._resolve_pane_target`'s answer, as the refusal it holds. The
## resolver decides its own code (a missing target is a bad param; an unknown
## or ambiguous one is app state), so no arm re-decides it.
static func target_refusal(found: Dictionary) -> Dictionary:
	return error(str(found["error"]), int(found.get("code", CODE_SERVER_ERROR)))


## Parse one queued request's `params` field for the drain loop.
##
## The Rust server refuses a `params` that is not a JSON object before it is
## queued (JSON-RPC `-32602`), and this is the second layer. GDScript has no
## try/catch, so a value that is not a `Dictionary` raises a call error in the
## typed handlers (`paneWait`'s `params.get(...)`, `handle(ws, method, params:
## Dictionary)`), which aborts the whole poll loop - every request already
## drained from the Rust queue is then neither handled nor answered, and each
## caller waits out its own timeout. One bad value must cost one error
## response, never the batch.
##
## Returns `{"params": Dictionary}` for a request that may be handled, or
## `{"error": String}` for one that must be answered and skipped. Absent, empty
## and `null` params all mean "no arguments"; unparseable JSON is treated the
## same way, because the server answers malformed JSON before queueing and this
## path only exists for whatever got past it.
static func request_params(raw) -> Dictionary:
	if not (raw is String) or raw.is_empty() or raw == "null":
		return {"params": {}}
	var parsed = JSON.parse_string(raw)
	if parsed == null:
		return {"params": {}}
	if not (parsed is Dictionary):
		return {"error": "params must be a JSON object, got %s" % type_string(typeof(parsed))}
	return {"params": parsed}


## The admin actions `gpty plugin` can take that change the store a running GUI
## reads. Closed vocabulary: the CLI names one, anything else is refused.
const PLUGIN_ADMIN_ACTIONS := ["uninstall", "enable", "disable"]


## Dispatch one drained request into the response documents it produces.
##
## Extracted from `Workspace._poll_ipc_requests` so the loop's own body can run
## in a GUT test: the Rust queue (`drain_ipc_requests`) has no push seam, and
## testing only the per-request params decision left the `paneWait`
## bookkeeping and the success/error envelope unexercised. Each entry is
## `{id, success, payload}`; an empty array means the answer is deferred
## (`paneWait` answers from the wait poll, `pluginInstall` from the review
## dialog, and a pane-creating method from its new pane's own start).
##
## A refusal's payload is the flat error object `error()` builds, not the
## `{"error": ...}` envelope: `respond_ipc` hands it to the Rust edge, which
## makes it the JSON-RPC error itself, so the caller reads the handler's own
## sentence instead of a stringified document.
static func dispatch_request(ws, req: Dictionary) -> Array:
	var id = req.get("id", 0)
	var parsed: Dictionary = request_params(req.get("params"))
	if parsed.has("error"):
		# -32602 matches what the Rust edge answers for the same input, so a
		# client sees one contract whichever layer refused it.
		return [_answer(id, false, bad_param(str(parsed["error"]))["error"])]
	var params: Dictionary = parsed["params"]
	var method = str(req.get("method", ""))
	if method == "paneWait":
		var w_found: Dictionary = ws._resolve_pane_target(str(params.get("pane_id", "")))
		if w_found.has("error"):
			return [_answer(id, false, target_refusal(w_found)["error"])]
		var w_body = w_found["body"]
		if not (w_body is TerminalPane):
			return [_answer(id, false, refused("Pane '%s' is not a terminal" % params.get("pane_id", ""))["error"])]
		var w_pattern = str(params.get("pattern", ""))
		if w_pattern == "" or w_pattern.length() > 1024:
			return [_answer(id, false, bad_param("Invalid wait pattern")["error"])]
		var w_timeout = clampi(int(params.get("timeout_ms", 10000)), 100, 60000)
		ws._pending_waits[str(id)] = {
			"attachment_id": w_body.attachment_id,
			"pattern": w_pattern,
			"deadline_ms": Time.get_ticks_msec() + w_timeout,
		}
		return []
	if method == "pluginInstall":
		ws._show_plugin_review(int(id), params, int(req.get("timeout_ms", 0)))
		return []
	var result = ws._handle_ipc_method(method, params)
	if result is Dictionary and result.has("error"):
		return [_answer(id, false, result["error"])]
	# A pane answer is only true once that pane can run. A terminal starts its
	# child from the first size its tile is laid out at, which is after this
	# returns, so an answer naming a pane is held (`_hold_pane_answer`) until
	# the pane reports the outcome: a spawn that failed answers an error
	# instead of a success over a tile that can never run anything.
	if result is Dictionary and result.has("pane_id") and ws._hold_pane_answer(int(id), result):
		return []
	return [_answer(id, true, result)]


static func _answer(id, success: bool, payload) -> Dictionary:
	return {"id": id, "success": success, "payload": payload}


static func handle(ws, method: String, params: Dictionary):
	match method:
		"vaultWeight":
			# The authored layer's one agent verb: declare (or clear) one
			# directed link's display weight. It writes the user's own store
			# (`user://link_weights.json`) and nothing else — never a vault,
			# never the index, never a decision. A declared weight can only
			# change how the graph and link panel are drawn (the same rule the
			# canvas's set/clear control follows), so an agent curating a
			# vault's structure still cannot hide an edge, gate navigation or
			# count as consent.
			#
			# One number is the whole surface: `weight` present means set, and
			# its absence (or null) means clear. The GUI owns the store because
			# `user://` is Godot's; a caller needs a running GUI, which is why
			# the CLI command never auto-spawns one.
			var vw_vault := LinkWeights.normalize_vault(str(params.get("vault_path", "")))
			if not LinkWeights.valid_vault_path(vw_vault) \
				or not DirAccess.dir_exists_absolute(vw_vault):
				return bad_param("Vault is not an absolute directory: %s" % vw_vault)
			# The caller-chosen root is the whole exposure: this verb writes a
			# user-owned store keyed by the vault, so an unregistered root would
			# let any client add entries (and, at the store's vault cap, evict
			# the user's own). The native search/read handlers apply the same
			# gate; `VaultRegistry` is the one list both read.
			if not VaultRegistry.has_root(vw_vault):
				return refused(
					"Vault is not registered: %s - open it in a Wiki pane's settings first"
						% vw_vault
				)
			var vw_src := str(params.get("src", ""))
			var vw_target := str(params.get("target", ""))
			if not LinkWeights.valid_note_path(vw_src) \
				or not LinkWeights.valid_note_path(vw_target):
				return bad_param(
					"`src` and `target` must be vault-relative note paths (.md, no hidden component)"
				)
			var vw_raw = params.get("weight")
			if vw_raw == null or (vw_raw is String and str(vw_raw).strip_edges() == ""):
				var vw_cleared := LinkWeightsStore.clear_weight(vw_vault, vw_src, vw_target)
				if vw_cleared != "":
					return refused(vw_cleared)
				return {"vault": vw_vault, "src": vw_src, "target": vw_target, "weight": 0}
			var vw_weight := 0
			if vw_raw is int:
				vw_weight = int(vw_raw)
			elif vw_raw is float:
				vw_weight = int(vw_raw)
			elif vw_raw is String and str(vw_raw).strip_edges().is_valid_int():
				vw_weight = str(vw_raw).strip_edges().to_int()
			else:
				return bad_param(
					"`weight` must be an integer between %d and %d, or omitted to clear"
						% [LinkWeights.MIN_WEIGHT, LinkWeights.MAX_WEIGHT]
				)
			if vw_weight < LinkWeights.MIN_WEIGHT or vw_weight > LinkWeights.MAX_WEIGHT:
				return bad_param(
					"`weight` must be between %d and %d" % [
						LinkWeights.MIN_WEIGHT, LinkWeights.MAX_WEIGHT,
					]
				)
			var vw_problem := LinkWeightsStore.set_weight(
				vw_vault, vw_src, vw_target, vw_weight
			)
			if vw_problem != "":
				return refused(vw_problem)
			return {
				"vault": vw_vault,
				"src": vw_src,
				"target": vw_target,
				"weight": vw_weight,
			}
		"pluginsChanged":
			# A CLI admin action has already written the plugin store when
			# this arrives (unlike the install review, whose clone lands only
			# after the human answers), so the profile list and the concept
			# set re-read it now and the answer means "the GUI has caught
			# up". Without this a running GUI kept listing an uninstalled
			# plugin's profiles — and kept activating them from its
			# in-memory copy — until the next restart, which made `disable`
			# look like it did nothing; an uninstalled plugin's concepts
			# would have stayed live in the engine the same way.
			#
			# Both fields are validated although only `action` is read today.
			# `id` is inert right now (this handler neither stores nor looks
			# anything up with it), and the CLI cannot deliver a malformed one:
			# it fires the notice only after `PluginStore` accepted the id, and
			# that store validates ids before any write. It is checked anyway
			# because validation is a boundary property, not a property of the
			# fields that happen to have consumers — the day something *uses*
			# the id (a toast naming the plugin, a row linking to its repo)
			# nobody will re-derive this decision, and an id that has been
			# travelling unvalidated for a release or two gets mistaken for
			# trusted input. The shape is not re-declared here: the GUI's one
			# mirror lives beside the consent records that key on the same id.
			var pc_action := str(params.get("action", ""))
			if not PLUGIN_ADMIN_ACTIONS.has(pc_action):
				return bad_param("Unknown plugin action: %s" % pc_action)
			var pc_id := str(params.get("id", ""))
			if not TrustedStore.valid_plugin_id(pc_id):
				return bad_param("Malformed plugin id: %s" % pc_id)
			ProfileManager.refresh_plugin_profiles()
			ConceptManager.refresh_plugin_concepts()
			return {"refreshed": true, "action": pc_action, "id": pc_id}
		"newPane":
			# Every value here is caller-supplied and ends at a spawn or a
			# label, so each is validated or sanitized before it is used. The
			# keys are the CLI's wire names; the MCP tool surface advertises
			# clap's ids and `wire.rs` translates them (`pane_type` -> `type`,
			# `title` -> `title_label`).
			var type_name = str(params.get("type", "terminal"))
			if not PaneTypes.ALL.has(type_name):
				return bad_param("Unknown pane type: %s" % type_name)
			# Validated before anything spawns: a refused call must not leave a
			# pane behind. Absent means focus (the documented default), and a
			# value that is not a boolean is refused rather than coerced —
			# `"false"` is truthy in GDScript, which would focus the opposite
			# of what the caller asked for.
			var np_focus = params.get("focus", true)
			if typeof(np_focus) != TYPE_BOOL:
				return bad_param("`focus` must be a boolean")
			var np_tags: Array = PaneTypes.sanitize_tags(params.get("tags", []))
			var np_opts: Dictionary
			if type_name == "cli_view":
				# argv, not a shell string: the pane runs the program directly,
				# so `command` is the program and `args` its argument vector.
				np_opts = {
					"command": PaneTypes.sanitize_shell(params.get("command"), ""),
					"shell_args": PaneTypes.sanitize_shell_args(params.get("args", [])),
					"tags": np_tags,
				}
			else:
				# `command` on a terminal is a command LINE, run through the
				# same configured shell `paneRun` uses (`-c`, or `/c` for
				# `cmd.exe`), never the pane's program: the old mapping put
				# the line into `shell_command`, so "echo hi" was spawned as a
				# program of that name and the call answered a success over a
				# child that never started. A program is set by a profile or a
				# saved tile — the two surfaces that own one.
				var np_shell: String = SettingsManager.cfg_shell_command
				np_opts = {"shell_command": np_shell, "tags": np_tags}
				var np_command := str(params.get("command", "")).strip_edges()
				if np_command != "":
					if np_command.length() > 1024 or np_command.contains("\uFFFD"):
						return bad_param("Invalid command")
					np_opts["shell_args"] = PaneTypes.shell_run_args(np_shell, np_command)
			# A display title, never the pane's addressable label
			# (`pane_label`): the request names it `title`, the spawn options
			# name it `title_label` (what `spawn_pane` reads), and an empty
			# result leaves the type's default in place.
			var np_title: String = PaneTypes.sanitize_title(params.get("title", ""))
			if np_title != "":
				np_opts["title_label"] = np_title
			# A split side is a placement preference for the largest tile
			# (`PaneTypes.SPLIT_SIDES`, what the CLI's `--split` accepts).
			# Anything else is a caller bug and is refused before a pane
			# exists, like a non-boolean `focus`; the tiling itself never
			# refuses the spawn over a preference.
			var np_split = params.get("split", "")
			if np_split != "":
				if not (np_split is String) or not PaneTypes.SPLIT_SIDES.has(np_split):
					return bad_param(
						"`split` must be one of: %s" % ", ".join(PackedStringArray(PaneTypes.SPLIT_SIDES)))
				np_opts["split"] = np_split
			var body = ws._spawn_pane(type_name, np_opts, np_focus)
			if body == null:
				var np_refused: String = ws._pane_ceiling_refusal()
				return refused(np_refused if np_refused != "" else "Grid is full")
			# A `cli_view` pane starts its program from `_ready`, so a refusal
			# is already known here: answer it and close the tile. A terminal
			# defers to the same rule from the other side (its child starts
			# after this returns, so `_hold_pane_answer` waits for it).
			if body is CliViewPane:
				var np_start_error: String = body.start_error()
				if np_start_error != "":
					ToastManager.warn(np_start_error)
					ws._kill_now(body)
					return refused(np_start_error)
			# The spawn activated the pane unless the caller passed
			# `focus: false` (`_spawn_pane_into` records and focuses it there).
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "spawned", "pane_id": body.attachment_id, "label": body.pane_label}))
			return {"pane_id": body.attachment_id, "label": body.pane_label, "type": type_name}
		"paneRead":
			var pr_found: Dictionary = ws._resolve_pane_target(str(params.get("pane_id", "")))
			if pr_found.has("error"):
				return target_refusal(pr_found)
			var pr_body: Control = pr_found["body"]
			var pr_lines = clampi(int(params.get("lines", 200)), 1, 2000)
			if pr_body is TerminalPane:
				return {"text": str(pr_body._terminal.get_plain_text(pr_lines))}
			if pr_body is CliViewPane:
				# A cli_view has no terminal buffer; its body text is the
				# drained child output the pane already displays.
				return {"text": pr_body.get_text(pr_lines)}
			return refused("Pane '%s' has no readable output" % params.get("pane_id", ""))
		"paneStatus":
			# No target = every pane's status (the CLI's no-argument mode and
			# the MCP tool's): one document, built here where the pane list and
			# the status primitives already live. Every pane answers through
			# `status_document()`; one without primitives is listed with
			# `status: null` rather than dropped, so the answer covers every
			# pane the list named.
			var ps_target := str(params.get("pane_id", ""))
			if ps_target == "":
				var ps_panes := []
				for t in ws._tm.tiles:
					var ps_any = ws._tm._find_body(t.wrapper)
					if ps_any == null:
						continue
					var ps_any_status = ps_any.status_document()
					ps_panes.append({
						"pane_id": ps_any.attachment_id,
						"label": ps_any.pane_label,
						"type": ps_any._pane_type(),
						"status": ps_any_status if ps_any_status is Dictionary else null,
					})
				return {"panes": ps_panes}
			var ps_found: Dictionary = ws._resolve_pane_target(ps_target)
			if ps_found.has("error"):
				return target_refusal(ps_found)
			var ps_body: Control = ps_found["body"]
			# Existing but with no status primitives: the pane is real, it just
			# has nothing to report. Say that instead of "not found", which sent
			# an agent looking for a pane it can already see in listPanes.
			var ps_status = ps_body.status_document()
			if not (ps_status is Dictionary):
				return refused("Pane '%s' has no status primitives" % ps_target)
			return ps_status
		"paneRun":
			var run_cmd := str(params.get("command", "")).strip_edges()
			if run_cmd == "":
				return bad_param("Command required")
			if run_cmd.length() > 1024 or run_cmd.contains("\uFFFD"):
				return bad_param("Invalid command")
			# Execute through the configured shell so compound commands
			# (&&, pipes, globs) work like a normal CLI invocation. The
			# command is an argument, never the program itself, and the
			# run flag follows the shell family (`cmd.exe` takes `/c`).
			# An agent-driven run must not take the keyboard mid-typing, so this
			# spawn is not an activation (`activate := false`).
			var run_body = ws._spawn_pane("terminal", {
				"shell_command": SettingsManager.cfg_shell_command,
				"shell_args": PaneTypes.shell_run_args(SettingsManager.cfg_shell_command, run_cmd),
			}, false)
			if run_body == null:
				var run_refused: String = ws._pane_ceiling_refusal()
				return refused(run_refused if run_refused != "" else "Grid is full")
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "spawned", "pane_id": run_body.attachment_id, "label": run_body.pane_label}))
			return {"pane_id": run_body.attachment_id, "label": run_body.pane_label, "type": "terminal"}
		"listPanes":
			var panes = []
			for t in ws._tm.tiles:
				var body = ws._tm._find_body(t.wrapper)
				if body == null:
					continue
				panes.append({
					"id": body.attachment_id,
					"label": body.pane_label,
					"type": body._pane_type(),
					"title": body.get("_last_title") if "_last_title" in body else "",
					"col": t.col, "row": t.row, "cspan": t.cspan, "rspan": t.rspan,
					"focused": body == ws._tm.last_body,
					"tags": body.tags,
				})
			return {"panes": panes, "count": panes.size()}
		"killPane":
			var kp_pane_id = str(params.get("pane_id", ""))
			var kp_target = null
			if kp_pane_id == "active" and ws._tm.last_body:
				kp_target = ws._tm.last_body
			else:
				var kp_found: Dictionary = ws._resolve_pane_target(kp_pane_id)
				if kp_found.has("error"):
					return target_refusal(kp_found)
				kp_target = kp_found["body"]
			if kp_target == null:
				return refused("Pane '%s' not found" % kp_pane_id)
			# A caller cannot answer a dialog, so a pane holding unsaved work
			# is refused rather than asked (the rule `layoutLoad` already
			# applies to an untrusted profile): naming a pane is not consent
			# to throw away what the user typed into it.
			if kp_target.has_unsaved_state():
				return refused("Pane '%s' has unsaved changes; save or discard them in the pane, then retry" % kp_pane_id)
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "killed", "pane_id": kp_target.attachment_id, "label": kp_target.pane_label}))
			# The kill primitive, not `_kill`: the GUI's close path asks about a
			# foreground process, and this caller cannot answer a dialog. Naming
			# the pane is consent to stop what it runs; unsaved work above is
			# the irreversible half that stays refused.
			ws._kill_now(kp_target)
			return {"success": true}
		"focusPane":
			var pane_id = str(params.get("pane_id", ""))
			var fp_found: Dictionary = ws._resolve_pane_target(pane_id)
			if fp_found.has("error"):
				return target_refusal(fp_found)
			var body: Control = fp_found["body"]
			# The same activation a click or a sidebar row performs: the pane
			# becomes the active one, and only a pane that can hold keyboard
			# focus takes it (a read-only pane must not swallow keys).
			ws.activate_pane(body)
			return {"success": true}
		"inject":
			var pane_id = str(params.get("pane_id", ""))
			var text = str(params.get("text", ""))
			if text.length() > 65536:
				return bad_param("Injected text exceeds 64 KiB limit")
			var in_found: Dictionary = ws._resolve_pane_target(pane_id)
			if in_found.has("error"):
				return target_refusal(in_found)
			var body: Control = in_found["body"]
			if not body is TerminalPane:
				return refused("Pane '%s' is not a terminal" % pane_id)
			body._send_line_to_term(text)
			return {"success": true}
		"broadcast":
			var b_tags: Array = PaneTypes.sanitize_tags(params.get("tags", []))
			var b_text = str(params.get("text", ""))
			if b_tags.is_empty() or b_text == "" or b_text.length() > 65536:
				return bad_param("Invalid broadcast request")
			var b_count = 0
			for t in ws._tm.tiles:
				var b_body = ws._tm._find_body(t.wrapper)
				if b_body == null or not (b_body is TerminalPane):
					continue
				var b_hit = false
				for tag in b_tags:
					if b_body.tags.has(tag):
						b_hit = true
						break
				if b_hit:
					b_body._send_line_to_term(b_text)
					b_count += 1
			return {"success": true, "count": b_count}
		"layoutSave":
			var profile_name = str(params.get("name", ""))
			if profile_name == "":
				return bad_param("Profile name required")
			if profile_name.length() > 128:
				return bad_param("Profile name too long")
			# The store is the authority on the name it kept (`add_profile`
			# suffixes a duplicate), so the answer names the row a later
			# `layoutLoad` resolves instead of the one the caller asked for.
			var stored := ProfileManager.add_profile(profile_name, ws._gather_tiles())
			return {"success": true, "name": stored}
		"layoutLoad":
			var profile_name = str(params.get("name", ""))
			var profile := ProfileManager.find_profile(profile_name)
			if profile.is_empty():
				return refused("Profile '%s' not found" % profile_name)
			# Restoring a profile can start a different program, pass argv, or set
			# an environment — the same decision the sidebar gates behind the
			# Workspace Trust dialog. A caller cannot answer that dialog, and
			# naming the profile is not consent to what a file asks for, so
			# untrusted profiles are refused here — unless the consent memory
			# already covers them (a builtin approved at this app version, or
			# a profile whose every untrusted spawn plan — program, argv and
			# the active workspace's directory — an approval covers): the user
			# approved that exact content in the GUI, and the record is the
			# proof a caller cannot forge.
			var profile_tiles: Array[Dictionary] = []
			for td in profile.get("tiles", []):
				if td is Dictionary:
					profile_tiles.append(td)
			if ws._tiles_untrusted(profile_tiles) and not ws._profile_consented(profile):
				return refused(
					"Profile '%s' needs confirmation in the GUI (it starts a different program or passes arguments)"
					% profile_name)
			# Activating a profile resets the active workspace, so a pane
			# holding unsaved work is refused for the same reason: a caller
			# cannot answer the pane's Save/Discard dialog. A running process
			# is not refused — the request to load a layout is consent to stop
			# what the layout replaces — and `ask_running: false` keeps the
			# GUI from raising a dialog this caller cannot answer.
			for pane in ws._pane_bodies(ws._active_workspace()):
				if pane.has_unsaved_state():
					return refused("A pane in the active workspace has unsaved changes; save or discard them in the pane, then retry")
			ws._do_activate(profile, false)
			return {"success": true}
		"layoutList":
			var names = []
			for p in ProfileManager.get_all_profiles():
				names.append(p.get("name", ""))
			return {"layouts": names}
		# `version` and `shutdown` are answered in Rust (`ipc.rs` registers
		# both locally, and never queues them), so an arm here would be dead.
		"conceptList":
			var concepts = ConceptManager.get_concepts()
			return {"concepts": concepts}
		"conceptToggle":
			var concept_name = str(params.get("name", ""))
			if concept_name == "":
				return bad_param("Concept name required")
			# The toggle only knows the merged set; a name it does not hold is a
			# bad parameter (an unknown enum member), and `toggle_concept`
			# writes nothing for it.
			if not ConceptManager.toggle_concept(concept_name):
				return bad_param("Unknown concept: %s" % concept_name)
			ConceptManager._push_to_rust()
			return {"success": true, "name": concept_name}
		_:
			return error("Unknown method: %s" % method, CODE_METHOD_NOT_FOUND)
