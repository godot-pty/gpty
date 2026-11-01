extends BasePersistenceManager
# VaultRegistry — the user's own list of vault roots.
#
# `user://vaults.json` is the ONLY place a directory becomes one the control
# socket's vault verbs may look inside:
#
#     {"roots": ["/home/me/notes", "/home/me/work/notes"]}
#
# `vaultSearch`, `vaultRead` and `vaultWeight` take a `vault_path` from the
# caller, so without a list they are a file-read primitive over any directory a
# client names: a same-user process could read those files anyway, but a
# prompt-injected agent confined to gPTY's own tools could not. The list closes
# that gap - the verbs answer only inside a root the user registered, and the
# refusal says so.
#
# The pane settings UI is the only writer (Workspace's `settings_applied`
# handler, the same single write path `PaneEnvStore` and `PaneInspectorStore`
# use). Nothing else can add an entry: not a layout, a profile, a plugin, an
# IPC call or the act of creating a Wiki pane, so a file or an agent cannot
# widen the list for the next question. The shipped knowledge base is the one
# exception, and it is app-supplied rather than file-supplied: a Wiki pane that
# resolves `KnowledgeStore.TOKEN` registers the resolved directory itself.
#
# `gpty-gdext` mirrors this list in process memory for the two native handlers
# (they run on the blocking pool, outside GDScript); [`method _push_to_rust`]
# is the one direction and runs after every load and write group.
#
# The file is hand-editable, so the loader is the same boundary as every other
# store: typed reads, the vault path vocabulary, one entry per spelling, and a
# cap - a bad entry costs itself, not the file.

const VAULTS_FILE := "user://vaults.json"

## Vault roots the user has registered, normalized, in registration order.
var _roots: Array[String] = []

func _on_init():
	reload()

func reload():
	_roots = []
	var d := _read_file(VAULTS_FILE)
	for raw in _as_array(d, "roots", []):
		if _roots.size() >= LinkWeights.MAX_VAULTS:
			break
		if not (raw is String):
			continue
		var root := LinkWeights.normalize_vault(str(raw))
		if not LinkWeights.valid_vault_path(root) or _roots.has(root):
			continue
		_roots.append(root)
	_push_to_rust()

## Every registered root, normalized. A copy: a caller must not be able to
## append to the list the handlers answer from.
func roots() -> Array[String]:
	return _roots.duplicate()

## Register one root. False when the value is not an absolute vault path, does
## not name a directory, or the list is full - the caller (the pane settings
## UI) shows the refusal rather than storing a root that can never answer.
func register(root: String) -> bool:
	var normalized := LinkWeights.normalize_vault(root)
	if not LinkWeights.valid_vault_path(normalized):
		return false
	if not DirAccess.dir_exists_absolute(normalized):
		return false
	if _roots.has(normalized):
		return true
	if _roots.size() >= LinkWeights.MAX_VAULTS:
		return false
	_roots.append(normalized)
	_write_file(VAULTS_FILE, {"roots": _roots})
	_push_to_rust()
	return true

## Whether the control socket's vault verbs may answer for `root`. The shipped
## knowledge base becomes an ordinary entry when a Wiki pane opens it (the
## pane calls [`method register`]), so this stays a pure lookup.
func has_root(root: String) -> bool:
	var normalized := LinkWeights.normalize_vault(root)
	return normalized != "" and _roots.has(normalized)

## Replace the native handlers' mirror with this list. `clear` first so a root
## removed by a hand edit of the file stops answering in the same process.
func _push_to_rust() -> void:
	# `--import` and other extension-less runs have no handler to mirror to.
	if not ClassDB.class_exists("GptyTerminal"):
		return
	GptyTerminal.vault_clear_roots()
	for root in _roots:
		GptyTerminal.vault_register_root(root)
