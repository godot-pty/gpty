---
title: "Roadmap details - PLUGIN"
weight: 900
build:
  list: never
---

Every PLUGIN row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## PLUGIN-1

**Plugin manifest** - `gpty-plugin.toml` (id, name, version, min_gpty_version, platforms,
build/startup commands, actions, events, link handlers) plus gpty-native `[[concepts]]` and
`[[profiles]]` sections so a plugin can be pure JSON - zero code. **Closed:** the schema and
validator shipped as `crates/gpty-cli/src/plugin_manifest.rs` (`parse_manifest` → typed `Manifest`;
precise per-path errors for the install review dialog; `toml` 0.8 + `gpty-core` added to gpty-cli).
The validator's contract is "the manifest ships only what gpty already accepts": every
`[[concepts]]` entry is held to the visual editor's closed key set and **round-tripped through the
real engine parser** (`concepts_from_json`) - a trigger the Rust `regex` dialect refuses (a PCRE2
lookbehind) rejects the manifest, which is the seam test's centerpiece; `[[profiles]]` tiles mirror
`PaneTypes.sanitize_tile` (five pane types, grid 60, rows/cols 500/2000, `attachment_id` pattern)
with reject-not-clamp (a manifest is authored content); `[[actions]].command` must be one of
`schema::mcp_tool_names()` (the published 19-tool API); `[[events]].type` is the closed event-socket
vocabulary; argv sections carry the `shell_args` caps (≤32 entries, ≤4096 chars, no U+FFFD) and
nothing executes at parse time. 16 new unit tests (33 total in the crate) cover every cap, the
closed vocabularies, and the two seams; `cargo fmt`/`clippy` clean. The module is dead-code-allowed
until the install item wires it - the allow comment says so. (Deferred from the design:
install/lifecycle, the review dialog, and executing actions belong to the next item.)

Commits: d17bac7

## PLUGIN-2

**Plugin install & lifecycle** - `gpty plugin install <owner>/<repo>@ref` (git clone into a staging
dir, manifest parsed with the shipped validator - the size/count/path caps live there, item above -
review dialog over a new `pluginInstall` IPC handshake reusing the Workspace Trust pattern, pinned
revision, per-plugin config/state/log dirs) and `list` / `enable` / `disable` / `uninstall` / `run`
/ `logs`. The entire CLI is the plugin API (`GPTY_BIN_PATH`); commands are argv arrays, never
shell-evaluated. A manifest's `build`/`startup` commands are displayed in the review but not
executed by this item (declared, not run - the lifecycle item that runs them is its own trust
decision). **Closed:** install clones `https://github.com/<owner>/<repo>` into `<data>/staging`
(argv-driven git, ref names validated against option-injection/traversal), gates on id-match (the
manifest must declare exactly the installed target), platform, and `min_gpty_version`; the review
summary travels over `pluginInstall` (a GDScript-routed method whose Rust fallback deadline is 300
s, not 5 s) to `workspace.gd:_show_plugin_review` (paneWait-style deferred response; ≤4 pending; the
dialog text is `PluginReviewText`, a pure unit-tested builder whose field caps and control-char
stripping keep a hostile manifest from shaping the dialog); no GUI answers => nothing installs, and
the plugin subcommand is excluded from the MCP tool list (`NON_TOOL_ROUTED` in the contract test).
Acceptance moves the clone into `<data>/plugins/<id>` (same-filesystem rename, old revision swapped
with rollback), creates `<state>/plugins/<id>/{config,state,logs}`, and records
`{id, revision, enabled, installed_at}` in `<state>/plugins.json` (`plugin_store.rs`: ≤256 records,
atomic random-suffix temp + 0600 rename, strict on corrupt files, upgrade preserves the enabled
flag). `run` spawns `GPTY_BIN_PATH` (or the current exe) with `--key value` argv, captures output to
the log dir, prints it on exit, refuses disabled plugins. Evidence: 54 CLI tests (12 store + 8
plugin + 3 handshake roundtrips + both contract seams), 62 gpty-ipc, 27 gdext, 440 GUT tests, live
smoke of `plugin list`/`enable`/help/schema, `./scripts/ci-check` green. Not exercised live: the
full clone→review→move path needs a hosted plugin repo (the registry item); its pieces are each
unit/roundtrip-tested. Follow-up (same session): `@ref` is documented as accepting any advertised
git ref - tag, branch, or commit SHA (bare install = default branch latest, which is the
no-`@latest` keyword answer) - and the review summary now carries `requested_ref`, so the dialog
shows the ref the user named resolving to the pinned revision.

Commits: d17bac7

## PLUGIN-3

