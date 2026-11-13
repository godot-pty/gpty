class_name A11yContent
extends Control
## A published accessible content node — see `A11y.publish`.
##
## The role and value `A11y.set_text` queues are written from this control's own
## accessibility update, the only place 4.7.2's server accepts them. A bare
## `Control` keeps the container role the engine creates every element with,
## and AccessKit drops a named container from the exposed tree (measured
## 2026-11-13: the terminal's published slot appeared as an unnamed node with a
## `Label`, and not at all with a bare `Control`, while the pane body's
## role-carrying element reads its `accessibility_name` back intact). A
## `Label` cannot carry the content either: its AT-SPI name is its display
## text, which would put the whole screen through text shaping (992 ms for
## 221x78, measured 2026-11-11).
##
## Nothing about this node is visible or interactive: `A11y.publish` sets it to
## 1x1, transparent, unfocusable and pointer-transparent.

func _notification(what: int) -> void:
	if what == NOTIFICATION_ACCESSIBILITY_UPDATE:
		A11y.apply_update(self)
