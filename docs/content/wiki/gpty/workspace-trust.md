# Workspace Trust

Workspace Trust is the consent dialog that stands between a saved file and a process. Restoring a layout, activating a profile — including one an installed plugin ships — can start programs; the dialog asks before a file decides something you did not.

## What a restore can run

A terminal tile's spawn is a program plus an argument array — never a shell string. Both come from the tile's saved settings:

| Key | Precedence |
|---|---|
| `command` | First choice |
| `shell` | Second choice |
| the tile's legacy `shell` | Last resort |
| `shell_args` | Appended arguments |

A tile is **untrusted** when its program differs from your current default shell command, or when it carries any non-empty `shell_args`. Both matter: a `shell`-only check once missed a tile that shipped `command` or an argv payload like `["-c", "…"]`. A tile that matches your defaults needs no prompt — restoring it starts what you would have started anyway.

The same keys gate `cli_view`, whose pane runs its argv directly. Installed plugin profiles go through the same gate, because their tiles are saved content too.

## When the dialog appears

The prompt appears when a restore would spawn a different program or extra arguments, on the paths where a user is present to answer:

- restoring the saved workspace set at startup, or reloading it with the palette's load action;
- activating a profile from the sidebar.

On the workspace path the dialog describes every affected workspace. Cancelling does not run the file's programs: the affected workspaces are rebuilt with their panes dropped, so the app opens without the untrusted spawns.

Over IPC, `layoutLoad` **refuses** an untrusted profile instead of prompting. A caller cannot answer a dialog, so naming a profile is not consent to what the file asks for. It loads only when the consent record already covers the content.

## The consent key

Consent is per spawn plan, not per file. The key is the exact program and argv joined in order, with a unit separator between parts — the same derivation the trust predicate uses, so the thing shown in the dialog, the thing stored, and the thing checked can never drift. A file that changes one argument is a new decision.

The dialog shows the plan rather than a summary sentence: which pane type, which program, which arguments. Values are escaped and length-capped because they are attacker-controlled file content, and newlines in particular would forge an extra dialog line.

## Who records consent

| Content | Approval recorded as | Invalidated by |
|---|---|---|
| Builtin profile | Profile name + app version + every tile's spawn plan | A new gPTY version |
| Installed plugin | Plugin id + pinned revision | A new revision |
| User-authored profile | Nothing | — (asks each time) |

Only the trust dialogs' confirm paths write records. A user-authored profile never records consent, so approving one does not make the next activation silent. A builtin ships with the app, so its approval is tied to the version that shipped it: a new release re-prompts by construction. A plugin is approved at the revision the install pinned, so a moved tag or new commit re-prompts.

The store is `user://trusted.json`, with two namespaces: `builtins` mapping a name to a version and a list of plan keys, and `plugins` mapping an id to a revision. It is hand-editable, so it is read like any other untrusted file: typed reads, shape checks, and caps on entries, name and version lengths, plan counts, and key length. A bad entry costs itself, not the file.

That also describes revocation: remove the entry — or delete the file — and the next launch reads a store with no record, so the next restore asks again. The store is a memory of approvals, not a lock.

## Why environment is not a file decision

Environment reaches a child as authority, not configuration. A saved tile's `shell_env` is dropped on restore with a notice naming what was dropped; it never reaches a spawn, so there is no env clause in the trust predicate and nothing to show in the dialog.

Per-pane environment is yours: it lives in `user://pane_env.json`, keyed by the pane's stable id, written only by the pane settings UI, and applied at spawn over your global environment. A file cannot supply it. The environment a pane still inherits is the GUI's own — that is a real boundary and is covered in [[security-model|Security Model]].

## Limits

The gate is about **what runs**, not about what a program then does. After you approve, gPTY runs what the file asks for, with your permissions, in a shell that can drive the rest of the workspace. The dialog exists so that decision is explicit, not so it is harmless. Approvals are also per machine and per user; copying `trusted.json` to another machine carries your decisions with it.

## Related

- [[gpty]]
- [[security-model]]
- [[profile]]
- [[workspace]]
- [[plugins]]
