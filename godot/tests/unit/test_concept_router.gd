extends GutTest
# Unit tests for ConceptRouter — pure concept-capture routing extracted
# from workspace.gd. Mocks replace the GDExtension-bound terminal.

class MockReceiver:
	extends Control

	var type_name := "code_viewer"
	var received := ""
	var capable := true
	var accepts_delivery := true

	func _pane_type() -> String:
		return type_name

	func can_receive_content(_event: Dictionary = {}) -> bool:
		return capable

	func receive_content(t: String, _event: Dictionary = {}) -> bool:
		received = t
		return accepts_delivery


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
	var receiver = _receiver("inspector")
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


func test_declining_receiver_falls_through_to_next_match():
	var thinking = _receiver("code_viewer")
	thinking.capable = false
	var answer = _receiver("code_viewer")
	var term = MockTerminal.new()

	var ok: bool = ConceptRouter.route_capture_event(
		[thinking, answer] as Array[Control], _event(), term)

	assert_true(ok)
	assert_eq(thinking.received, "", "declining pane must not consume content")
	assert_eq(answer.received, "a\nb", "next capable pane should receive content")
	assert_eq(term.acked, [7], "successful delivery acknowledges exactly once")
	assert_eq(term.flushed, [])
	thinking.free()
	answer.free()


func test_failed_delivery_falls_through_to_next_match():
	var failed = _receiver("code_viewer")
	failed.accepts_delivery = false
	var fallback = _receiver("code_viewer")
	var term = MockTerminal.new()

	var ok: bool = ConceptRouter.route_capture_event(
		[failed, fallback] as Array[Control], _event(), term)

	assert_true(ok)
	assert_eq(failed.received, "a\nb")
	assert_eq(fallback.received, "a\nb")
	assert_eq(term.acked, [7])
	assert_eq(term.flushed, [])
	failed.free()
	fallback.free()


func test_flushes_when_all_matching_receivers_decline():
	var thinking = _receiver("code_viewer")
	thinking.capable = false
	var term = MockTerminal.new()

	var ok: bool = ConceptRouter.route_capture_event(
		[thinking] as Array[Control], _event(), term)

	assert_false(ok)
	assert_eq(term.acked, [])
	assert_eq(term.flushed, [7], "declined capture must return to the terminal")
	thinking.free()

func test_legacy_observer_target_does_not_route_to_inspector():
	var inspector = _receiver("inspector")
	var term = MockTerminal.new()
	var ev := _event()
	ev["target_pane_type"] = "observer"

	var ok: bool = ConceptRouter.route_capture_event(
		[inspector] as Array[Control], ev, term)

	assert_false(ok, "legacy observer target must not reach inspector")
	assert_eq(inspector.received, "")
	assert_eq(term.flushed, [7])
	inspector.free()
