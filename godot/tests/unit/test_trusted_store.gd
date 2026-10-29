extends GutTest
# TrustedStore — the consent memory behind the Workspace Trust dialog. The
# record keys on content identity + version (builtin name + app version,
# plugin id + pinned revision), so the interesting boundaries are: stale
# versions, shape checks on a hand-edited file, caps, and the plan-key
# coverage the restore gate asks about.

func before_each():
	MockAutoloads.setup()

func after_each():
	MockAutoloads.teardown()

func test_builtin_approval_is_version_scoped():
	assert_false(TrustedStore.is_builtin_approved("OMP Workspace", "0.5.4"))
	TrustedStore.approve_builtin("OMP Workspace", "0.5.4", ["omp\u001f-m"])
	assert_true(TrustedStore.is_builtin_approved("OMP Workspace", "0.5.4"))
	# A new app version re-prompts: the same name at another version is stale.
	assert_false(TrustedStore.is_builtin_approved("OMP Workspace", "0.5.5"))
	# Re-approving at the new version replaces the old record.
	TrustedStore.approve_builtin("OMP Workspace", "0.5.5", ["omp\u001f-m"])
	assert_true(TrustedStore.is_builtin_approved("OMP Workspace", "0.5.5"))
	assert_false(TrustedStore.is_builtin_approved("OMP Workspace", "0.5.4"))

func test_builtin_plans_follow_the_version():
	TrustedStore.approve_builtin("Demo", "0.5.4", ["plan-a", "plan-b"])
	assert_eq(TrustedStore.builtin_plans("Demo", "0.5.4"), ["plan-a", "plan-b"])
	assert_eq(TrustedStore.builtin_plans("Demo", "0.5.5"), [], "a stale approval covers nothing")
	assert_eq(TrustedStore.builtin_plans("Other", "0.5.4"), [])

func test_plugin_approval_is_revision_scoped():
	assert_false(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "a1b2c3d4e5f6"))
	TrustedStore.approve_plugin("godot-pty/gpty-omp", "a1b2c3d4e5f6", ["omp\u001f-m"])
	assert_true(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "a1b2c3d4e5f6"))
	# A new pinned revision re-prompts, and the old revision's plans are not
	# reachable under the new one.
	assert_false(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "f6e5d4c3b2a1"))
	assert_eq(TrustedStore.plugin_plans("godot-pty/gpty-omp", "f6e5d4c3b2a1"), [])
	TrustedStore.approve_plugin("godot-pty/gpty-omp", "f6e5d4c3b2a1", ["omp\u001f-m", "git"])
	assert_true(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "f6e5d4c3b2a1"))
	assert_eq(
		TrustedStore.plugin_plans("godot-pty/gpty-omp", "f6e5d4c3b2a1"), ["omp\u001f-m", "git"],
		"the plans the review listed are what the approval covers")
	assert_false(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "a1b2c3d4e5f6"),
		"an approval is replaced, not accumulated")
	assert_eq(TrustedStore.plugin_plans("godot-pty/gpty-omp", "a1b2c3d4e5f6"), [])

func test_invalid_records_are_refused_not_stored():
	TrustedStore.approve_builtin("", "0.5.4", [])
	TrustedStore.approve_builtin("Bad Version", "0.5.4\nEXTRA", [])
	TrustedStore.approve_builtin("Demo", "not a version!", [])
	assert_true(TrustedStore._builtins.is_empty(), "invalid builtin approvals never land")
	TrustedStore.approve_plugin("Owner/Upper", "a1b2c3d4e5f6")
	TrustedStore.approve_plugin("godot-pty/gpty-omp", "short")
	assert_true(TrustedStore._plugins.is_empty(), "invalid plugin approvals never land")

func test_plan_keys_are_capped_and_filtered():
	var plans: Array = []
	for i in TrustedStore.MAX_PLANS + 10:
		plans.append("plan-%d" % i)
	TrustedStore.approve_builtin("Demo", "0.5.4", ["ok", "ok", "", 42, "x".repeat(TrustedStore.MAX_PLAN_KEY_LEN + 1)] + plans)
	var stored: Array = TrustedStore.builtin_plans("Demo", "0.5.4")
	assert_eq(stored.size(), TrustedStore.MAX_PLANS, "valid plans cap at MAX_PLANS; junk entries drop")
	assert_eq(stored[0], "ok")
	assert_eq(stored.count("ok"), 1, "a repeated plan is stored once")
	assert_true(stored.has("plan-0"))
	assert_false(stored.has("plan-%d" % TrustedStore.MAX_PLANS), "plans beyond the cap drop")

