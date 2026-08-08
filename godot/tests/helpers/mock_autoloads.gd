class_name MockAutoloads
# Test helper: overrides autoload singletons to use in-memory storage.
# Call setup() before each test, teardown() after each test.
#
# Uses set_script() to replace the script on existing autoload nodes.
# This preserves the global name bindings (SettingsManager, etc.) while
# redirecting _read_file/_write_file to an in-memory Dictionary.
#
# File I/O never touches disk — all reads/writes go to the shared _store.

# ── In-memory storage ──────────────────────────────────────────────────

static var _store: Dictionary = {}
static var _original_scripts: Dictionary = {}

static func set_store(key: String, value):
	_store[key] = value

static func get_store(key: String):
	return _store.get(key, {})

# ── Setup / teardown ───────────────────────────────────────────────────

static func setup():
	_store.clear()
	_original_scripts.clear()

	_override_script("SettingsManager", _MockSettingsManager)
	_override_script("ProfileManager", _MockProfileManager)
	_override_script("LayoutManager", _MockLayoutManager)
	_override_script("ConceptManager", _MockConceptManager)

	# For node-only autoloads, just ensure they're valid nodes
	# (they exist from project.godot autoload registration)

static func teardown():
	_restore_script("ConceptManager")
	_restore_script("SettingsManager")
	_restore_script("ProfileManager")
	_restore_script("LayoutManager")
	_store.clear()
	_original_scripts.clear()

static func _override_script(name: String, mock_class):
	var root = Engine.get_main_loop().root
	var node = root.get_node(name)
	_original_scripts[name] = node.get_script()
	node.set_script(mock_class)

static func _restore_script(name: String):
	var root = Engine.get_main_loop().root
	var node = root.get_node_or_null(name)
	if node and _original_scripts.has(name):
		node.set_script(_original_scripts[name])

# ── Mock subclasses ────────────────────────────────────────────────────

class _MockSettingsManager extends "res://scenes/autoloads/settings_manager.gd":
	func _read_file(path: String) -> Dictionary:
		return MockAutoloads.get_store(path)
	func _write_file(path: String, data: Dictionary):
		MockAutoloads.set_store(path, data)
	func _on_init():
		# Skip loading from disk during _ready
		pass

class _MockProfileManager extends "res://scenes/autoloads/profile_manager.gd":
	func _read_file(path: String) -> Dictionary:
		return MockAutoloads.get_store(path)
	func _write_file(path: String, data: Dictionary):
		MockAutoloads.set_store(path, data)
	func _on_init():
		pass

class _MockLayoutManager extends "res://scenes/autoloads/layout_manager.gd":
	func _read_file(path: String) -> Dictionary:
		return MockAutoloads.get_store(path)
	func _write_file(path: String, data: Dictionary):
		MockAutoloads.set_store(path, data)
	func _on_init():
		pass


class _MockConceptManager extends "res://scenes/autoloads/concept_manager.gd":
	func _read_file(path: String) -> Dictionary:
		return MockAutoloads.get_store(path)
	func _write_file(path: String, data: Dictionary):
		MockAutoloads.set_store(path, data)
	func _on_init():
		pass