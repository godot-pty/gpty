# Profile

A profile is a named, reusable set of tiles. Activating one replaces the panes of the active workspace with a copy of that set; the profile itself stays unchanged for the next activation.

## What is in a profile

A profile holds a list of tiles, each with the same geometry a layout uses — `col`, `row`, `cspan`, `rspan` on the 60-unit grid — plus the settings for the pane that goes there. Because it is a template rather than a live workspace, it stores no processes, no scrollback, and no environment: a profile that once contained a terminal's `shell_env` is stripped on restore, with a notice, because environment is user-owned and lives in its own store (see [[settings]]).

Activating a profile resets the active workspace and rebuilds its panes from the profile's tiles. That is why a profile behaves like restoring a layout, and why it can trip the same Workspace Trust gate described in [[workspace-trust]].

## Where profiles come from

There are three sources, shown in one list in the sidebar's Profiles section.

**Shipped, then seeded.** gPTY ships two layouts in `res://profiles.default.json`: **Agent Workspace** — a wide terminal on the left with an Inspector and a Reasoning pane stacked on the right, wired by the stable attachment ids `omp-terminal`, `omp-inspector`, and `omp-reasoning` — and **Knowledge Base**, a Wiki pane opened on the bundled vault through the `@knowledge` token. On the first launch of this build both are copied into `user://profiles.json` as ordinary user profiles; the seed file is never written back, and the `seeded_defaults` marker stops a deleted copy from returning. Both name no program, so activating one raises no trust dialog. Because they are user profiles, they are renamed and deleted exactly like any other row.

**Installed with a plugin.** The single-pane tool presets — Herdr, Lazygit, Neovim, Claude, and OMP — arrive from their own plugin repositories, one profile per tool, each restoring a full-window terminal that runs that tool. The two shipped layouts are also published as `godot-pty/gpty-agent-workspace` and `godot-pty/gpty-knowledge-base`. None of the tool presets installs the OMP event extension or launches `omp` for you; you do that inside the terminal. Plugin profiles are re-read from the installed-plugin store, are never written into the user profile file, and disappear with the plugin. Their sidebar rows show where they came from (`owner/repo@revision`) and carry a trash that uninstalls the plugin after an in-place check/cross; uninstalling removes every profile and concept the plugin ships. Plugin rows offer no rename. Installing a plugin whose profile name matches one of your profiles names the replacement in the install review; accepting gives the plugin's copy the bare name once the install lands.

**Saved by you.** The `+` button in the Profiles header captures the active workspace's current tiles as a new profile. The dialog asks for a name and lets you edit each pane's command before saving, which is how you turn a working arrangement into a repeatable one. User profiles live in `user://profiles.json`.

Name collisions are resolved with a ` (n)` suffix rather than overwriting: a user profile keeps the bare name and a colliding plugin profile yields, while among plugin profiles the first one wins. Saving or renaming a user profile into an existing user-profile name asks to replace it; a name held only by a plugin is not a replacement target, so the user profile takes it and the plugin yields. Double-clicking a user profile row renames it; its delete button removes it. Deleting or renaming a profile also clears or updates the accent on any workspace that had activated it.

## Activating a profile

Clicking a profile row activates it. If the active workspace has panes, gPTY asks first, because activation replaces the current layout. Each pane still gets its own close guard, so unsaved work — a wiki note with edits, for example — can cancel the whole activation.

Before anything is torn down, the trust check runs. A profile whose tiles would start a different program or pass extra arguments compared with your configured shell raises a Workspace Trust dialog naming the program and arguments. Approvals are remembered narrowly:

| Profile source | What an approval covers |
|---|---|
| Plugin | That plugin id at the exact installed revision, and the spawn plans the install review listed; a new revision asks again, and so does different content under the same revision |
| Saved by you (including the seeded defaults) | Ask every time, unless every untrusted spawn plan was already approved through an old built-in record |

Where a profile came from is recorded by gPTY when it loads it, not read from the file. A hand-written `profiles.json` entry cannot claim to belong to an installed plugin (the legacy `builtin` claim is stripped too): those fields are removed on load, so the entry is your profile and goes through the same plan check as any other. An approval also covers only the plans it recorded, which is why a profile whose tiles changed under an approved revision asks again.

The seeded defaults are user profiles, so they consult no name+version record of their own. `trusted.json`'s legacy `builtins` namespace and `approved_plan_keys()` stay readable so a workspace saved from a pre-seed built-in still restores under the approval it recorded; both shipped defaults name no program, so they would not prompt anyway.

A saved-by-you profile never writes a consent record, so it is a fresh decision each activation. The dialog's Cancel activates nothing and leaves the workspace as it was.

The activated profile's name is remembered by the workspace that activated it, and its row is accented while that workspace is active. Resetting the workspace's panes (`Ctrl+Shift+R` or the Panes title row's close-all) clears that state, because an empty layout is no longer that profile. **Clear Workspace** in a workspace row's More menu clears that workspace's accent too.

## Automation

The control API's layout commands operate on profiles:

```bash
gpty layout save "Review"
gpty layout load "Review"
gpty layout list
```

`layout save` captures the active workspace under the given name, creating a user profile; `layout load` activates a profile by name; `layout list` prints every visible profile name. The same methods are available as the `layout-save`, `layout-load`, and `layout-list` MCP tools.

A caller cannot answer a dialog, so these paths are stricter than the sidebar. Loading a profile that would spawn an unapproved program or argument list is refused with an explanation instead of prompting, and loading is refused when a pane in the active workspace holds unsaved changes. A running process is not a reason to refuse — naming the profile is taken as consent to stop what it replaces. Loading also starts the GUI when needed, unlike queries.

## Profile, layout, workspace

| Term | Meaning |
|---|---|
| Profile | A named template of tiles, reusable across workspaces |
| Layout | The arrangement currently inside one workspace |
| Workspace | The tab that owns a layout and a directory |
| Pane | One unit placed by either |

Saving a profile copies the current layout; activating one copies the profile's layout back into a workspace. Neither operation changes the other: editing the workspace afterwards does not edit the profile, and there is no implicit "update profile" action — save a new profile instead.

## Related

[[gpty]] · [[layout]] · [[workspace]] · [[sidebar]] · [[plugins]] · [[workspace-trust]]
