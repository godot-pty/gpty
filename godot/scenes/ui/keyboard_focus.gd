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
