class_name WorkspaceIpcHandlers
## IPC method dispatch extracted from workspace.gd.
##
## Every handler receives the Workspace instance and stays side-effect
## compatible with the inline version it replaced. New pane-API methods
## land here; keep the smoke script (scripts/smoke_pane_api.py) as the
## end-to-end contract check.


static func error(msg: String, code := -32000) -> Dictionary:
	return {"error": {"code": code, "message": msg}}


## The admin actions `gpty plugin` can take that change the store a running GUI
## reads. Closed vocabulary: the CLI names one, anything else is refused.
const PLUGIN_ADMIN_ACTIONS := ["uninstall", "enable", "disable"]


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
				return error("Vault is not an absolute directory: %s" % vw_vault, -32602)
			var vw_src := str(params.get("src", ""))
			var vw_target := str(params.get("target", ""))
			if not LinkWeights.valid_note_path(vw_src) \
				or not LinkWeights.valid_note_path(vw_target):
				return error(
					"`src` and `target` must be vault-relative note paths (.md, no hidden component)",
					-32602
				)
			var vw_raw = params.get("weight")
			if vw_raw == null or (vw_raw is String and str(vw_raw).strip_edges() == ""):
				var vw_cleared := LinkWeightsStore.clear_weight(vw_vault, vw_src, vw_target)
				if vw_cleared != "":
					return error(vw_cleared)
				return {"vault": vw_vault, "src": vw_src, "target": vw_target, "weight": 0}
			var vw_weight := 0
			if vw_raw is int:
				vw_weight = int(vw_raw)
			elif vw_raw is float:
				vw_weight = int(vw_raw)
			elif vw_raw is String and str(vw_raw).strip_edges().is_valid_int():
				vw_weight = str(vw_raw).strip_edges().to_int()
			else:
				return error(
					"`weight` must be an integer between %d and %d, or omitted to clear"
						% [LinkWeights.MIN_WEIGHT, LinkWeights.MAX_WEIGHT],
					-32602
				)
			if vw_weight < LinkWeights.MIN_WEIGHT or vw_weight > LinkWeights.MAX_WEIGHT:
				return error(
					"`weight` must be between %d and %d" % [
						LinkWeights.MIN_WEIGHT, LinkWeights.MAX_WEIGHT,
					],
					-32602
				)
			var vw_problem := LinkWeightsStore.set_weight(
				vw_vault, vw_src, vw_target, vw_weight
			)
			if vw_problem != "":
				return error(vw_problem)
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
				return error("Unknown plugin action: %s" % pc_action)
			var pc_id := str(params.get("id", ""))
			if not TrustedStore.valid_plugin_id(pc_id):
				return error("Malformed plugin id: %s" % pc_id)
			ProfileManager.refresh_plugin_profiles()
			ConceptManager.refresh_plugin_concepts()
			return {"refreshed": true, "action": pc_action, "id": pc_id}
		"newPane":
			var type_name = str(params.get("type", "terminal"))
			if not PaneTypes.ALL.has(type_name):
				return error("Unknown pane type: %s" % type_name)
			var np_tags: Array = PaneTypes.sanitize_tags(params.get("tags", []))
			var opts: Dictionary
			if type_name == "cli_view":
				# argv, not a shell string: the pane runs the program directly,
				# so `command` is the program and `args` its argument vector.
				opts = {
					"command": PaneTypes.sanitize_shell(params.get("command"), ""),
					"shell_args": PaneTypes.sanitize_shell_args(params.get("args", [])),
					"tags": np_tags,
				}
			else:
				var shell: String = PaneTypes.sanitize_shell(
					params.get("command"), SettingsManager.cfg_shell_command)
				opts = {"shell_command": shell, "tags": np_tags}
			var body = ws._spawn_pane(type_name, opts)
			if body == null:
				return error("Grid is full")
			GptyTerminal.emit_event(JSON.stringify({"type": "pane", "event": "spawned", "pane_id": body.attachment_id, "label": body.pane_label}))
			return {"pane_id": body.attachment_id, "label": body.pane_label, "type": type_name}
		"paneRead":
			var pr_body = ws._find_pane_by_label(str(params.get("pane_id", "")))
			var pr_lines = clampi(int(params.get("lines", 200)), 1, 2000)
			if pr_body is TerminalPane:
				return {"text": str(pr_body._terminal.get_plain_text(pr_lines))}
			if pr_body is CliViewPane:
				# A cli_view has no terminal buffer; its body text is the
				# drained child output the pane already displays.
				return {"text": pr_body.get_text(pr_lines)}
			return error("Pane '%s' not found" % params.get("pane_id", ""))
		"paneStatus":
			# No target = every pane's status (the CLI's no-argument mode and
			# the MCP tool's): one document, built here where the pane list and
			# the status primitives already live. Non-terminal panes have no
			# status primitives — they are listed with `status: null` rather
			# than dropped, so the answer covers every pane the list named.
			var ps_target := str(params.get("pane_id", ""))
			if ps_target == "":
				var ps_panes := []
				for t in ws._tm.tiles:
					var ps_any = ws._tm._find_body(t.wrapper)
					if ps_any == null:
						continue
					var ps_entry := {
						"pane_id": ps_any.attachment_id,
						"label": ps_any.pane_label,
						"type": ps_any._pane_type(),
						"status": null,
					}
					if ps_any is TerminalPane:
						var ps_all = JSON.parse_string(str(ps_any._terminal.get_status()))
						if ps_all is Dictionary:
							ps_entry["status"] = ps_all
					ps_panes.append(ps_entry)
				return {"panes": ps_panes}
			var ps_body = ws._find_pane_by_label(ps_target)
			if ps_body == null:
				return error("Pane '%s' not found" % ps_target)
			# Existing but not a terminal: the pane is real, it just has no
			# status primitives. Say that instead of "not found", which sent
			# an agent looking for a pane it can already see in listPanes.
			if not (ps_body is TerminalPane):
				return error("Pane '%s' has no status (not a terminal)" % ps_target)
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
			# command is an argument, never the program itself, and the
			# run flag follows the shell family (`cmd.exe` takes `/c`).
			var run_body = ws._spawn_pane("terminal", {
				"shell_command": SettingsManager.cfg_shell_command,
				"shell_args": PaneTypes.shell_run_args(SettingsManager.cfg_shell_command, run_cmd),
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
			# A caller cannot answer a dialog, so a pane holding unsaved work
			# is refused rather than asked (the rule `layoutLoad` already
			# applies to an untrusted profile): naming a pane is not consent
			# to throw away what the user typed into it.
			if kp_target.has_unsaved_state():
				return error("Pane '%s' has unsaved changes; save or discard them in the pane, then retry" % kp_pane_id)
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
			# untrusted profiles are refused here — unless the consent memory
			# already covers them (a builtin approved at this app version, or
			# a profile whose every untrusted spawn plan an approval covers):
			# the user approved that exact content in the GUI, and the record
			# is the proof a caller cannot forge.
			var profile_tiles: Array[Dictionary] = []
			for td in profile.get("tiles", []):
				if td is Dictionary:
					profile_tiles.append(td)
			if ws._tiles_untrusted(profile_tiles) and not ws._profile_consented(profile):
				return error(
					"Profile '%s' needs confirmation in the GUI (it starts a different program or passes arguments)"
					% profile_name)
			# Activating a profile resets the active workspace, so a pane
			# holding unsaved work is refused for the same reason: a caller
			# cannot answer the pane's Save/Discard dialog.
			for pane in ws._pane_bodies(ws._active_workspace()):
				if pane.has_unsaved_state():
					return error("A pane in the active workspace has unsaved changes; save or discard them in the pane, then retry")
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