**Installed content re-prompts forever, and shipped tool profiles are refused over IPC** - the
Workspace Trust dialog had no memory, so every sidebar activation of a profile whose tiles name a
program asked again (all five tool built-ins: `command: omp`/`herdr`/`lazygit`/`nvim`/`claude` -
`workspace.gd:_activate_profile` ran the same `_tiles_untrusted` gate for built-ins, deliberately
without an exemption), and `layoutLoad` refused those profiles outright because a caller cannot
answer a dialog and naming a profile is not consent. **Closed:** consent made once now counts -
`TrustedStore` (`user://trusted.json`, a new autoload on the BasePersistenceManager pattern: atomic
temp+rename 0600 writes, typed accessors, caps of 128 entries per namespace, 64 plans per builtin,
name 128/version 32/revision 7–64 chars) records two namespaces, both keyed by content identity +
version: `builtins` (profile name → app version + spawn plans) and `plugins` (plugin id → pinned
revision). Writers are exactly the two review-confirm paths: the profile trust dialog records a
*builtin* (name, the app version it shipped with, and every tile's `PaneTypes.tile_plan_key` - a new
canonical program+argv derivation kept adjacent to the predicate so the two cannot drift), and the
plugin install review records id + revision; user-authored profiles and layout files never record
consent and keep today's ask-every-time behavior. Consumers: `_activate_profile` skips the dialog
when `_profile_consented` (builtin approved at this app version, or every untrusted tile's exact
plan covered by an approval); the workspace-restore loop uses `_tiles_untrusted_without_consent` (a
workspace saved from an approved builtin restores without re-asking - the plans are what carry the
approval across, since saved tiles have no profile provenance); and `layoutLoad` over IPC consults
the same check instead of refusing outright - the record is proof a caller cannot forge, so
`gpty layout load`/the MCP tool now work on content the user already approved. A new app version or
a new pinned revision re-prompts by construction (the record keys on the version). The plugin
record's profile-side consumption activates when installed-plugin profiles surface (the
profiles-migration item); the same record gates `build`/`startup` execution later. Evidence: 10
TrustedStore unit tests (version/revision scoping, shape checks on a hand-edited file, plan caps,
reload seeding, plan-union coverage, persistence), plan-key seam tests in `test_pane_hardening.gd`,
consent contract tests in `test_ipc_dispatch_contract.gd` (unapproved/stale/covered builtins,
plan-covered and uncovered user profiles, the restore gate), 451 GUT tests total,
`./scripts/ci-check` green.

Commits: d17bac7

## PLUGIN-4

**A timed-out plugin review leaves an orphan dialog** - the `pluginInstall` fallback deadline (300
s) kills the request while `workspace.gd`'s review dialog stays open; a click on it answers a dead
channel (`respond_ipc` no-ops) and the user believes the install happened, while the CLI already
failed. Close the dialog when the request is gone (the GUI can watch the same deadline or the Rust
side can push an expiry notice), so a late click cannot look like consent. **Closed:** the request's
own deadline now travels with it. `IpcRequest` carries the `Instant` its fallback fires at
(`fallback_timeout` stays the single source of truth for the 300 s), `ipc::request_document` turns
it into the time *remaining*, and `drain_ipc_requests` hands GDScript
`[{id, method, params, timeout_ms}]` (0 once it has passed). `_show_plugin_review` opens a dialog
only when `timeout_ms > 0` - a request that died before the frame drained it has no channel left to
answer - arms a one-shot `Timer` for the remainder, and stores `{dialog, timer}` per id;
`_expire_plugin_review` closes and frees the dialog, drops the entry, and toasts that the requesting
command already timed out, answering nothing because by then the request is gone. The answer path
(`_finish_plugin_review`) frees the same two nodes, so an answered review leaves no timer to fire
later. Evidence: `crates/gpty-gdext/src/ipc.rs` tests (the document reports remaining time and
saturates to 0, never wrapping; a queued `pluginInstall` request carries its method's fallback
deadline), `test_plugin_review_expiry.gd` 3/3 (150 ms deadline closes+frees the dialog and toasts;
`timeout_ms == 0` opens nothing; an answered review settles the entry and frees dialog and timer),
`./scripts/ci-check` green.

Commits: d17bac7

## PLUGIN-5

