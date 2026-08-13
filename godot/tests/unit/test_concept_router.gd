extends GutTest
# Unit tests for ConceptRouter — pure concept-capture routing extracted
# from workspace.gd. Mocks replace the GDExtension-bound terminal.

class MockReceiver:
	extends Control

	var type_name := "code_viewer"
	var received := ""

	func _pane_type() -> String:
		return type_name

	func receive_content(t: String):
		received = t


class MockTerminal:
	extends RefCounted

	var acked: Array = []
	var flushed: Array = []

	func acknowledge_capture(id):
		acked.append(id)

	func flush_capture(id):
		flushed.append(id)


class PlainPane:
	extends Control

	func _pane_type() -> String:
		return "code_viewer"


func _receiver(type_name: String) -> MockReceiver:
	var r = MockReceiver.new()
	r.type_name = type_name
	return r


func _event() -> Dictionary:
	return {"target_pane_type": "code_viewer", "lines": PackedStringArray(["a", "b"]), "id": 7}


func test_routes_to_matching_receiver():
	var receiver = _receiver("code_viewer")
	var term = MockTerminal.new()
	var ok: bool = ConceptRouter.route_capture_event(
		[receiver] as Array[Control], _event(), term)
	assert_true(ok, "route should succeed when a receiver exists")
	assert_eq(receiver.received, "a\nb", "receiver should get joined lines")
	assert_eq(term.acked, [7], "source terminal should acknowledge")
	assert_eq(term.flushed, [], "nothing should be flushed")
	receiver.free()


func test_flushes_when_no_receiver():
	var receiver = _receiver("observer")
	var term = MockTerminal.new()
	var ok: bool = ConceptRouter.route_capture_event(
		[receiver] as Array[Control], _event(), term)
	assert_false(ok, "route should fail when no matching receiver exists")
	assert_eq(term.flushed, [7], "source terminal should flush the capture")
	assert_eq(term.acked, [], "nothing should be acknowledged")
	assert_eq(receiver.received, "", "non-matching receiver must not get content")
	receiver.free()


func test_skips_bodies_without_receive_content():
	# A body with the right pane type but no receive_content method is
	# not a valid receiver.
	var plain = PlainPane.new()
	var term = MockTerminal.new()
	var ok: bool = ConceptRouter.route_capture_event(
		[plain] as Array[Control], _event(), term)
	assert_false(ok, "body without receive_content must not be a receiver")
	assert_eq(term.flushed, [7])
	plain.free()
