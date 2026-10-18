extends BasePersistenceManager
# LinkWeightsStore — the user's declared link weights, the authored layer over
# the link graph's measured mention counts.
#
# `user://link_weights.json` is the only place a declaration lives:
#
#     {"vaults": {"/abs/vault": {"note.md": {"other.md": 10}}}}
#
# It is display-only (see LinkWeights): the canvas draws with it, the link
# panel orders with it, and nothing else consults it — never a spawn, a trust
# decision, a navigation gate or a write to the vault. It is deliberately not
# in `vaults.db`: that store is a derived cache a schema bump rebuilds, and
# authored work must survive a rebuild.
#
# Two writers, one store: the wiki pane's canvas (a set/clear control on an
# edge; `set_pair`/`clear_pair`, which touch both directions of the drawn
# pair) and the `vaultWeight` IPC method (one directed number, for an agent).
# The pane lazily prunes declarations whose endpoints left the vault when it
# shows a complete graph, so the file does not accumulate names forever.
#
# The file is hand-editable, so the loader is the same boundary as every other
# store: typed reads, path-shape checks, weight-range checks, and caps — a bad
# entry costs itself, not the file.

const WEIGHTS_FILE := "user://link_weights.json"

## vault root (normalized) -> {src note -> {target note -> weight}}
var _vaults: Dictionary = {}

func _on_init():
	reload()

func reload():
	_vaults = {}
	var d = _read_file(WEIGHTS_FILE)
	var raw_vaults := _as_dict(d, "vaults", {})
	for raw_root in raw_vaults:
		if _vaults.size() >= LinkWeights.MAX_VAULTS:
			break
		if not (raw_root is String):
			continue
		var root := LinkWeights.normalize_vault(str(raw_root))
		if not LinkWeights.valid_vault_path(root) or _vaults.has(root):
			continue
		var raw_map: Variant = raw_vaults[raw_root]
		if not (raw_map is Dictionary):
			continue
		var map := _load_vault(raw_map)
		if not map.is_empty():
			_vaults[root] = map

## Parse one vault's map with the vocabulary and caps applied. `src -> target`
## pairs whose paths or weights do not hold lose themselves, and the entry
## count is bounded before the map can grow.
func _load_vault(raw_map: Dictionary) -> Dictionary:
	var map := {}
	var total := 0
	for raw_src in raw_map:
		if total >= LinkWeights.MAX_ENTRIES:
			break
		if not (raw_src is String) or not LinkWeights.valid_note_path(str(raw_src)):
			continue
		var raw_targets: Variant = raw_map[raw_src]
		if not (raw_targets is Dictionary):
			continue
		var targets := {}
		for raw_target in raw_targets:
			if total >= LinkWeights.MAX_ENTRIES:
				break
			if not (raw_target is String) or not LinkWeights.valid_note_path(str(raw_target)):
				continue
			var weight := _as_int(raw_targets, str(raw_target), 0)
			if weight < LinkWeights.MIN_WEIGHT or weight > LinkWeights.MAX_WEIGHT:
				continue
			targets[str(raw_target)] = weight
			total += 1
		if not targets.is_empty():
			map[str(raw_src)] = targets
	return map

## A copy of one vault's declarations, shaped for `VaultGraphModel.parse`
## (`src -> target -> weight`). Copying keeps the caller from mutating the
## store's map while the model holds it.
func vault_weights(root: String) -> Dictionary:
	var map: Variant = _vaults.get(LinkWeights.normalize_vault(root))
	if not (map is Dictionary):
		return {}
	return (map as Dictionary).duplicate(true)

## One directed declaration, or 0 when there is none.
func weight_of(root: String, src: String, target: String) -> int:
	var map: Variant = _vaults.get(LinkWeights.normalize_vault(root))
	if not (map is Dictionary):
		return 0
	return LinkWeights.lookup(map, src, target)

## Declare `weight` for one directed edge. Returns "" on success and a reason
## otherwise, so the pane can toast it and the IPC arm can answer with it.
func set_weight(root: String, src: String, target: String, weight: int) -> String:
	var problem := _write_problem(root, weight)
	if problem != "":
		return problem
	var pair_problem := _pair_problem(root, src, target)
	if pair_problem != "":
		return pair_problem
	var key := LinkWeights.normalize_vault(root)
	var map: Dictionary = _vaults.get(key, {})
	if _count_missing(map, [[src, target]]) > 0 \
		and LinkWeights.count(map) >= LinkWeights.MAX_ENTRIES:
		return _cap_problem()
	_put(key, map, src, target, weight)
	_save()
	return ""

## Remove one directed declaration. Clearing an absent one is a no-op that
## still succeeds, so an agent may state "no declaration" idempotently.
func clear_weight(root: String, src: String, target: String) -> String:
	var pair_problem := _pair_problem(root, src, target)
	if pair_problem != "":
		return pair_problem
	var key := LinkWeights.normalize_vault(root)
	var map: Variant = _vaults.get(key)
	if not (map is Dictionary) or not _remove(map, src, target):
		return ""
	_store_after_clear(key, map)
	return ""

