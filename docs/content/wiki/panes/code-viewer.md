# Code Viewer Pane

A code viewer pane shows a file's text read-only, with basic syntax colouring, and renders Markdown as formatted prose. It is the pane the file tree opens supported files into, and the pane concepts route command output to.

## What it is

The body is `CodeViewerPane` (`godot/scenes/panes/code_viewer.gd`). It holds two widgets behind one toolbar: a read-only `CodeEdit` for source, and the shared sanitized `MarkdownView` for rendered prose. The registered type key is `code_viewer`, its label prefix is `C`, and it is one of the two pane types that accept routed concept content.

The pane is a viewer, not an editor. There is no save path and no writable state: the file's bytes are read once on open, and the only way to see a newer version is the toolbar's **Reload** button. That is a deliberate trade — the pane's scroll position, selection and rendered/source mode belong to its document, so it is stable while you read.

## When to use it

Use it to read source, config, logs, diffs, or documentation without leaving gPTY. It is also what `cat`-style captures and `git diff` output land in when a concept routes to a code viewer, which makes it the usual place to inspect what a command produced.

For a directory listing use [[file-tree|File Tree]]; for a vault of Markdown notes with editing, links and search, use the [[wiki-pane|Wiki Pane]].

## How to open it

| Method | Action |
|---|---|
| Shortcut | `Ctrl+Shift+D` |
| Sidebar | the code viewer button |
| Palette | `new code viewer` |
| CLI | `gpty new-pane -t code_viewer` |
| MCP | the `new-pane` tool with `type: "code_viewer"` |
| From a pane | activating a supported file in the file tree |
| A concept | any enabled concept whose action targets the code viewer (`cat_command` and `git_diff` ship this way) |

A pane opened from the CLI or API starts empty; the file it should display is pane state, set through Pane Settings or a saved layout tile. A file tree request for a path this workspace already shows in a viewer focuses that pane instead of opening a second copy, because a duplicate would split the scroll and mode state across two panes.

Panes do not spawn panes directly: the file tree emits a request and the workspace decides whether to create a pane or focus an existing one.

## What it shows and how it is driven

The file is read through one shared gate: the path must be absolute, must be a regular file (Godot's regular-file check rejects directories, devices and FIFOs before the GUI thread blocks on an open), and at most 1 MiB is read. A read that hits the cap still displays, with a truncation notice — appended to the text in source view, and shown as a banner above the body in rendered view.

Syntax colouring is deliberately shallow: comment delimiters are registered for `gd`/`py` (`#`) and `rs`/`c`/`cpp`/`h`/`hpp` (`//`), so those files edit and read with sensible comments highlighted; the pane does not ship a full grammar per language.

Markdown gets a second mode. When the language resolves to `md` or `markdown` — from the `language` setting or the file extension — a toolbar toggle appears:

| Stored `view_mode` | What you see |
|---|---|
| `auto` (the default) | Markdown rendered; everything else as source |
| `rendered` | Markdown rendered |
| `source` | the raw Markdown text |

The toggle reads **View source** while rendered and **Render Markdown** while in source. Rendering goes through the same sanitized pipeline the wiki uses: raw HTML and BBCode are escaped, images reduce to alt text, and only `http`/`https`/`mailto` links are kept as links. Nothing in a Markdown file can execute.

When a concept delivers a capture, `receive_content` replaces the pane's text and clears its `file_path` — the pane now shows the capture, not a file, so a later request to open a file must not focus a viewer that no longer displays it. The captured text is the whole document; the only cap that applies is the renderer's own, and it reports itself.

## Settings that matter

| Setting | Values |
|---|---|
| Name | the pane's title |
| Font size | 8–32 px |
| File | absolute path of the file to show |
| Language | `(auto)`, `md`, `gd`, `py`, `rs`, `c`, `cpp`, `h`, `js`, `ts` |
| View | `Auto`, `Source`, `Rendered` |

`Auto` means "render if this is Markdown, otherwise source". Language is only used to decide Markdown-ness and is not a highlighter selection beyond the comment delimiters above.

## What it does not do

It does not edit or save files. It does not open arbitrary binaries: from the file tree, only extensions in the closed `ViewableFiles` table (source, config/data, docs/prose extensions plus a handful of extensionless names such as `Makefile` and `Dockerfile`) are routed here, and anything else keeps the confirm-then-system-handler path. It does not watch the file for changes — Reload is explicit, which also means a file that was moved or replaced by a directory clears the pane instead of showing stale text as if it were current. It does not render images or play media; that is the [[media-pane|Media Pane]].

## Limits and edge cases

Reads are capped at 1 MiB and happen on the GUI thread, so a pathologically large file costs the first MiB, not the whole file. The truncation notice is how you know. A capture arriving while a file is open replaces the document permanently — reopening the file is a new pane request. Saved layouts record `file_path`, `language` and `view_mode`, so a viewer reopens on the same file in the same mode.

## Related

- [[pane]]
- [[file-tree]]
- [[wiki-pane]]
- [[concepts]]
- [[vault]]
