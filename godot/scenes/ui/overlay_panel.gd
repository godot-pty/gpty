extends Control
class_name OverlayPanel
## Base for the workspace overlays that own the keyboard while they are open:
## the Settings panel, Pane Settings, the command palette and the concept graph
## editor.
##
## One contract, from the v0.8.0 finding "An open overlay neither takes keyboard
## focus nor blocks the terminal behind it":
##
##  - `open()` shows the overlay and takes the keyboard: it remembers who had
##    focus and focuses a control inside (`KeyboardFocus.first_reachable`), so a
##    typed character lands here instead of in the terminal behind it (a
##    terminal only reads keys while it owns focus).
##  - `Workspace` handles Escape in `_input`, a stage no `_gui_input` can
##    pre-empt, and calls `close()`. A focused terminal can therefore never turn
##    Escape into the raw ESC byte it would otherwise send its child.
##  - `close()` hides the overlay and, when the overlay still owned the
##    keyboard, emits `keyboard_released` so `Workspace` puts focus back where
##    it was. A close caused by a click elsewhere does not emit: that click
##    already decided where the keyboard goes.
##
## A subclass overrides `_initial_focus()` to name a cursor, `_before_open()` to
## build content the focus target needs, and `_before_close()` to save or veto.

## The overlay hid while it still owned the keyboard.
signal keyboard_released

## Who held the keyboard when this overlay took it; where `close()` gives it
## back to.
var return_focus: Control = null

## Show this overlay and take the keyboard. The one entry point: an overlay is
## never shown by a bare `visible = true`, because that path would leave the
## keyboard on the pane behind it.
func open() -> void:
	_before_open()
	grab_keyboard()

## Take the keyboard without rebuilding content: remember who had it and focus
## a control inside, so a typed character lands here instead of in the terminal
## behind it. An overlay that is already visible calls this when a stacked
## overlay closes and the keyboard comes back to it (`Workspace`).
func grab_keyboard() -> void:
	var vp := get_viewport()
	return_focus = vp.gui_get_focus_owner() if vp != null else null
	visible = true
	var target := _initial_focus()
	if target == null or not target.is_visible_in_tree():
		target = KeyboardFocus.first_reachable(self)
	if target != null:
		target.grab_focus()

## Build or refresh what the overlay shows before focus moves into it. The
## concept editor reloads its canvas here.
func _before_open() -> void:
	pass

## The control a typed character should reach first. The default is the first
## reachable descendant; an overlay with a natural cursor overrides it.
func _initial_focus() -> Control:
	return null

## Hide this overlay. A subclass with work to lose overrides `_before_close()`.
func close() -> void:
	if not visible:
		return
	if not _before_close():
		return
	var vp := get_viewport()
	var owner := vp.gui_get_focus_owner() if vp != null else null
	var owned := owner == null or owner == self or is_ancestor_of(owner)
	visible = false
	_after_close()
	if owned:
		keyboard_released.emit()

## Return false to keep the overlay open (the concept editor asks before
## dropping rules it could not save). Runs before anything is hidden.
func _before_close() -> bool:
	return true

## Release state that only makes sense while the overlay is visible.
func _after_close() -> void:
	pass
