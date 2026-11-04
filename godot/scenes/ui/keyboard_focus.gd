extends RefCounted
class_name KeyboardFocus
## One definition of "the control a keyboard user reaches first" under a node:
## the first descendant keyboard traversal can visit, in tree order.
##
## Two callers share it: an overlay when it takes the keyboard (so a typed
## character lands inside the overlay) and pane chrome when it hands the
## keyboard back to a read-only pane (a wiki pane cannot hold focus itself, so
## its content — the note list or the search field — is where the user
## continues).

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
