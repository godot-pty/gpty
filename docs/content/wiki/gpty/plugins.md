# Plugins

A gPTY plugin is a Git repository containing a `gpty-plugin.toml` manifest that adds profiles, concepts, link handlers, actions, and event bindings to a workspace. Plugins are installed explicitly, reviewed by a human in the GUI, and then run with your authority — they are the guest at the outer edge of the [[gpty|gPTY]] trust boundary.

## What a plugin contributes

A plugin is data plus commands, not a library loaded into the process. There is no plugin ABI, no in-process callback surface, and no way to replace a pane type. What it can do is narrower:

| Section | What it adds |
|---|---|
| `[[profiles]]` | Named tile sets that appear in the profile list — a workspace layout to open |
| `[[concepts]]` | Regex triggers that capture terminal output into a pane |
| `[[actions]]` | Named commands a user (or `gpty plugin run`) can invoke |
| `[[events]]` | Declared event subscriptions, shown in the review; gPTY does not dispatch them, and the plugin reads the event socket itself |
| `[[link_handlers]]` | Declared URL-scheme handlers, validated and shown in the review; no current runtime opens a link through one |

Every one is a declaration: install validates the file; the GUI decides when a profile opens or an action runs. Profiles and concepts are the two sections the runtime actually consumes; actions are invoked manually with `gpty plugin run`.

## The manifest

The schema lives in `crates/gpty-cli/src/plugin_manifest.rs`. Top-level keys:

| Key | Rules |
|---|---|
| `id` | `owner/name`, parts `[a-z0-9-]`, 1–63 characters each |
| `name` | 1–64 characters |
| `version`, `min_gpty_version` | Semver `X.Y.Z`, no pre-release |
| `platforms` | Subset of `linux`, `macos`, `windows`; default all |
| `build`, `startup` | argv arrays, declared and displayed but not executed by any current item |

The array-of-table sections each have a cap: `[[actions]]` ≤64 (`name`, `command`, optional `args`), `[[events]]` ≤64 (`name`, `type`), `[[link_handlers]]` ≤16 (`scheme`, `command` argv), `[[concepts]]` ≤128, `[[profiles]]` ≤64 with ≤64 tiles each.

Three rules make the manifest safe to read:

- **Nothing executes at parse or validation time.** `build`, `startup`, and link-handler commands are argv arrays, never shell strings, capped at 32 entries and 4096 characters; an action's `command` is a published tool name and its `args` become flags.
- **Every concept is engine-accepted.** Each `[[concepts]]` entry round-trips through the real concept engine (`concepts_from_json`). An entry the engine would silently drop — a PCRE2 lookbehind, say, when the engine speaks Rust `regex` — rejects the manifest instead of vanishing.
- **Tiles mirror the GUI's sanitizer.** Pane type must be one of the eight real types, grid geometry must fit the 60-unit grid, rows and cols within 500 and 2000. The sanitizer clamps legacy files; the validator rejects, because a manifest is authored content and an out-of-range value is an authoring error.

Unknown keys in manifest sections are rejected. The schema is closed: a typo fails at validate time instead of surfacing later as a missing feature.

## Install, review, pin

```bash
gpty plugin install godot-pty/gpty-omp
gpty plugin install godot-pty/gpty-lazygit@v1.2.0
```

Install clones `https://github.com/<owner>/<repo>` — git driven by argv, never a shell — into a staging directory under the data directory. It accepts any advertised git ref: tag, branch, or commit SHA. A bare install means the default branch's latest.

Before anything lands it gates the manifest: the `id` must equal the install target, the current platform must be declared, and `min_gpty_version` must not exceed the CLI. Then, because the plugin's actions will run as you, it sends a summary over the `pluginInstall` IPC method for a human to accept in the GUI. The review dialog shows the requested ref beside the resolved revision and prints the distinct programs a profile's tiles would run. No GUI answering — declined, disconnected, `--no-daemon` — means nothing installs.

Content moves to `data_dir()/plugins/<id>`, runtime directories are created under `state_dir()/plugins/<id>/{config,state,logs}`, and a record lands in `state_dir()/plugins.json` with the resolved SHA and the manifest's profiles and concepts. **The store pins the SHA**, not the tag: a moved tag is a new revision and triggers a re-review. The GUI never parses TOML: the validator stays the single gate, and a broken record degrades one entry at a time.

Every `plugin` command reads the running GUI's version before it does anything else — bounded, best-effort, silent when no GUI answers. The store is shared state, so a CLI older than the GUI beside it rejects record keys it does not know and reports `plugins.json` as corrupt; that is what a stale `gpty` on `PATH` looks like. The warning names both versions and the fix: reinstall the CLI, or use the one shipped beside the GUI.

## The trust model

The review dialog is not a formality. A plugin's actions run as the user, through the same API a person at the CLI uses, so installing one is granting a third party the ability to create panes, inject keystrokes, and read your vault through your own account. That is why install always asks, why `pluginInstall` is deliberately not an MCP tool — a client cannot answer a dialog — and why the review names the programs the profiles would run.

The blast radius is bounded by published surfaces, not by sandboxing:

- **Actions may only name published tools.** `[[actions]].command` is validated against the same list `schema::mcp_tool_names()` derives — the 22 MCP tools. A manifest cannot name anything else on the socket.
- **Event types are a closed vocabulary.** `pane.spawned`, `pane.killed`, `concept.matched`, `state.declared`, plus the generic OMP set (`session.bound`, `agent.started`, `turn.started`, `tool.call`, `thinking.delta`). Adding one is a deliberate change in lockstep with the emitting side.
- **Concepts capture and route display content only**; they never execute. Plugin concepts are the same engine objects a hand-written concept is.
- **Profiles are consented at the pinned revision.** Opening a tile that would spawn a different program or argv is already a [[workspace-trust|Workspace Trust]] decision; plugin profiles go through the same gate.

What none of this prevents is a plugin running arbitrary code in the panes it spawns, with a concept of its own choosing. The [[security-model|Security Model]] treats plugins as untrusted guests for that reason: they are gated at install and at the API surface, not contained at runtime.

## Managing installed plugins

| Verb | Effect |
|---|---|
| `gpty plugin list` | Installed records, their revision, and enabled state |
| `gpty plugin enable <id>` / `disable <id>` | Flip the record; a running GUI updates its profile list, or reads the store on next launch |
| `gpty plugin uninstall <id>` | Remove the record and directories; the GUI drops its profiles |
| `gpty plugin logs <id>` | Read the plugin's captured action output |
| `gpty plugin run <id> <action>` | Spawn the action's CLI command through `GPTY_BIN_PATH` and print its output |
| `gpty plugin validate <path>` | Run the shipped install validator offline |


## The authoring loop

`gpty plugin validate` is the whole local loop: it runs the same parser and gates the install uses, on a plugin directory or its manifest, with no GUI and no network. `--json` prints `{"ok": …}` and exits 1 on rejection, which is what a plugin repo's CI runs. Each first-party plugin repo — one per tool, each a single manifest — validates its own checkout and keeps a one-line assertion that its `id` equals the repo name, because that equality is the install gate's contract and the validator cannot see the repo.

The plugin verbs are CLI-only: `install` waits on a human, and the admin verbs touch local state rather than the workspace API, so none of them are MCP tools.

## Related

[[gpty]] · [[workspace-trust]] · [[security-model]] · [[profile]] · [[concepts]]
