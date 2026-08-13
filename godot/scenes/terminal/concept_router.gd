class_name ConceptRouter
# Pure routing for captured concept output. Extracted from workspace.gd
# so the decision logic is unit-testable without the GDExtension-bound
# Workspace class.
#
# Receivers are pane bodies with a `receive_content(text)` method whose
# `_pane_type()` matches the event's `target_pane_type`. The toast on a
# failed route stays in workspace.gd (ToastManager is UI glue, not logic).

static func route_capture_event(bodies: Array[Control], ev: Dictionary, source_term) -> bool:
	var target_type: String = ev.get("target_pane_type", "")
	var lines: PackedStringArray = ev.get("lines", PackedStringArray())
	var receiver = _find_receiver(bodies, target_type)
	if receiver != null:
		receiver.receive_content("\n".join(lines))
		source_term.acknowledge_capture(ev.get("id", 0))
		return true
	source_term.flush_capture(ev.get("id", 0))
	return false

static func _find_receiver(bodies: Array[Control], type_name: String) -> Control:
	for body in bodies:
		if body != null and body._pane_type() == type_name and body.has_method("receive_content"):
			return body
	return null
