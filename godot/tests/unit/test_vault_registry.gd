extends GutTest
# VaultRegistry — the user-owned list that decides what the control socket's
# vault verbs may look inside. The rules that matter: one spelling per root,
# only an existing absolute directory registers, the loader is the same
# hand-edited-file boundary as every store, and the native handlers' in-process
# mirror is exactly this list (they run on the blocking pool and cannot read
# `user://`, so a drift here would be invisible to both sides).

var _vault := ""

func before_each():
	MockAutoloads.setup()
	VaultRegistry.reload()
	_vault = TestPaths.user_path("vault_registry_probe")
	DirAccess.make_dir_recursive_absolute(_vault)

func after_each():
	DirAccess.remove_absolute(_vault)
	VaultRegistry.reload()
	GptyTerminal.vault_clear_roots()
	MockAutoloads.teardown()

## The roots the native vault handlers answer from, as GDScript sees them.
func _mirror() -> Array:
	var parsed = JSON.parse_string(str(GptyTerminal.vault_registered_roots()))
	return parsed if parsed is Array else []

func test_register_persists_one_spelling():
	assert_true(VaultRegistry.register(_vault), "a real directory registers")
	assert_true(VaultRegistry.register(_vault + "/"), "the trailing separator is the same root")
	assert_eq(VaultRegistry.roots().size(), 1, "one spelling, one entry")
	var stored: Dictionary = MockAutoloads.get_store(VaultRegistry.VAULTS_FILE)
	assert_eq((stored.get("roots") as Array).size(), 1, "the store holds the one entry")

func test_register_refuses_what_cannot_be_a_vault():
	assert_false(VaultRegistry.register(""), "an empty value is not a vault")
	assert_false(VaultRegistry.register("relative/path"), "a relative path is not a vault")
	assert_false(VaultRegistry.register("/does/not/exist/anywhere"), "a missing directory is not a vault")
	assert_eq(VaultRegistry.roots().size(), 0, "nothing refused was stored")

func test_the_loader_drops_bad_entries_and_caps():
	var seeded: Array = ["", "relative", "/does/not/exist", _vault, _vault + "/"]
	for i in LinkWeights.MAX_VAULTS:
		seeded.append(TestPaths.user_path("vault_registry_bulk%d" % i))
	MockAutoloads.set_store(VaultRegistry.VAULTS_FILE, {"roots": seeded})
	VaultRegistry.reload()
	assert_true(VaultRegistry.has_root(_vault), "a valid entry survives its bad neighbours")
	assert_eq(VaultRegistry.roots().size(), LinkWeights.MAX_VAULTS, "the file's list is capped")

func test_a_full_list_refuses_a_new_root():
	var full: Array = []
	for i in LinkWeights.MAX_VAULTS:
		full.append(TestPaths.user_path("vault_registry_full%d" % i))
	MockAutoloads.set_store(VaultRegistry.VAULTS_FILE, {"roots": full})
	VaultRegistry.reload()
	assert_eq(VaultRegistry.roots().size(), LinkWeights.MAX_VAULTS)
	assert_false(VaultRegistry.register(_vault), "a full list refuses instead of evicting")
	assert_false(VaultRegistry.has_root(_vault), "and the refused root does not answer")

func test_the_native_mirror_is_this_list():
	GptyTerminal.vault_clear_roots()
	assert_eq(_mirror(), [], "an empty list clears the handlers' mirror")
	assert_true(VaultRegistry.register(_vault))
	var roots := _mirror()
	assert_eq(roots.size(), 1, "registration reaches the native handlers")
	# Rust's `canonicalize` answers backslashes (and a `\\?\` prefix) on
	# Windows, so the suffix check normalizes the separator rather than
	# asserting the host's spelling.
	assert_true(
		str(roots[0]).replace("\\", "/").ends_with("/vault_registry_probe"),
		"the mirror holds the canonical root (%s)" % roots
	)
	MockAutoloads.set_store(VaultRegistry.VAULTS_FILE, {"roots": []})
	VaultRegistry.reload()
	assert_eq(_mirror(), [], "a reload replaces the mirror instead of growing it")
