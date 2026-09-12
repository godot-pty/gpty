class_name WorkspaceIpcHandlers
## IPC method dispatch extracted from workspace.gd.
##
## Every handler receives the Workspace instance and stays side-effect
## compatible with the inline version it replaced. New pane-API methods
## land here; keep the smoke script (scripts/smoke-pane-api) as the
## end-to-end contract check.


static func error(msg: String, code := -32000) -> Dictionary:
	return {"error": {"code": code, "message": msg}}


static func handle(ws, method: String, params: Dictionary):
	match method:
		"newPane":
			var type_name = str(params.get("type", "terminal"))
			if not PaneTypes.ALL.has(type_name):
				return error("Unknown pane type: %s" % type_name)
			var shell: String = PaneTypes.sanitize_shell(
				params.get("command"), SettingsManager.cfg_shell_command)
			var np_tags: Array = PaneTypes.sanitize_tags(params.get("tags", []))
			var body = ws._spawn_pane(type_name, {"shell_command": shell, "tags": np_tags})
			if body == null:
				return error("Grid is full")
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "spawned", "pane_id": body.attachment_id, "label": body.pane_label}))
			return {"pane_id": body.attachment_id, "label": body.pane_label, "type": type_name}
		"paneRead":
			var pr_body = ws._find_pane_by_label(str(params.get("pane_id", "")))
			if pr_body == null or not (pr_body is TerminalPane):
				return error("Pane '%s' not found" % params.get("pane_id", ""))
			var pr_lines = int(params.get("lines", 200))
			return {"text": str(pr_body._terminal.get_plain_text(clampi(pr_lines, 1, 2000)))}
		"paneStatus":
			var ps_body = ws._find_pane_by_label(str(params.get("pane_id", "")))
			if ps_body == null or not (ps_body is TerminalPane):
				return error("Pane '%s' not found" % params.get("pane_id", ""))
			var ps_status = JSON.parse_string(str(ps_body._terminal.get_status()))
			if not (ps_status is Dictionary):
				return error("Pane status unavailable")
			return ps_status
		"paneRun":
			var run_cmd := str(params.get("command", "")).strip_edges()
			if run_cmd == "":
				return error("Command required")
			if run_cmd.length() > 1024 or run_cmd.contains("\uFFFD"):
				return error("Invalid command")
			# Execute through the configured shell so compound commands
			# (&&, pipes, globs) work like a normal CLI invocation. The
			# command is an argument, never the program itself.
			var run_body = ws._spawn_pane("terminal", {
				"shell_command": SettingsManager.cfg_shell_command,
				"shell_args": ["-c", run_cmd],
			})
			if run_body == null:
				return error("Grid is full")
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
				kp_target = ws._find_pane_by_label(kp_pane_id)
			if kp_target == null:
				return error("Pane '%s' not found" % kp_pane_id)
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "killed", "pane_id": kp_target.attachment_id, "label": kp_target.pane_label}))
			ws._kill(kp_target)
			return {"success": true}
		"focusPane":
			var pane_id = str(params.get("pane_id", ""))
			var body = ws._find_pane_by_label(pane_id)
			if body == null:
				return error("Pane '%s' not found" % pane_id)
			# The same activation a click or a sidebar row performs: the pane
			# becomes the active one, and only a pane that can hold keyboard
			# focus takes it (a read-only pane must not swallow keys).
			ws.activate_pane(body)
			return {"success": true}
		"inject":
			var pane_id = str(params.get("pane_id", ""))
			var text = str(params.get("text", ""))
			if text.length() > 65536:
				return error("Injected text exceeds 64 KiB limit")
			var body = ws._find_pane_by_label(pane_id)
			if body == null:
				return error("Pane '%s' not found" % pane_id)
			if not body is TerminalPane:
				return error("Pane '%s' is not a terminal" % pane_id)
			body._terminal.send_line(text)
			return {"success": true}
		"broadcast":
			var b_tags: Array = PaneTypes.sanitize_tags(params.get("tags", []))
			var b_text = str(params.get("text", ""))
			if b_tags.is_empty() or b_text == "" or b_text.length() > 65536:
				return error("Invalid broadcast request")
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
					b_body._terminal.send_line(b_text)
					b_count += 1
			return {"success": true, "count": b_count}
		"layoutSave":
			var profile_name = str(params.get("name", ""))
			if profile_name == "":
				return error("Profile name required")
			if profile_name.length() > 128:
				return error("Profile name too long")
			ProfileManager.add_profile(profile_name, ws._gather_tiles())
			return {"success": true, "name": profile_name}
		"layoutLoad":
			var profile_name = str(params.get("name", ""))
			var profile := ProfileManager.find_profile(profile_name)
			if profile.is_empty():
				return error("Profile '%s' not found" % profile_name)
			# Restoring a profile can start a different program, pass argv, or set
			# an environment — the same decision the sidebar gates behind the
			# Workspace Trust dialog. A caller cannot answer that dialog, and
			# naming the profile is not consent to what a file asks for, so
			# untrusted profiles are refused here and the user activates them in
			# the GUI.
			var profile_tiles: Array[Dictionary] = []
			for td in profile.get("tiles", []):
				if td is Dictionary:
					profile_tiles.append(td)
			if ws._tiles_untrusted(profile_tiles):
				return error(
					"Profile '%s' needs confirmation in the GUI (it starts a different program, passes arguments, or sets an environment)"
					% profile_name)
			ws._do_activate(profile)
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
				return error("Concept name required")
			ConceptManager.toggle_concept(concept_name)
			ConceptManager._push_to_rust()
			return {"success": true, "name": concept_name}
		_:
			return error("Unknown method: %s" % method, -32601)
