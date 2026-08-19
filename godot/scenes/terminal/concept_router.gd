class_name ConceptRouter
# Pure routing for captured concept output. Extracted from workspace.gd
# so the decision logic is unit-testable without the GDExtension-bound
# Workspace class.
#
# Receivers explicitly advertise capability and confirm successful delivery.
# A matching pane may decline because of its role or runtime state; routing
# continues until one accepts. The source is acknowledged only after success.
# The toast on a failed route stays in workspace.gd (UI glue, not logic).

static func route_capture_event(bodies: Array[Control], ev: Dictionary, source_term) -> bool:
	var target_type: String = str(ev.get("target_pane_type", ""))
	var lines: PackedStringArray = ev.get("lines", PackedStringArray())
	var text := "\n".join(lines)
	for receiver in _matching_receivers(bodies, target_type):
		if receiver.can_receive_content(ev) and receiver.receive_content(text, ev):
			source_term.acknowledge_capture(ev.get("id", 0))
			return true
	source_term.flush_capture(ev.get("id", 0))
	return false

static func _matching_receivers(bodies: Array[Control], type_name: String) -> Array[Control]:
	var matches: Array[Control] = []
	for body in bodies:
		if (
			body != null
			and body.has_method("_pane_type")
			and body._pane_type() == type_name
			and body.has_method("can_receive_content")
			and body.has_method("receive_content")
		):
			matches.append(body)
	return matches