**Plugin registry** - JSON index repo + browse page on the docs site; submission by PR. Policy to
settle at build time: plugin ids are immutable and owned by their repo, `min_gpty_version` is a
floor the registry states, and no registry-side deletion while an install is pinned to a revision
(the pin keeps working). **Closed:** the index lives at `godot-pty/gpty-plugins` (created 2026-09;
the name follows the org's `gpty-` prefix) - `registry.json` seeded with the five tool plugins,
`validate.py`, a README carrying the schema and the policies, and a validate workflow (push, PRs,
weekly; `actions/checkout` pinned to a full SHA like every other repo in the org). Validation has
two layers: structure (closed key set, `owner/repo` ids, `https://github.com/<id>` repo URLs, semver
floor, platform subset, category vocabulary, no duplicates) and manifest agreement (`--check-repos`
fetches each entry's `gpty-plugin.toml` at HEAD and requires id/name/floor/platforms plus a shipped
section to agree), so the catalog cannot drift from the plugin it points at; both layers were
mutation-checked (a trailing-slash repo URL and an isolated floor mismatch are each caught). The
docs site gets a `/plugins/` page and a menu entry: the `plugin-registry` shortcode fetches the
index live at build time and falls back to the committed snapshot `docs/assets/registry.json` when
unreachable (warning in the build log - the failure mode that would otherwise be a silently stale
page; `docs/data/` is generated by `setup.sh`, so the snapshot lives in the assets tree the docs
build reads); both paths were built with the CI-pinned Hugo 0.164.0 and the page inspected rendered
(five entries, correct nav). Policy: ids are immutable and owned by their repo; `min_gpty_version`
is a floor the registry states, not an install gate; removal stops new installs only, since every
install is pinned to a commit SHA. Evidence: registry CI run
[35036315367](https://github.com/godot-pty/gpty-plugins/actions/runs/35036315367) green; docs build
clean on both paths; `./scripts/ci-check` green.

Commits: d17bac7

## PLUGIN-6

**Move tool-specific shipped profiles to plugin repos** - `godot/profiles.default.json` ships six
built-ins, five of which name a program (`command: omp`/`herdr`/`lazygit`/`nvim`/`claude`); only
"Agent Workspace" is pure geometry. Shipping them couples tool layouts to gpty's release cadence and
makes core endorse L3 tools (Herdr) and agents (Claude) that the ADE boundary says are the market's.
Fix, sequenced after the manifest, install, consent-store, and registry items: move the five into
**one repo per tool** under the `godot-pty` org - `gpty-omp`, `gpty-herdr`, `gpty-lazygit`,
`gpty-neovim`, `gpty-claude` (2026-09 decision: no `gpty-profiles` mixed-bag bundle and no catalog
monorepo - a repo is the install/review/consent unit, the manifest's `[[profiles]]` array already
holds per-tool *variants*, and one-repo-per-tool is the shape third-party plugins have, so the
registry and docs ship one shape from day one; the five repos are created and initialized -
manifest, README, Apache-2.0 license, and a minimal validate workflow that pins the TOML parse + id
contract until the migration item wires the authoritative validator) - keep "Agent Workspace"
built-in (the recommended layout, names no program, keeps first-run onboarding at zero dialogs),
seed the registry with them, and point a first-run hint at the catalog page listing all five.
Collateral, all deliberate: `test_six_builtins_in_default_profiles_file` shrinks to one while
`test_each_preset_tile_passes_sanitize_tile` keeps covering it, and the moved profiles get the same
sanitizer checks in each repo's own CI (dogfooding the manifest - which needs a
`gpty plugin validate <path>` command running the shipped `parse_manifest`, since the repos' current
validate workflow only pins the TOML parse + id contract; the command doubles as the
plugin-authoring loop); `ProfileManager` must surface installed-plugin profiles in the same
namespace as user profiles so the sidebar, `layoutList` and `layoutLoad` see them (a name collision
follows `add_profile`'s dedupe convention: a ` (n)` suffix, user-named first); removal is safe for
existing users (built-ins are read-only templates - saved workspaces/profiles are copies). Decide at
migration time whether the tool-specific shipped *concept* defaults (`git_log`, `cargo_check` -
Inspector-targeting, shipped disabled) follow the same move, same argument: shipped defaults keep
tracking updates, and the visual editor already writes a rule equal to a shipped default as *no*
user entry. **Closed:** `godot/profiles.default.json` now ships exactly one built-in ("Agent
Workspace"), verified faithful - each plugin manifest runs the same program with the same argv as
the built-in it replaces. The read path is: install acceptance records the validated manifest's
profiles in the plugin record (`{id, revision, enabled, installed_at, profiles: [{name, tiles}]}`;
caps 64 profiles × 64 tiles, strict reader, an absent key reading as empty so older records stay
valid), `GptyTerminal.installed_plugin_profiles()` hands the *enabled* records to GDScript as JSON
(malformed entries skipped and the reason logged), and `ProfileManager.refresh_plugin_profiles()`
merges them between built-ins and user profiles - dedupe keeps the bare name for user/builtin
content and gives the plugin ` (n)`, first plugin wins, and the naming is re-derived whenever a user
profile takes or frees a name (`_derive_plugin_profiles()`, called by the four user-profile
mutators) so the winner does not depend on arrival order - a follow-up fix, because with the plugin
arriving first the two rows shared one name for the session and `find_profile` resolved the
collision to the *plugin's* row (users are listed last); a `plugin_profiles_source` Callable is the
test seam; `layoutList`/`find_profile`/`layoutLoad` see them with no changes. Trust:
`_profile_consented` consults `TrustedStore.is_plugin_approved(id, revision)` FIRST for a profile
carrying `plugin_id` (approved revision activates without re-asking, a newer revision re-prompts),
and the install review now prints each profile's distinct programs (`programs` in the summary), so
acceptance is informed consent for what its profiles run. The sidebar shows plugin rows with a
provenance tooltip and no delete/rename (the plugin owns them), plus a "Get more layouts → catalog"
hint row while none is installed. `gpty plugin validate <path>` (offline, `--json`, exit 1 on
rejection) is the authoring loop and the check the five plugin repos' CI switches to - their inline
TOML+id script stays until a released CLI is installable there (the command cannot exist before the
v0.5.5 tag), and all five first-party manifests were verified with it locally. Deliberate
collateral: the sidebar's delete/rename lookups were reading `get_all_profiles()` with a
user-profile index (already off by the built-in count) and now read `get_profiles()`. Decision on
the concept defaults: `git_log`/`cargo_check` stay in gpty - generic git/cargo rules rather than
tool endorsements, shipped disabled and Inspector-gated. Evidence: `cargo test -p gpty` 64/64 (store
profile shape/caps, `plugin validate` good/bad/manifest-vs-directory, review programs), `gpty-gdext`
39/39 (the FFI's enabled-only/malformed-entry rules), GUT `test_profile_manager` 20/20,
`test_sidebar` 14/14, `test_ipc_dispatch_contract` 10/10, `test_layout_restore` 12/12; the live
smoke's `plugin-provided profile` step (seeded store record → `layout list` → `layout load` →
`list-panes` shows the profile's tile) passes; `./scripts/ci-check` green.

Commits: d17bac7

## PLUGIN-7

**Plugin admin actions never reach a running GUI** - `gpty plugin uninstall\|enable\|disable`
rewrites `state_dir()/plugins.json`, but the GUI reads that store only at startup and once after an
accepted install review (`workspace.gd:_refresh_plugin_profiles_deferred` - the deferred 2 s pickup
for the accepted clone), because the plugin subcommand is deliberately CLI-only (not routed, not an
MCP tool). A running GUI therefore keeps listing an uninstalled plugin's profiles *and* keeps
activating them from its in-memory copy (tiles plus the programs the user approved at review time,
so nothing unsafe runs - but the `disable` switch visibly does nothing until a restart). Found while
answering whether a v0.5.4 profile can be removed by uninstalling a plugin: it cannot - the five
tool layouts were never plugin records (the store is new in v0.5.5; `uninstall` on an unknown id
bails with "not installed"), `delete_profile` operates on `user://profiles.json` only, and the
sidebar deliberately offers no rename/delete on a `plugin: true` row ("plugin profiles follow the
plugin") - but an installed plugin's profile *does* stay after `uninstall` until the next refresh.
Fix one of: an IPC notification the CLI fires after an admin action (the GUI's dispatch already
exists; the method joins the contract test's `NON_TOOL_ROUTED`), or a cheap store-mtime check in the
GUI's existing slow poll. Verify live: install → row appears, `uninstall` → row leaves without a
restart. **Closed:** the CLI now fires `pluginsChanged {"action", "id"}` over the control socket
after a successful `uninstall`/`enable`/`disable`, and `ipc_handlers.gd` answers it by re-reading
the store *synchronously* - so the CLI's reply means the GUI's profile list is already up to date
(the install review keeps its deferred re-read, because there the clone lands only after the
answer). Best-effort in the one direction that matters: no GUI, a refused connect or a 2 s timeout
is dropped, and an admin action never starts a GUI (`ensure_running` is deliberately absent here,
unlike `install`). The method is routed but not an MCP tool (`NON_TOOL_ROUTED`, alongside
`pluginInstall`), which the CLI's contract test enforces. Evidence:
`plugin_admin_notice_reaches_a_gui_and_is_silent_without_one` (payload, absent-GUI silence, and a
failed action never notifying), GUT `test_an_admin_notification_refreshes_the_profile_list` (the row
leaves the list and an action outside the closed vocabulary is refused), The notice validates both
fields though only `action` has a consumer today: `id` is inert and the CLI cannot deliver a
malformed one, but validation is a boundary property, not a property of the read fields - and the
shape is shared, not re-declared (`TrustedStore.valid_plugin_id`, made public for its second
consumer; the consent records were the first), which the closed item's own boundary test covers
(`test_valid_plugin_id_holds_the_manifest_shape`). Evidence: the live smoke gained a
`plugin admin notice` step - seeded record → `gpty plugin uninstall` → `layout list` no longer
offers the profile - which fails under mutation (the call renamed to an unregistered method
reproduces the original bug: "a running GUI must drop an uninstalled plugin's profile (got: ['Agent
Workspace', 'Smoke Layout'])").

Commits: d17bac7

## PLUGIN-8

**Plugin `[[concepts]]` never reach the engine** - the manifest validator accepts them
(round-tripped through `concepts_from_json`), the install review counts them
(`"concepts": manifest.concepts.len()` in `commands/plugin.rs`; `PluginReviewText` prints "Concepts:
N"), and `docs/content/plugins.md` tells authors a plugin can "ship pure data - profiles, concepts,
event subscriptions", but nothing delivers them: the store record persists `profiles` only
(`PluginRecord` in `plugin_store.rs`), the GUI's single store reader shapes profiles only
(`installed_plugin_profiles` → `profiles_json`), and `ConceptManager` reads exactly
`res://concepts.default.json` + `user://concepts.json` - an installed plugin's concepts are listed
to the user and then dropped. `[[events]]` and `[[link_handlers]]` are the same shape (validated and
summarized in the review; no consumer outside `commands/plugin.rs` + `plugin_manifest.rs`). Decide:
wire them the way profiles were wired (the CLI is the only manifest reader - carry the validated
entries in the record, hand them to GDScript, merge with provenance = plugin id + pinned revision
and a defined precedence against shipped defaults, removed on `disable`/`uninstall`), or declare the
sections review-only, drop them from the vocabulary, and correct the docs sentence. Found 2026-10-09
while checking whether `godot/profiles.default.json`/`godot/concepts.default.json` are still needed
after the plugin move - they are, and this gap is why `concepts.default.json` remains the only
shipped concept source that reaches the engine. **Closed:** decided per layer. **Concepts are wired
the way profiles were**: the record carries the validated entries (`concepts: [...]`, cap 128,
closed `CONCEPT_KEYS`, absent reads empty - strict reader and a write-path mirror in
`plugin_store.rs`), the new static `GptyTerminal.installed_plugin_concepts()` shapes the enabled
records as `{plugin_id, revision, name, concept}` (`plugin_concepts_json`, tested), and
`ConceptManager.refresh_plugin_concepts()` merges them between the shipped defaults and the user's
own: a plugin name yields to a default or an earlier plugin with ` (n)` (so uninstall and re-install
give the bare name back), a user entry naming a rule is that rule's *overlay* - which is what makes
the Settings toggle/edit/delete work on installed content, delete writing a disabled overlay rather
than touching a file the plugin owns - the Settings row carries provenance, and the visual canvas
excludes plugin rules (its no-entry/tombstone save semantics are defined for the defaults and the
user's rules only). Refresh fires at init, after an accepted install review (the same deferred
re-read as profiles), and on `pluginsChanged`. The install review names each rule and what it would
do (`{name, enabled, notify_only, targets}`) instead of printing a count. **`[[events]]` and
`[[link_handlers]]` are declared only** - decided in the item below: reviewed declarations, never
dispatched. Evidence: 499 GUT tests green (merge precedence, name dedupe against defaults and among
plugins, toggle overlay, unusable entries skipped, refresh replaces-and-emits, review naming,
deferred install pickup, `pluginsChanged` arm refresh); Rust 80 + 46 (store roundtrip/caps/shape
rejection, `plugin_concepts_json`); the live smoke seeds the record, sees the rule in
`concept list`, fires it from real output (single-line notify → event), and sees it leave on
uninstall.

Commits: d17bac7

## PLUGIN-9

**`[[events]]` and `[[link_handlers]]` are declared and reviewed but never delivered** - the
validator accepts and caps both (events ≤64 against the closed event-socket vocabulary, link
handlers ≤16 with argv commands) and the install review displays them, but no runtime consumes them:
nothing runs a plugin action when a subscribed event fires, and nothing opens a link through a
handler. This was decided *separately* from `[[concepts]]` (2026-10): concepts are inert data
(capture/display), while both of these are execution paths - an event-triggered action runs
`GPTY_BIN_PATH <action> …` as the user on events that terminal output or a pane's program can
provoke, and a link handler runs argv on a user click, which needs its own per-scheme consent
boundary. Decide with a trust design: wire events through an explicit subscription review (which
action, which event types; events are low-volume metadata, but `state.declared` is claimable by
anything that prints, so authority must be stated) and link handlers behind a Workspace Trust-style
consent, or drop the sections from the accepted vocabulary at the next schema break and correct the
docs. Until then the docs say "declared, not delivered" and the review shows them as such. **Closed
(decided 2026-10): keep both sections as reviewed declarations; build neither runtime.** Events:
gpty ships the primitives - the event socket (`subscribe`/`eventsPoll`, open to same-UID processes;
a plugin program launched in a pane already receives `GPTY_EVENT_SOCKET`) - and an
event→plugin-action dispatcher stays out of core by the ADE boundary (observe/display, never
orchestrate) and by the execution-primitive stance (it would run user-level commands on signals that
terminal output or a Tier-2 declaration can provoke). Link handlers: the Markdown view opens only
`http`/`https`/`mailto` through `OS.shell_open` after a confirmation and ignores every other scheme,
so nothing consults these entries; a click path would need an env-stripped argv spawn surface
(Godot's own process spawn cannot drop `GPTY_SECRET` or a pane's event capability), a
reserved-scheme policy, and per-click consent - and no consumer exists. What shipped: the install
review renders every declared-only section as such
(`Listens for (declared; the plugin reads gpty's event socket itself)`,
`Link handlers (declared; gpty runs none of these)`,
`Build/Startup command (declared, not run by gpty)`), `docs/content/plugins.md` and AGENTS.md state
the model, and a review-text test pins the wording so the consent surface cannot drift into implying
delivery. Kept in the vocabulary rather than dropped: a 0.5.x patch is no place for a
published-schema break, and the declarations carry review value; pruning stays a deliberate
schema-break decision. The author-facing event-socket reference is the v1.0.0 docs item - no
separate follow-up queued. Evidence: claim checks (`markdown_view.gd::_confirm_link`'s allowlist;
`transport::default_event_socket_path`; `pty.rs`'s trusted `GPTY_EVENT_SOCKET` injection) and 500
GUT tests green.

Commits: d17bac7

## PLUGIN-10

**Plugin repos' CI runs the authoritative validator** - the five first-party plugin repos
(`gpty-omp`, `gpty-herdr`, `gpty-lazygit`, `gpty-neovim`, `gpty-claude`) still check their manifests
with an inline `tomllib` + id script; `gpty plugin validate <path>` is the shipped validator now
(verified against all five manifests locally), and v0.5.5 shipped it, so their CI can install it at
a pinned ref now. Switch each repo's `.github/workflows/validate.yml` to install the CLI at a pinned
ref (`cargo install --git https://github.com/godot-pty/gpty --rev <sha> gpty`, the git SHA being the
pin per the supply-chain rule) and run `gpty plugin validate .`; the inline script's whole job was
to pin the TOML parse + id contract until this existed. Release-time work, deferred from the
profiles-migration item whose closure records the command and the local verification. **(Deferred
from v0.5.5.)** **Closed:** each repo's `.github/workflows/validate.yml` now installs the CLI from
the v0.5.5 commit
(`cargo install --git https://github.com/godot-pty/gpty --rev 2f174598561540d2b0c6836c57d81182e99bfa61 --locked gpty`
- the SHA is the pin, per the supply-chain rule) and runs `gpty plugin validate .`, the same
`parse_manifest` the install path runs; the inline script reduces to the one assertion the validator
cannot make (the install gate requires `id` to equal the install target, and only the repo knows
which target it is). Verified: the pinned CLI validated all five manifests from the clones, and the
new workflow passed on all five pushed commits - gpty-omp `c15d625`, gpty-herdr `05f9480`,
gpty-lazygit `b24f77c`, gpty-neovim `df64788`, gpty-claude `ae3ef84` (cargo checkout cached per
revision key).

Commits: d17bac7

## PLUGIN-11

**gpty-omp ships the OMP-branded workspace** - shipped 2026-11-15 (plugin 0.2.0). The manifest
carries a second profile beside the single-pane `OMP` launcher: `OMP Workspace` with the built-in
3-tile geometry (`0/0/35/60`, `35/0/25/30`, `35/30/25/30`) and names `OMP`/`Inspector`/`Reasoning` -
terminal `command = "omp"`, Inspector `backend = "omp"`, Reasoning
`source_attachment_id = "omp-ws-terminal"`, and its own
`omp-ws-terminal`/`omp-ws-inspector`/`omp-ws-reasoning` ids so it cannot collide with the built-in's
`agent-*` handles. `version` 0.1.0 to 0.2.0 and `min_gpty_version` 0.5.4 to 0.5.5, so the profiles
only advertise on a GUI that lists installed-plugin profiles. The README lists both profiles, names
the app's generic Agent Workspace as the counterpart, and repeats the `omp plugin link ...` step for
Reasoning; `godot-pty/gpty-plugins` and the committed `docs/assets/registry.json` snapshot carry the
same 0.5.5 floor and a description naming both profiles. `gpty plugin validate` answers
`plugin ok: godot-pty/gpty-omp 0.2.0 (2 profiles, 0 actions, 0 events, 0 concepts, 0 link handlers)`;
no core change was needed - the install review already lists `omp` from `settings.command`, and
approval at the pinned revision covers activation.

Commits: 6232fd3, 6cecfd6, a2bfbb3

## PLUGIN-12

**The generic Agent Workspace plugin still ships the OMP ids** - found 2026-11-15 while closing
**The built-in Agent Workspace still names OMP**: `godot-pty/gpty-agent-workspace` is the published
twin of the seeded Agent Workspace, and its tiles still carried
`omp-terminal`/`omp-inspector`/`omp-reasoning` plus a redundant `backend = "omp"` after the built-in
moved to `agent-*` - so one arrangement shipped under two handle sets, and the plugin's Inspector
pinned a backend the built-in no longer names. Fixed in the same session (plugin 0.2.0): the ids are
`agent-terminal`/`agent-inspector`/`agent-reasoning`, the Inspector inherits the pane's default
backend, and the README frames the profile as core geometry with OMP as the Inspector's default
adapter. `gpty plugin validate` answers
`plugin ok: godot-pty/gpty-agent-workspace 0.2.0 (1 profiles, 0 actions, 0 events, 0 concepts, 0 link handlers)`.

Commits: a2bfbb3

## PLUGIN-13

**A plugin store written by this build is unreadable to an older CLI** - fixed 2026-11-16 (build
0.8.4): the reader's forward-compatibility policy lives in `crates/gpty-plugin/src/store.rs` and is
one rule at every level - an unknown *sibling* key is ignored (file root, record, profile entry,
concept entry) while a required field, a type, a shape, a cap and the id/revision formats are still
refused, so a renamed or removed field still fails through its required-field check and tolerance
covers additive drift only. The writer still refuses an unknown concept key: the closed set
(`CONCEPT_KEYS`, the manifest's vocabulary) moved out of the shared shape check into
`validate_concepts`, so the store never emits what the validator would not admit, while the reader
keeps an additive key the engine ignores (`gpty_core::concept::concepts_from_json` reads the keys it
knows, and a legacy `cmd` is explicitly data). A rewrite converges the file to this build's keys:
profile entries are re-serialized from `PluginProfileRecord`, so a newer profile field is dropped
(the GUI then re-infers, as it does for an absent `grid_unit`), while concept entries travel as raw
JSON and keep theirs. A per-record shape failure is the new `StoreError::mismatched` - the file, the
failing field, `different gpty release`, `run the CLI and the GUI from the same release` - and
`is corrupt` is now reserved for JSON syntax, a missing `plugins` array, an IO error and the
256-record cap; the `plugin` surface's stale-binary probe still warns first. Tests:
`additive_keys_read_and_a_rewrite_keeps_only_this_builds_keys`,
`an_unknown_concept_key_reads_but_is_never_written` (the write path still refuses `unknown key`),
`a_record_that_does_not_match_names_the_version_skew`, and the two shape tables lost their
`unknown-key` cases. Measured in a sandbox (`XDG_STATE_HOME`/`XDG_RUNTIME_DIR`/`GPTY_SOCKET` under
one temp dir, 2026-11-16 build): a store carrying `future_record_key`, a profile `color` and a
concept `future` lists as `enabled owner/x @aaaaaaa`; `plugin disable owner/x` succeeds and the
rewritten file holds exactly the six record keys, `name`/`grid_unit`/`tiles`, and the concept's
`future`; a record missing `enabled` prints the skew sentence naming `record 0` and exits 1, with no
`is corrupt` in it.

Commits: 0a028a0, 8bdfbad

## PLUGIN-14

**A plugin cannot declare the four newest event types** - `plugin_manifest::EVENT_TYPES` listed nine
names while the event socket's generic vocabulary (`omp_events.rs`) has ten: `session.shutdown`,
`agent.settled`, `turn.finished` and `tool.finished` were absent, so a manifest subscribing to one
was refused as unknown and `docs/content/docs/agents/plugins.md`'s claim that the validator's list
is the socket vocabulary was false. Fixed 2026-11-15 by removing the second copy rather than adding
four names to it: the generic vocabulary is `gpty_core::events::GENERIC_EVENT_NAMES` (one array,
with a duplicate-name test), the extension's wire table is `WIRE_TO_GENERIC` and a gdext test pins
its generic side against the shared list name-for-name and in order, and the validator's
`event_types()` is the three native names (`NATIVE_EVENT_TYPES` - the GUI's own emitters) plus every
shared name, so an event the socket emits is one a manifest can subscribe to by construction. The
refusal message no longer points at the removed const. Measured with the built CLI:
`type = "session.shutdown"` and `type = "tool.finished"` validate (exit 0), `type = "pane.gone"`
still exits 1 naming it. Tests: `event_types_are_the_socket_vocabulary` (all thirteen parse, and the
count is native + generic), `the_translation_covers_the_shared_vocabulary`,
`the_vocabulary_names_each_event_once`; `crates/gpty-core/README.md`'s module table carries the new
module.

Commits: aaa2c0e, 8c6db51

## PLUGIN-15

**The plugin store has no byte cap, so a planted tile array is read whole** - fixed 2026-11-16
(build 0.8.4): `crates/gpty-plugin/src/store.rs` gained `MAX_STORE_BYTES` (`MAX_PLUGINS` × the 64
KiB manifest cap = 16777216) and one reader, `read_store_text(path)` - it opens the file, reads at
most cap + 1 bytes through `Read::take` (the allocation is bounded; sizing from `metadata()` first
would race the read), refuses a longer file as `<path> is corrupt: more than 16777216 bytes` before
it is decoded, and answers `Ok(None)` for a missing store. `PluginStore::records` parses that text,
and the GUI's two start-up readers (`installed_plugin_profiles`, `installed_plugin_concepts` in
`gpty-gdext/src/bridge_api.rs`) now call the same function instead of `read_to_string`, so the
start-up path is bounded too. The manifest cap moved to `gpty_plugin::schema::MAX_MANIFEST_BYTES`
and `gpty-cli`'s plugin command imports it, so the store's cap and the CLI's manifest check are one
constant rather than a comment. Tests: `a_store_over_the_byte_cap_is_refused_without_being_parsed`
(a *valid* JSON store of 16777217 bytes - the refusal must be the length, not a parse error - whose
message names the path and the cap) and `a_store_just_under_the_byte_cap_reads` (16777215 bytes, one
record). Measured with the built CLI in a sandbox: the 16777217-byte store answered
`error: /tmp/…/state/gpty/plugins.json is corrupt: more than 16777216 bytes`, exit 1; the
16777215-byte store listed `enabled owner/x @aaaaaaa`, exit 0. Docs: `agents/plugins.md` and the
wiki's plugin page state the cap; `godot/knowledge.json` rebuilt.

Commits: 8bdfbad, 47092ee

## PLUGIN-16

**A plugin's output is copied to disk without a cap, and then read back whole** - `run_action`
(`crates/gpty-cli/src/commands/plugin.rs`) starts the action with stdout and stderr in append mode
on `<logs>/<action>-<unix>.log` and never bounds that file, then `read_to_string(&log_path)` loads
all of it to print; `logs()` on the same file load is the same shape, and
`daemon::take_startup_output` (`crates/gpty-cli/src/commands/daemon.rs:374`) reads the GUI's startup
capture whole before keeping only its last 2000 bytes. A plugin is untrusted by the trust model, so
an action that prints without end costs disk linearly and then the CLI's address space in one read
on the next `plugin logs` or `plugin run` (and `--json` embeds the whole text). Fix: one tail-read
helper (open, seek to a bounded window from the end, read only that, sanitise) shared by all three
sites, plus a cap at the writer: past N MiB the child's writes are truncated and the action fails
with a typed notice naming the cap, keeping the exit-code contract and the `--json` keys. Tests: an
action that writes past the cap yields a bounded log and the typed notice, `plugin logs` returns the
last N lines of an oversized file without loading it, and `take_startup_output` keeps the tail of an
oversized capture.

## PLUGIN-17

**The plugin registry's floor is below the profiles feature** - `godot-pty/gpty-plugins` and the
committed `docs/assets/registry.json` still give four entries `min_gpty_version = "0.5.4"`, but
installed-plugin profiles only surface from 0.5.5 (`docs/content/docs/changelog/v0.5.5.md:11`).
`godot-pty/gpty-omp` was raised to 0.5.5 in v0.8.4 along with its `OMP Workspace` profile (manifest,
registry entry and snapshot all say 0.5.5); the other four tool plugins still say 0.5.4, and one of
their READMEs says 0.5.5 while its manifest says 0.5.4. Fix: raise `min_gpty_version` to 0.5.5 for
the remaining four in one sweep, refresh the snapshot, and run `validate.py --check-repos`. A 0.5.4
install currently succeeds and shows no profile, which looks like a broken plugin.

## PLUGIN-18

**The OMP plugin ships no demo clip** - the demo row's OMP-specific cut cannot live in this
repository: the `OMP Workspace` profile and the `omp` launch command are `godot-pty/gpty-omp`'s
surface, so a gPTY-side clip would show a plugin the repository does not ship. Fix: record it in
that repository against an installed plugin - an OMP session beside the Inspector and Reasoning
panes, the state badge named, the `omp plugin link` step visible - with the same CLI-driven method
(`scripts/record-demo` is the reference implementation, including the sandbox, the seeded layout and
the caption encoder) and link it from that README; gPTY's own seven clips stay generic. Validate the
plugin's README link with its own checks; no core change.
