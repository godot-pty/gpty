# Start Here

gPTY is a desktop workspace built on Rust and Godot: a tiling grid of terminal panes and specialty panes, a control socket that scripts and agents can drive, and a small concept engine that routes output between panes. This vault is its knowledge base — plain Markdown notes explaining both the project and the terminal ideas underneath it. It is written for someone who has just opened the app, not for a release note.

Every note starts with a definition you can stop after. If you only read one, read [[gpty]]. If you have the app open and want to do something, read [[getting-started]].

## Read this in the app

Open a **Wiki** pane and set its vault path to the absolute path of this directory — `docs/content/wiki` in a source checkout. The pane lists every note, searches their text, and renders the mentions between them as links.

- Click a note title in the list to open it.
- Click a rendered mention to follow it in place; the note's link panel below the editor shows what it links to, what links back, and which targets do not resolve.
- **Graph** draws the whole vault as a map: notes are nodes, mentions are edges, and an unresolved target appears as a ghost you can turn into a note.
- **Search** is full-text over note bodies, not just titles.

Because the vault is just Markdown files, it also opens in Obsidian or any editor. Nothing in it is stored in a database you cannot see; the index is derived and rebuilt from the files.

## In a packaged build

Release builds carry this vault as a generated bundle: the built-in **Knowledge Base** profile opens a copy seeded into your user data on first use, so the notes are available without a source checkout. The seed is keyed by the vault's content hash — a release whose notes changed seeds a new copy instead of writing over edits you made in the previous one. A checkout keeps `docs/content/wiki` as the source of truth; `scripts/build-wiki` refreshes the bundle and `scripts/build-wiki --check` fails CI when the two drift.

## Pick a path

| If you want to… | Start at |
|---|---|
| Install the app and open your first pane | [[getting-started]] |
| Learn what a PTY, shell, grid, or escape sequence is | [[terminal-foundations]] |
| Know what the app is and what it deliberately is not | [[gpty]] |
| Understand what you see on screen | [[pane]] |
| Drive gPTY from a script or an agent | [[control-api]] |
| Understand this vault, its links, and its graph | [[vault]] |
| Look up one term quickly | [[glossary]] |

## The map

| Cluster | Hub | What it covers |
|---|---|---|
| Product | [[gpty]] | The workspace, its layers, its scope, and the rest of the project notes |
| Terminal foundations | [[terminal-foundations]] | PTYs, shells, emulation, grids, escape sequences, colors, scrollback |
| Panes | [[pane]] | The pane model and all eight pane types |
| Control | [[control-api]] | The JSON-RPC socket, the CLI, and the MCP server |
| Wiki | [[vault]] | Vaults, wikilinks, the link graph, weights, and the note editor |
| Practice | [[agent-workflow]] | Worked recipes for agents, concepts, and vaults |
| Reference | [[glossary]] | Definitions and pointers; [[settings]] and [[keyboard-shortcuts]] live under the product cluster |

The product cluster also holds the pieces a user configures: [[layout]], [[workspace]], [[profile]], [[sidebar]], [[settings]], [[keyboard-shortcuts]], [[concepts]], [[plugins]], and [[security-model]]. Pane types each have a note under [[pane]].

## How the notes are written

- The product is `gPTY` in prose; identifiers stay lowercase and literal — `gpty`, `GPTY_ENV`, `GptyTerminal`.
- A **pane** is what you see and operate. A **tile** is the grid cell and chrome around it; a **body** is the pane-type implementation inside. [[pane]] explains the split.
- Notes describe what exists now. Release notes and the roadmap live in the project documentation, not here.
- Every note ends with **Related**, listing the notes worth reading next. If a note has no way back, the graph has a hole in it.

## What this wiki is not

It is not the changelog, the roadmap, or the developer rulebook. Those track decisions and future work; this vault explains the design as a reader meets it. For build commands and contribution rules, see [[contributing]].

## Related

- [[gpty]]
- [[getting-started]]
- [[terminal-foundations]]
- [[pane]]
- [[control-api]]
- [[vault]]
