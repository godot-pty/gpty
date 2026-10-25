# Getting Started

This is the shortest path from a download to a workspace you understand. It assumes you have used a terminal before, not that you have used gPTY.

If you want the ideas first, read [[gpty]]; if you want to build from source, see [[contributing]].

## Get the app

Release bundles are standalone: they carry the engine and the export, so you do not need Godot installed.

| Platform | Package |
|---|---|
| Linux | `gpty-v<version>-linux-x86_64.tar.gz` — extract; `./gpty-gui.sh` starts the GUI, `./gpty` is the CLI |
| macOS | `gpty-v<version>-macos.zip` — unzip; right-click the `.app` → Open; `gpty` sits beside it |
| Windows | `gpty-v<version>-windows-x86_64.zip` — unzip; `gpty-gui.exe` starts the GUI, `gpty.exe` is the CLI |

Each release publishes `SHA256SUMS`; verify the download before running it. Assets also carry a build-provenance attestation. The binaries are not code-signed, so the checksum and the source are the trust path.

The CLI is the same binary family as the GUI. It talks to a running GUI over a local socket and does not need a toolchain.

## First launch

Start the GUI. On a fresh profile you get **Workspace 1** with one terminal pane, already focused. Type a command; it runs in the shell gPTY started for that pane.

The window has three regions:

- The **sidebar** on the left: window mode, workspaces, profiles, and pane rows. `Ctrl+Shift+B` hides it.
- The **grid** in the middle: every pane is a tile here. Drag a divider to resize.
- The **titlebar** above each pane: the pane name, and its minimize, position, type, settings, and close controls.

The **command palette** (`Ctrl+Shift+P`) is the fastest way to create a pane: type `new` and pick a type. The sidebar's `+` button and the per-type shortcuts do the same thing.

## Learn five shortcuts

| Keys | What it does |
|---|---|
| `Ctrl+Shift+N` | New terminal pane |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+Shift+W` | Close the focused pane |
| `Ctrl+Shift+B` | Toggle the sidebar |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | Copy the selection / paste |

`Ctrl+V` on its own is deliberately sent to the shell as `^V`; readline and vim use it. Paste is always `Ctrl+Shift+V`. The full list is in [[keyboard-shortcuts]].

## Make the grid yours

New panes join the tiling grid; there is no separate "split right" mode to learn first. Drag the dividers to trade space. The sidebar's pane rows can minimize a pane, move it, change its type, open its settings, or close it.

Two ideas are worth separating now, because the rest of the app depends on them:

- A **layout** is the arrangement of panes in one workspace. The palette's `save` writes the whole workspace set to disk, and `load` reloads it; the workspace you close is auto-saved too.
- A **profile** is a reusable named set of tiles. Save one from the sidebar's Profiles `+` button, or with `gpty layout save <name>` (the CLI keeps the older "layout" verb; the record is a profile).
- A **workspace** is a tab containing its own layout and its own default directory. Create one from the sidebar; switch with `Ctrl+PageUp` / `Ctrl+PageDown`.

The workspace you close is auto-saved and restored on the next launch. [[layout]], [[workspace]], and [[profile]] explain the differences; [[profile|Profiles]] also lists the shipped **Agent Workspace**.

## Try the non-terminal panes

| Pane | Open it | Try |
|---|---|---|
| [[code-viewer]] | `Ctrl+Shift+D`, then pick a file | Read a source file without leaving the app |
| [[file-tree]] | `Ctrl+Shift+T` | Browse a directory; supported files open in a viewer or media pane |
| [[wiki-pane]] | Palette → `new wiki`, or the sidebar's **Knowledge Base** profile | Read the bundled wiki, or point a pane at any Markdown vault |
| [[media-pane]] | Palette → `new media`, or a media file from the file tree | Play a local audio or video file |
| [[cli-view]] | Palette → `new cli view` | Stream a command's stdout without a PTY |
| [[inspector]] | `Ctrl+Shift+O` | Ask a private, read-only question about what is on screen |
| [[reasoning]] | Palette → `new reasoning` | Watch an agent's lifecycle events (needs the OMP extension) |

The Inspector is a private Q&A session, not a chat with the terminal's agent. Reasoning is passive; it shows events a cooperating agent emits and never drives it.

## Automate something small

The GUI owns the workspace; the CLI is a stateless client. With the GUI running:

```bash
gpty list-panes
gpty new-pane --pane-type terminal --command "cargo test" --title tests
gpty pane-wait T2 --pattern "tests passed" --timeout-ms 30000
gpty pane-read T2 --lines 40
gpty pane-status T2
```

`pane-run` opens a new terminal pane and runs a command through your configured shell. `pane-wait` matches a Rust regex against recent output. `pane-read` is a snapshot of screen plus scrollback, not a stream. [[control-api]] has the whole surface; [[agent-workflow]] has the recipes an agent should follow.

## Read this wiki in gPTY

Open a Wiki pane, open its **Pane Settings**, and set the vault path to the absolute path of this directory (`docs/content/wiki` in a checkout). The notes list opens; `Graph` draws the link structure. Click a mention to follow it, and use the link panel under the editor to see backlinks and unresolved targets.

This is also the best way to see what the wiki pane does before you write your own notes. [[vault-workflow]] walks through opening a vault and writing the first note.

## Where to go next

| If you want to… | Read |
|---|---|
| Understand the panes | [[pane]] |
| Learn the terminal concepts | [[terminal-foundations]] |
| Route output between panes | [[concepts]] |
| Understand what is trusted | [[security-model]] |
| Build or modify gPTY | [[contributing]] |

## Related

- [[index]]
- [[pane]]
- [[layout]]
- [[workspace]]
- [[control-api]]
- [[vault]]