## The canvas control's write: one number for the drawn pair, stored in both
## directions. The canvas aggregates a pair from the index's two directed
## rows, so a declaration authored on the edge should apply whichever way the
## mention was written (and to the link panel on both notes); the key shape
## stays `(src, target)` so a directed agent write remains expressible.
func set_pair(root: String, a: String, b: String, weight: int) -> String:
	if a == b:
		return "A note cannot declare a weight with itself"
	var problem := _write_problem(root, weight)
	if problem != "":
		return problem
	var pair_problem := _pair_problem(root, a, b)
	if pair_problem != "":
		return pair_problem
	var key := LinkWeights.normalize_vault(root)
	var map: Dictionary = _vaults.get(key, {})
	# Both directions are one write: checking the capacity for the pair up
	# front means a refusal cannot leave one direction declared and the other
	# missing.
	if LinkWeights.count(map) + _count_missing(map, [[a, b], [b, a]]) \
		> LinkWeights.MAX_ENTRIES:
		return _cap_problem()
	_put(key, map, a, b, weight)
	_put(key, map, b, a, weight)
	_save()
	return ""

## Clear both directions of a drawn pair.
func clear_pair(root: String, a: String, b: String) -> String:
	if a == b:
		return "A note cannot declare a weight with itself"
	var pair_problem := _pair_problem(root, a, b)
	if pair_problem != "":
		return pair_problem
	var key := LinkWeights.normalize_vault(root)
	var map: Variant = _vaults.get(key)
	if not (map is Dictionary):
		return ""
	var changed := false
	if _remove(map, a, b):
		changed = true
	if _remove(map, b, a):
		changed = true
	if changed:
		_store_after_clear(key, map)
	return ""

## Drop declarations whose endpoint is not in `known` (the note ids of a
## complete graph answer), and save only when something went. Called lazily by
## the pane when it shows an untruncated graph; a truncated answer must never
## prune, because the note it does not name might come back.
func prune(root: String, known: Dictionary) -> bool:
	var key := LinkWeights.normalize_vault(root)
	var map: Variant = _vaults.get(key)
	if not (map is Dictionary):
		return false
	var changed := false
	for src in map.keys():
		if not known.has(src):
			map.erase(src)
			changed = true
			continue
		var targets: Dictionary = map[src]
		for target in targets.keys():
			if not known.has(target):
				targets.erase(target)
				changed = true
		if targets.is_empty():
			map.erase(src)
	if changed:
		if map.is_empty():
			_vaults.erase(key)
		else:
			_vaults[key] = map
		_save()
	return changed

func _write_problem(root: String, weight: int) -> String:
	var key := LinkWeights.normalize_vault(root)
	if not LinkWeights.valid_vault_path(key):
		return "Vault must be an absolute path"
	if weight < LinkWeights.MIN_WEIGHT or weight > LinkWeights.MAX_WEIGHT:
		return "Weight must be between %d and %d" % [
			LinkWeights.MIN_WEIGHT, LinkWeights.MAX_WEIGHT,
		]
	if not _vaults.has(key) and _vaults.size() >= LinkWeights.MAX_VAULTS:
		return "The store already names the maximum number of vaults (%d)" \
			% LinkWeights.MAX_VAULTS
	return ""

func _pair_problem(root: String, src: String, target: String) -> String:
	var key := LinkWeights.normalize_vault(root)
	if not LinkWeights.valid_vault_path(key):
		return "Vault must be an absolute path"
	if not LinkWeights.valid_note_path(src) or not LinkWeights.valid_note_path(target):
		return "Source and target must be vault-relative note paths"
	return ""

## How many of `pairs` (`[[src, target], …]`) are not already declared.
func _count_missing(map: Dictionary, pairs: Array) -> int:
	var missing := 0
	for pair in pairs:
		var targets: Variant = map.get(pair[0])
		if not (targets is Dictionary) or not targets.has(pair[1]):
			missing += 1
	return missing

func _put(key: String, map: Dictionary, src: String, target: String, weight: int) -> void:
	var targets: Dictionary = map.get(src, {})
	targets[target] = int(weight)
	map[src] = targets
	_vaults[key] = map

## Drop a direction from `map`; true when it was there.
func _remove(map: Dictionary, src: String, target: String) -> bool:
	var targets: Variant = map.get(src)
	if not (targets is Dictionary) or not targets.has(target):
		return false
	targets.erase(target)
	if targets.is_empty():
		map.erase(src)
	return true

## Persist a map after a clear: an empty map takes its vault key with it.
func _store_after_clear(key: String, map: Dictionary) -> void:
	if map.is_empty():
		_vaults.erase(key)
	else:
		_vaults[key] = map
	_save()

func _cap_problem() -> String:
	return "This vault already has the maximum number of declared weights (%d)" \
		% LinkWeights.MAX_ENTRIES

func _save():
	_write_file(WEIGHTS_FILE, {"vaults": _vaults})
