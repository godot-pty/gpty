class_name LinkWeights
## The declared edge-weight vocabulary: range, note-path shape, and the nested
## lookup the graph model and the store share.
##
## A declared weight is authored data about a *display*. The index counts
## mentions, which is a crude proxy — two notes can be deeply related and
## mention each other once, or name-drop ten times and share nothing — so the
## user (or an agent, through `vaultWeight`) may state a number that overrides
## the measured count for edge thickness, layout stiffness and backlink
## ordering.
##
## It is keyed `(vault, src, target)` on vault-relative note paths and lives in
## the user-owned `user://link_weights.json` ([LinkWeightsStore]), never in the
## derived `vaults.db`: the index is a cache a schema bump rebuilds, and
## authored work must not be erased by a rebuild.
##
## Nothing here reads the vault or decides anything. Display-only is the rule:
## a declared weight can never hide an edge, gate navigation, trigger a write
## or count as consent.

## Authored weights sit on a small, human-readable scale. The measured count
## is on its own scale (mentions can be in the thousands); a declaration
## replaces one edge's value rather than competing with it, and the canvas
## normalizes thickness over whatever the graph holds.
const MIN_WEIGHT := 1
const MAX_WEIGHT := 100
## What the canvas's set control starts at when the edge has no declaration.
const DEFAULT_WEIGHT := 10

## Caps for the user-owned store (one vault's map, and how many vaults it may
## name). They bound a hand-edited file, not a normal workflow.
const MAX_VAULTS := 32
const MAX_ENTRIES := 1024

## Longest paths the store keeps. A note path is the index's own vocabulary
## (`MAX_REL_PATH_BYTES` in `gpty_core::vault`); a vault root is a filesystem
## path.
const MAX_NOTE_PATH_BYTES := 1024
const MAX_VAULT_PATH_BYTES := 4096

## The declared weight for one directed edge, or 0 when there is none.
##
## `weights` is the store's nested map (`src -> target -> weight`). A value
## outside the range is treated as absent: the loader drops those, and a
## hand-built map (a test, a future caller) must not be able to make a list
## index or a thickness computation read a weight the vocabulary never allows.
static func lookup(weights: Dictionary, src: String, target: String) -> int:
	if src == "" or target == "":
		return 0
	var targets: Variant = weights.get(src)
	if not (targets is Dictionary):
		return 0
	var value: Variant = targets.get(target)
	if not (value is int):
		return 0
	var weight := int(value)
	if weight < MIN_WEIGHT or weight > MAX_WEIGHT:
		return 0
	return weight

## Number of directed declarations in one vault's map.
static func count(weights: Dictionary) -> int:
	var total := 0
	for src in weights:
		var targets: Variant = weights[src]
		if targets is Dictionary:
			total += targets.size()
	return total

## A note path the vault walk could have produced: a relative path of
## ordinary components, none hidden, ending in `.md`. This is the same shape
## `gpty_core::vault::note_path` enforces, so a key the store accepts is one
## the index can answer — a `..`, an absolute path, a hidden component or a
## non-Markdown name is refused instead of stored under a spelling no note has.
static func valid_note_path(path: String) -> bool:
	if path.is_empty() or path.length() > MAX_NOTE_PATH_BYTES:
		return false
	if path.is_absolute_path() or path.contains("\\"):
		return false
	var parts := path.split("/", true)
	if parts.is_empty():
		return false
	for part in parts:
		if part == "" or part == "." or part == ".." or part.begins_with("."):
			return false
	return parts[parts.size() - 1].get_extension().to_lower() == "md"

## A vault root the store may key on: an absolute path, bounded. The directory
## need not exist to load the file (a vault on an unmounted drive must keep its
## declarations); callers that act on a vault check it exists themselves.
static func valid_vault_path(root: String) -> bool:
	return not root.is_empty() \
		and root.length() <= MAX_VAULT_PATH_BYTES \
		and root.is_absolute_path()

## One spelling per vault: `simplify_path()` collapses `.`/`..` and doubled
## separators, and the trailing separator goes away, so `/vault` and `/vault/`
## cannot become two entries that hold different weights for the same notes.
static func normalize_vault(root: String) -> String:
	var path := root.strip_edges().simplify_path()
	# Keep a filesystem root as it is (`/`, and `C:/` on Windows), and drop a
	# trailing separator everywhere else.
	if path.length() > 1 and path.ends_with("/") and not path.ends_with(":/"):
		path = path.trim_suffix("/")
	return path
