extends BasePersistenceManager
# TrustedStore — the consent memory behind the Workspace Trust dialog.
#
# `user://trusted.json` remembers approvals so consent made once counts once:
# the sidebar profile gate, the workspace-restore gate, and the IPC layoutLoad
# gate consult it instead of re-asking forever (or refusing, over IPC) for
# content the user already approved.
#
# Two namespaces, both keyed by content identity + version:
#   builtins: profile name -> {version: app version, plans: [spawn-plan keys]}
#     A builtin ships with the app, so its version is the app version: a new
#     gpty release re-prompts. The plans are what the approval actually
#     covers — a workspace saved from an approved builtin restores without a
#     dialog because every tile's exact program+argv was approved.
#   plugins: plugin id -> pinned revision
#     Written when the install review dialog is accepted. A new revision
#     re-prompts. (The profile-activation side of this record activates when
#     installed-plugin profiles surface — the profiles-migration item.)
#
# Only the trust dialogs' confirm paths write here: a builtin approval from
# the profile dialog, a plugin approval from the install review. User-authored
# profiles and layout files never record consent — content that arrived any
# other way keeps today's behavior (it asks again each time).
#
# The file is hand-editable, so the loader is the same boundary as every
# other store: typed reads, shape/pattern checks, and caps — a bad entry
# costs itself, not the file.

const TRUSTED_FILE := "user://trusted.json"

## Caps for hand-edited file content.
const MAX_ENTRIES := 128
const MAX_NAME_LEN := 128
const MAX_VERSION_LEN := 32
const MIN_REVISION_LEN := 7
const MAX_REVISION_LEN := 64
const MAX_PLANS := 64
const MAX_PLAN_KEY_LEN := 8192

var _builtins: Dictionary = {}
var _plugins: Dictionary = {}

func _on_init():
	reload()

func reload():
	_builtins = {}
	_plugins = {}
	var d = _read_file(TRUSTED_FILE)
	var builtins := _as_dict(d, "builtins", {})
	for key in builtins:
		if not (key is String) or not _valid_name(key):
			continue
		if _builtins.size() >= MAX_ENTRIES:
			break
		var entry = builtins[key]
		if not (entry is Dictionary):
			continue
		var version := _as_string(entry, "version", "")
		if not _valid_version(version):
			continue
		var plans_raw = entry.get("plans", [])
		var plans: Array = []
		if plans_raw is Array:
			for p in plans_raw:
				if p is String and not p.is_empty() and p.length() <= MAX_PLAN_KEY_LEN:
					plans.append(p)
				if plans.size() >= MAX_PLANS:
					break
		_builtins[key] = {"version": version, "plans": plans}
	var plugins := _as_dict(d, "plugins", {})
	for key in plugins:
		if not (key is String) or not valid_plugin_id(key):
			continue
		if _plugins.size() >= MAX_ENTRIES:
			break
		var revision := _as_string(plugins, key, "")
		if not _valid_revision(revision):
			continue
		_plugins[key] = revision

## A builtin profile approved at exactly this app version.
func is_builtin_approved(p_name: String, version: String) -> bool:
	var entry = _builtins.get(p_name)
	return entry is Dictionary and str(entry.get("version", "")) == version

## Record a builtin approval: the profile name, the app version it shipped
## with, and the spawn plans it covers. Overwrites any older approval.
func approve_builtin(p_name: String, version: String, plans: Array):
	if not _valid_name(p_name) or not _valid_version(version):
		return
	if _builtins.size() >= MAX_ENTRIES and not _builtins.has(p_name):
		return
	var capped: Array = []
	for p in plans:
		if p is String and not p.is_empty() and p.length() <= MAX_PLAN_KEY_LEN:
			capped.append(p)
		if capped.size() >= MAX_PLANS:
			break
	_builtins[p_name] = {"version": version, "plans": capped}
	_save()

## The plans an approval of `p_name` at `version` covers; empty when the
## approval is absent or from another version (stale content re-prompts).
func builtin_plans(p_name: String, version: String) -> Array:
	var entry = _builtins.get(p_name)
	if entry is Dictionary and str(entry.get("version", "")) == version:
		var plans = entry.get("plans", [])
		return plans if plans is Array else []
	return []

## A plugin approved at exactly this pinned revision.
func is_plugin_approved(p_id: String, revision: String) -> bool:
	return str(_plugins.get(p_id, "")) == revision

## Record a plugin install-review acceptance. Overwrites any older revision.
func approve_plugin(p_id: String, revision: String):
	if not valid_plugin_id(p_id) or not _valid_revision(revision):
		return
	if _plugins.size() >= MAX_ENTRIES and not _plugins.has(p_id):
		return
	_plugins[p_id] = revision
	_save()

## Every spawn-plan key a builtin approval at this app version covers.
## The restore gate asks "was this exact program+argv approved?" — a tile
## whose key is absent keeps today's prompt-every-time behavior.
func approved_plan_keys(version: String) -> Dictionary:
	var keys := {}
	for name in _builtins:
		var entry = _builtins[name]
		if entry is Dictionary and str(entry.get("version", "")) == version:
			for p in entry.get("plans", []):
				keys[p] = true
	return keys

func _save():
	_write_file(TRUSTED_FILE, {"builtins": _builtins, "plugins": _plugins})

## Profile names follow layoutSave's own cap.
static func _valid_name(name: String) -> bool:
	return not name.is_empty() and name.length() <= MAX_NAME_LEN

## App versions are `X.Y.Z` today; the check stays permissive so a version
## format change costs nothing here, and hostile content cannot smuggle
## control characters into a comparison key.
static func _valid_version(version: String) -> bool:
	if version.is_empty() or version.length() > MAX_VERSION_LEN:
		return false
	for ch in version:
		if (
			not ch.is_valid_int()
			and not (ch >= "a" and ch <= "z")
			and not (ch >= "A" and ch <= "Z")
			and ch != "."
			and ch != "_"
			and ch != "-"
		):
			return false
	return true

## The manifest's own `owner/name` shape, mirrored from
## `plugin_manifest.rs::valid_plugin_id` (which remains authoritative: it is
## what gates a write to the store).
##
## Public because it has two consumers on this side of the boundary — the
## consent records keyed by plugin id here, and the `pluginsChanged` notice
## the CLI fires after an admin action (`ipc_handlers.gd`). One mirror, not
## two: a second copy of the shape is how the GUI's idea of a valid id drifts
## from the CLI's.
static func valid_plugin_id(id: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9-]{1,63}/[a-z0-9-]{1,63}$")
	return re.search(id) != null

## The store's revision shape (git commit ids), mirrored from plugin_store.rs.
static func _valid_revision(revision: String) -> bool:
	var re := RegEx.create_from_string("^[a-z0-9._-]{%d,%d}$" % [MIN_REVISION_LEN, MAX_REVISION_LEN])
	return re.search(revision) != null
