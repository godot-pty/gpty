class_name NavHistory
extends RefCounted
## A bounded back/forward trail of string keys.
##
## This is the About tab's document history, kept pure so it needs no scene
## tree: the owner decides what an entry means and renders it, and this class
## only owns the cursor. It is deliberately generic (a future wiki-pane note
## history is the intended second consumer), which is why it knows nothing
## about documents or the bundle.
##
## Two rules are the reason it is not a plain array:
##
##  - **The root is pinned.** The first entry never leaves, whatever the cap;
##    overflow drops the *second* entry instead. A document viewer can then
##    promise that holding Back reaches its home page in a bounded number of
##    clicks (the About tab's home is the README).
##  - **A new page truncates the forward tail.** Pushing while the cursor is
##    behind the end discards everything after it, the way a browser does, so
##    the forward list can never grow past the cap either.

const CAP := 64

var _root := ""
var _cap := CAP
var _entries := PackedStringArray()
var _index := -1

## `root` is the entry that must always stay at the front; pass `""` for a
## history with no home page (then overflow drops the oldest entry).
func _init(root := "", cap := CAP) -> void:
	_root = root
	_cap = maxi(1, cap)
	if root != "":
		_entries.append(root)
		_index = 0

func current() -> String:
	return _entries[_index] if _index >= 0 else ""

func size() -> int:
	return _entries.size()

func can_back() -> bool:
	return _index > 0

func can_forward() -> bool:
	return _index >= 0 and _index < _entries.size() - 1

## Append a page after the cursor. An empty entry and a repeat of the current
## page are no-ops, so opening the same document twice cannot double a step.
func push(entry: String) -> void:
	if entry == "" or entry == current():
		return
	if _index < _entries.size() - 1:
		_entries.resize(_index + 1)
	_entries.append(entry)
	_index = _entries.size() - 1
	while _entries.size() > _cap:
		# The pinned root is never the entry dropped; otherwise the oldest goes.
		_entries.remove_at(1 if _root != "" else 0)
		_index -= 1

## Step one page back, answering the page now current (`""` when there is none,
## and the cursor does not move).
func back() -> String:
	if not can_back():
		return ""
	_index -= 1
	return current()

## Step one page forward, same contract.
func forward() -> String:
	if not can_forward():
		return ""
	_index += 1
	return current()
