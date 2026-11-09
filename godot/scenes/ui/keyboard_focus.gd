extends RefCounted
class_name KeyboardFocus
## One definition of "the control a keyboard user reaches first" under a node,
## and of what a toolbar's keyboard stops are.
##
## `first_reachable` has two callers: an overlay when it takes the keyboard (so
## a typed character lands inside the overlay) and pane chrome when it hands the
## keyboard back to a read-only pane (a wiki pane cannot hold focus itself, so
## its content — the note list or the search field — is where the user
## continues).
##
## `reachable_children` + `ring` are the toolbar pair: pane chrome
## (`TerminalManager._wire_chrome_keyboard`) and the wiki note toolbar
## (`WikiPane._wire_note_toolbar`) build their `focus_next`/`focus_previous`
## rings through them, so a row of actions has one definition of "these stops,
## in this order, wrapping at the ends".
##
## `declare_mouse_only` + `mouse_only_reason` are the third pair: the focus
## audit (`scripts/ui-capture --audit-focus`) cannot tell a deliberately
## mouse-only control from an oversight, so a control that leaves its action to
## a chord or to a field declares the reason on itself. `next_index` is the one
## clamped cursor step, shared by the palette and the terminal's history
## results.

## The controls under `root` that keyboard traversal can visit, in tree order:
## visible, not queued for deletion, not `FOCUS_NONE`, and not a disabled
## button. Container chrome — labels, separators, spacers — is skipped, which
## is what makes a toolbar row's stop list the row's own.
static func reachable_children(root: Node) -> Array:
	var out := []
	for child in root.get_children():
		if not child is Control:
			continue
		var c := child as Control
		if not c.visible or c.is_queued_for_deletion():
			continue
		if c.focus_mode == Control.FOCUS_NONE:
			continue
		if c is BaseButton and (c as BaseButton).disabled:
			continue
		out.append(c)
	return out

## Make `controls` one explicit traversal ring, in the order given (visual
## order): every member is a tab stop, Tab moves to the next and wraps at the
## end, and Shift+Tab moves to the previous one. Without the explicit ring a
## toolbar's stops leak into the neighbouring tile or into the surface below
## it, which is why pane chrome and the wiki note toolbar both come through
## here rather than each spelling out the same two NodePaths.
static func ring(controls: Array) -> void:
	var count := controls.size()
	if count == 0:
		return
	# A one-member ring has nowhere to wrap to: leave the two paths empty so the
	# engine falls back to tree order instead of a self-referential "." path -
	# and clear the paths a larger ring left behind, or a member that just lost
	# its partner (a CLI view's Stop after the child exits) would still be walked
	# to as if it were reachable.
	if count < 2:
		var only := controls[0] as Control
		only.focus_mode = Control.FOCUS_ALL
		only.focus_next = NodePath()
		only.focus_previous = NodePath()
		return
	for i in count:
		var c := controls[i] as Control
		if c == null:
			continue
		c.focus_mode = Control.FOCUS_ALL
		c.focus_next = c.get_path_to(controls[(i + 1) % count])
		c.focus_previous = c.get_path_to(controls[(i - 1 + count) % count])

## The first control under `root`, in tree order, that keyboard traversal can
## reach — the one Tab would land on first. Hidden, disabled and `FOCUS_NONE`
## controls are skipped, and a hidden branch is not searched.
static func first_reachable(root: Control) -> Control:
	for child in root.get_children():
		if not child is Control:
			continue
		var c := child as Control
		if not c.visible or c.is_queued_for_deletion():
			continue
		if c.focus_mode != Control.FOCUS_NONE \
				and not (c is BaseButton and (c as BaseButton).disabled):
			return c
		var nested := first_reachable(c)
		if nested != null:
			return nested
	return null

## The keyboard traversal of `controls`, grouped into the components
## `find_next_valid_focus` forms: `[{"controls": Array, "closed": bool}, …]`, in
## the order each component's first member appears in `controls`.
##
## `closed` is true when the walk returned to its own first member — an explicit
## ring, which is what `ring` builds — and false when it ran into a member
## another component already claimed, or into nothing. One walk from one start
## therefore sees at most one ring, which is why an audit built that way
## reported 5 of the wiki state's 178 controls; this is the whole map.
static func tab_components(controls: Array) -> Array:
	var seen := {}
	var components := []
	for control in controls:
		var start := control as Control
		if start == null or not start.is_inside_tree() or seen.has(start):
			continue
		var component := []
		var cur := start
		var closed := false
		# A component cannot be longer than the list it came from.
		for _i in controls.size() + 1:
			component.append(cur)
			seen[cur] = true
			var nxt := cur.find_next_valid_focus()
			if nxt == null or not nxt.is_inside_tree():
				break
			if nxt == start:
				closed = true
				break
			if seen.has(nxt):
				break
			cur = nxt
		components.append({"controls": component, "closed": closed})
	return components

## The meta a control carries once it declares itself intentionally mouse-only.
const MOUSE_ONLY_META := &"gpty_mouse_only_reason"

## Record that a `FOCUS_NONE` control is mouse-only on purpose, and name the
## keyboard path that does the same thing. `scripts/ui-capture --audit-focus`
## prints such a control with its reason and counts only the undeclared ones as
## unaccounted: without the declaration a mouse-only button is
## indistinguishable from an oversight. An empty reason clears the declaration.
static func declare_mouse_only(control: Control, reason: String) -> void:
	if reason == "":
		control.remove_meta(MOUSE_ONLY_META)
		return
	control.set_meta(MOUSE_ONLY_META, reason)

## The declared reason, or "" when the control is not declared mouse-only.
static func mouse_only_reason(control: Control) -> String:
	if not control.has_meta(MOUSE_ONLY_META):
		return ""
	return str(control.get_meta(MOUSE_ONLY_META))

## The index a list cursor moves to from `current` by `delta`: clamped to
## `0..count-1`, so the ends stay put and holding an arrow cannot tour the list;
## from -1 (nothing selected yet) the first step lands on the first row for a
## positive delta and on the last for a negative one. -1 when there is nothing
## to move over.
static func next_index(current: int, count: int, delta: int) -> int:
	if count <= 0 or delta == 0:
		return -1
	if current < 0:
		return 0 if delta > 0 else count - 1
	return clampi(current + signi(delta), 0, count - 1)