func test_reload_seeds_from_the_file_and_drops_bad_entries():
	MockAutoloads.set_store(TrustedStore.TRUSTED_FILE, {
		"builtins": {
			"Good": {"version": "0.5.4", "plans": ["a", "b"]},
			"WrongVersion": {"version": "x y", "plans": ["c"]},
			"WrongShape": "not a table",
			"PlanJunk": {"version": "0.5.4", "plans": ["ok", 42, "", "y".repeat(TrustedStore.MAX_PLAN_KEY_LEN + 1)]},
		},
		"plugins": {
			# The pre-plans shape: still an approval, and it covers nothing
			# beyond the revision, so that plugin's profiles ask once more.
			"godot-pty/gpty-omp": "a1b2c3d4e5f6",
			"godot-pty/gpty-herdr": {"revision": "c0ffee123456",
				"plans": ["herdr", "herdr", 42, "", "z".repeat(TrustedStore.MAX_PLAN_KEY_LEN + 1)]},
			"godot-pty/gpty-lazygit": {"revision": "not a revision!", "plans": ["lazygit"]},
			"BAD/ID!": "a1b2c3d4e5f6",
			"godot-pty/gpty-claude": 99,
		},
	})
	TrustedStore.reload()
	assert_true(TrustedStore.is_builtin_approved("Good", "0.5.4"))
	assert_eq(TrustedStore.builtin_plans("Good", "0.5.4"), ["a", "b"])
	assert_false(TrustedStore.is_builtin_approved("WrongVersion", "x y"))
	assert_false(TrustedStore.is_builtin_approved("WrongShape", "0.5.4"))
	assert_eq(TrustedStore.builtin_plans("PlanJunk", "0.5.4"), ["ok"])
	assert_true(TrustedStore.is_plugin_approved("godot-pty/gpty-omp", "a1b2c3d4e5f6"))
	assert_eq(TrustedStore.plugin_plans("godot-pty/gpty-omp", "a1b2c3d4e5f6"), [],
		"a legacy string record approves the revision and covers no plans")
	assert_true(TrustedStore.is_plugin_approved("godot-pty/gpty-herdr", "c0ffee123456"))
	assert_eq(TrustedStore.plugin_plans("godot-pty/gpty-herdr", "c0ffee123456"), ["herdr"],
		"a plans record keeps its keys, deduplicated and filtered")
	assert_false(TrustedStore.is_plugin_approved("godot-pty/gpty-lazygit", "not a revision!"),
		"a record with an invalid revision is dropped")
	assert_false(TrustedStore.is_plugin_approved("BAD/ID!", "a1b2c3d4e5f6"))
	assert_false(TrustedStore.is_plugin_approved("godot-pty/gpty-claude", "a1b2c3d4e5f6"))

func test_approved_plan_keys_union_all_current_builtins():
	TrustedStore.approve_builtin("A", "0.5.4", ["a1", "shared"])
	TrustedStore.approve_builtin("B", "0.5.4", ["b1", "shared"])
	TrustedStore.approve_builtin("C", "0.5.5", ["stale"])
	var keys: Dictionary = TrustedStore.approved_plan_keys("0.5.4")
	assert_true(keys.has("a1") and keys.has("b1") and keys.has("shared"))
	assert_false(keys.has("stale"), "plans from another version do not cover")

func test_approvals_persist_to_the_store():
	TrustedStore.approve_builtin("Demo", "0.5.4", ["plan-a"])
	TrustedStore.approve_plugin("godot-pty/gpty-omp", "a1b2c3d4e5f6", ["omp\u001f-m"])
	var on_disk = MockAutoloads.get_store(TrustedStore.TRUSTED_FILE)
	assert_eq(on_disk["builtins"]["Demo"], {"version": "0.5.4", "plans": ["plan-a"]})
	assert_eq(on_disk["plugins"]["godot-pty/gpty-omp"],
		{"revision": "a1b2c3d4e5f6", "plans": ["omp\u001f-m"]},
		"a plugin record carries the revision and the plans it covers")

## The plugin-id shape, now a shared public API (`ipc_handlers.gd` uses it for
## the `pluginsChanged` notice, this store keys consent records on it). Its
## boundaries are the whole point: an id that passes here but not in
## `plugin_manifest.rs::valid_plugin_id` would let the GUI accept something the
## CLI would refuse to store.
func test_valid_plugin_id_holds_the_manifest_shape():
	assert_true(TrustedStore.valid_plugin_id("godot-pty/gpty-omp"))
	assert_true(TrustedStore.valid_plugin_id("a/b"), "single characters are valid")
	assert_true(TrustedStore.valid_plugin_id("a1-2/b3-4"))
	assert_true(TrustedStore.valid_plugin_id("%s/%s" % ["a".repeat(63), "b".repeat(63)]),
		"63 characters per part is the ceiling")

	assert_false(TrustedStore.valid_plugin_id(""), "an empty id is not an id")
	assert_false(TrustedStore.valid_plugin_id("noslash"), "the separator is required")
	assert_false(TrustedStore.valid_plugin_id("Owner/repo"), "uppercase is refused")
	assert_false(TrustedStore.valid_plugin_id("owner/repo/extra"), "a second separator is refused")
	assert_false(TrustedStore.valid_plugin_id("owner/re po"), "whitespace is refused")
	assert_false(TrustedStore.valid_plugin_id("owner/"), "an empty part is refused")
	assert_false(TrustedStore.valid_plugin_id("%s/b" % "a".repeat(64)),
		"64 characters per part is over the ceiling")
