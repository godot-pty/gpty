---
title: "Roadmap details - DOCS"
weight: 900
build:
  list: never
---

Every DOCS row, by ID and in allocation order. The queue and its priority live on the release chain pages; this page is the evidence behind each row.

## DOCS-1

**Documentation hub** - docs sidebar restructure (crate READMEs under Overview), dev setup
consolidated into CONTRIBUTING.md

Commits: d17bac7

## DOCS-2

**Documentation overhaul** - MCP integration, crate README accuracy, testing guide with explicit
gaps

Commits: d17bac7

## DOCS-3

**ADE boundary & security rules in AGENTS.md** - layer model, non-goals, and OSC/plugin/broadcast
constraints (the "why not" record).

Commits: d17bac7

## DOCS-4

**Docs site** - the security policy is published (threat model, supported versions, reporting), the
GPL text and the license exceptions are rendered as pages, and the docs build verifies the mirrored
README actually baked into the overview (a wrong mirror fails the deploy instead of shipping
silently). Also shipped without a roadmap item.

Commits: d17bac7

## DOCS-5

**Stale `get_grid_rows()` references in the FFI docs** - closed: the three prose names are the real
ones, and the class is now unavailable to the next writer. `crates/gpty-gdext/README.md`'s tips
bullet and the `start_shell` / `get_grid_generation` doc comments name `get_rows()`/`get_cols()`
(ints; `0` when the lock is unavailable or no shell has started) and `get_grid_updates_packed()`,
whose lock-unavailable answer is an empty `Dictionary` - the old prose said `[]`, which was wrong
about the fallback as well as the name. The fix that outlives the typo is
`scripts/check-ffi-surface`'s new docs pass: a backticked `name(...)` in the crate's README or in
its `///`/`//!` comments must be an export, a plain `fn` in the crate, or a `DOC_ALLOWED_NAMES`
entry (the four Godot callbacks, `state_dir` from gpty-ipc, and `IpcServer::serve` - each with its
reason, the fail-closed shape `INHERITED_MEMBERS` already had). It found a second name on its first
run and reports the mutation that proves it bites: 78 doc names checked, `get_grid_rows()` fails it
with "not an export of this crate and not a plain fn". The crate README's mirror under
`docs/assets/repo/` moved with it, because `docs/setup.sh` copies that file verbatim at site-build
time.

Commits: d17bac7

## DOCS-6

**Wiki security notes in AGENTS.md** - vault content is user data but untrusted input to the
renderer: sanitized Markdown pipeline only; wikilinks resolve within the vault (no arbitrary file
reads). AGENTS.md now states the rule where the other security constraints live (the "Layout restore
trust" bullet) and beside the link vocabulary (the wikilinks bullet): note text reaches only the
sanitized Markdown pipeline, a mention is rendered by that renderer from the note's own text as a
percent-encoded `gpty-note:` URL (label escaped, scheme emitted by no other path - a document's
Markdown link still admits only http/https/mailto), `MarkdownView` announces the click instead of
opening anything, `vault_link_resolve` maps the target to a note in the index rather than a path,
and the pane opens it through `vault_note_read` - the same containment, 1 MiB cap and regular-file
gate as any other note read. The pane bullets carry the operational half (the parser's
fence/span/escape rules, ambiguity never silently picked, the panel's display caps) so a later
change has one place to read before touching it.

Commits: d17bac7

## DOCS-7

**The v0.7.1 changelog names the terminal selection fixes** - written 2026-11-01 as
`docs/content/docs/changelog/v0.7.1.md` (weight 0) and linked from `CHANGELOG.md`, with `docs-check`
holding the index and the page directory in bijection. It covers these user-visible changes from the
2026-10-26 fix: a bare `Ctrl` or `Shift` no longer snaps a scrolled-back pane to the bottom, so
`Ctrl+Shift+C` on scrollback works; the selection now stays on its text when the view scrolls
(wheel, PageUp/PageDown, search jump) and when output arrives, instead of holding a fixed screen
row; copy reads grid rows, so a selection scrolled out of view still copies in full; wrapped lines
copy joined instead of gaining a newline at each wrap; and the selection is dropped when the
terminal width changes or an app switches to the alternate screen (alacritty's rule - the old
highlight silently survived and landed on different text). Evidence: `term::tests::selection_*`
(view scroll, output at the bottom, output while scrolled back, off-screen copy, mid-drag rotation),
the `test_copy_routing` / `test_keyboard` / `test_gdext_ffi` GUT coverage, a live-pane smoke with a
real shell, and a full `./scripts/ci-check` run. It also covers the escape-string guard (**A program
can grow the GUI's memory without bound by opening an escape string and never closing it**): a
pane's output can no longer hold the grid's parser inside an OSC and grow the GUI, because the
string is closed at 64 KiB - on Linux and macOS, where gPTY sees the child's bytes directly. The
same page covers **A program can create panes without limit through the control socket**: a window
now holds at most 96 live panes across its workspaces, `new-pane`/`pane-run` past that answer with
the limit instead of starting a process per call, and a layout or profile with more tiles restores
what fits and says how many did not. It also names the v0.7 page's two store-and-log items: a store
written by an older build is repaired to owner-only when it is next read, the user directory is kept
at 0700 with its log files at 0600, and an agent backend's stderr no longer reaches the console or a
log file at `warn` (it is sanitized, bounded, `debug`-level, and shown in the failure message
instead). And it records the control-surface work closed the same day: `new-pane --split` places the
new pane on the named side (falling back to the larger-axis split when the grid cannot honour it), a
handler refusal reaches the CLI and MCP caller as its own sentence
(`error: rpc error -32000: Pane 'x' not found`) rather than a stringified JSON envelope, an MCP tool
failure is a successful response with `isError: true` and the sentence in `content` instead of a
protocol error, and the unused `gpty-ipc` typed request models are gone so the handlers'
`params.get(...)` keys are the wire vocabulary. The page must also name the two user-visible changes
this release's security rows added: `vault search`/`vault read`/`vault weight` now answer only for a
vault the user has opened in a Wiki pane's settings (a refused root says `not registered` and how to
fix it), and a media file that claims a pathological sample rate is refused with `too_large` instead
of decoding. One more user-visible fix belongs on that page: the close confirmation now also asks
when a terminal's I/O task has died while its child is still running — previously that pane read as
idle and closing it killed the surviving process group without a question. It also carries the two
fixes closed the same day (the Windows pipe claim and the non-blocking seek), the release asset set,
and the workspace-directory, Inspector-aim and profile-provenance work from the `v0.7.0..HEAD`
commit range.

Commits: 02343a4, 3823302, a2c5002, 20a903a, 69f1db3, e158f5f, 9630fb5, df2ba34

## DOCS-8

**The README and docs home show a scripted demo, not a screenshot** - `scripts/record-demo <scenario>`
launches a sandboxed gPTY (own data dir, HOME and IPC socket), seeds a workspace, drives it with the
`gpty` CLI the way an agent would, records the window with ffmpeg and burns in captions; output is
`docs/static/images/demo-<scenario>.{gif,mp4,webm}`. The README embeds the GIF; the docs home plays
the WebM/MP4 through a `video` shortcode. It simulates no keyboard or pointer input. Re-record it
when the UI changes. The two scenarios this row shipped (`hero`, `tour`) were replaced by seven
named ones in **Demo videos: one per workflow, not one hero GIF**; `demo-hero.*` is deleted, and
`demo-tour.*` now plays from the v0.7.2 post instead of the docs home. Found while building it: a
pane strips `GPTY_SOCKET`, so a CLI typed into a pane reaches whatever owns the default socket; the
script exports it from the sandbox's `.bashrc` so a recording can never drive a real session.

Commits: e090bfb, 6cecfd6, f6ff07a

## DOCS-9

**The v0.7.2 changelog records the hygiene work and the runtime fixes** - release-time work: write
`docs/content/docs/changelog/v0.7.2.md` and link it from `CHANGELOG.md`. Lead with the fixes a user
can act on - the Knowledge Base profile opens again, a `res://`/`user://` value is no longer
accepted where a real path is required, and the media pane no longer retains its read buffer per
open - then say plainly that the rest of the release is hygiene with no user-facing change and cover
what a reader can act on: the `v*` tag ruleset, the dependency-source and licence policy
(`deny.toml` and its CI job), OpenSSF Scorecard and the dependency-update bot, the fuzz targets and
how often CI runs them, and the `unsafe` fencing rule that now fails a build rather than a review.
Shipped 2026-11-02: `docs/content/docs/changelog/v0.7.2.md` is the page
(`title: "v0.7.2 - 2026-11-02"`, weight 0, with the ladder shifted one slot - v0.7.1 takes 10,
v0.1.0 160), linked first from `CHANGELOG.md`. It opens with the three fixes a user can act on - the
Knowledge Base profile opening again, a `res://`/`user://` value refused where a real path is
required, and the media pane no longer retaining its read buffer - states plainly that the rest is
hygiene with no runtime delta, and covers every item this row named: the `v*` tag ruleset (signed
tags required, org-admin bypass, `git tag -s` and `git tag -v` before the push), `deny.toml` with
its `cargo deny check` step and CI job, OpenSSF Scorecard (first baseline 7.7 overall,
Branch-Protection 6/10) and the grouped weekly dependency-update bot, the seven fuzz targets with
the per-PR build and nightly five-minute runs, and the `unsafe` fences (the two lints in five
crates, the CLI's `forbid(unsafe_code)`). The rest of the release a reader can act on is recorded
too - `main` protection, the docs-only path split, the cache-key and FFmpeg-prefix fixes, the
`tempfile` artifact guard, the citation gate, the MCP registry trigger, the Windows `--tests`
cross-check, the README badges and the docs-site icons, and the `gut-check` watchdog with its stall
attribution. `python3 scripts/docs-check` is green over the index/page pair, the weight ladder and
the citation set.

Commits: 39085e9, 81809dc

## DOCS-10

**The docs site still showed Hextra's favicon and had no Reddit link** - replaced the theme's
favicon set with the app icon. `assets/site-icons/` now holds `favicon.ico` (the app's 7-size ICO,
16-256), 16/32 PNGs, a 180px Apple touch icon, 192/512 Android icons, a traced `favicon.svg`
(potrace over the blue linework, 1.7 KB, so `/favicon.svg` is not the theme's mark), and
`site.webmanifest`; `docs/hugo.yaml` mounts the directory as a second `staticDir` and
`docs/layouts/_partials/favicons.html` is the one place the links are declared. The navbar gains a
Reddit icon left of GitHub. Because the pinned Hextra v0.12.3 has no remote icon provider (that
landed in v0.13.0), the Simple Icons `reddit` SVG (CC0) is vendored in `docs/data/icons.yaml` - a
build-time CDN fetch would add an unpinned dependency to every docs build, against the repo's
supply-chain rule. Verified by a full `hugo` build: every copied icon hash matches
`assets/site-icons/`, the head links are the new five, `/favicon.svg` is the trace, and the navbar
renders both `reddit` and `github`; `assets/site-icons/**` is in the Docs workflow's paths, both
code-workflow `paths-ignore` lists, and `ci-check`'s docs class, so an icon-only change is validated
by the build that consumes it.

Commits: 2ba3a60

## DOCS-11

**The v0.8.0 changelog records the audit baseline and the design system** - released 2026-11-06:
`docs/content/docs/changelog/v0.8.0.md` (linked from `CHANGELOG.md`; the weight ladder moved up one
step for every existing page so the new one takes 10, because Hugo reads `weight: 0` as unset and
dropped the page out of the section nav - caught by a local `hugo` build, not by the gates) covers
the re-baseline and the 21-state capture harness, the token module and the one `Theme`, the UI scale
and its window cap, the dark/light palette with `Appearance: follow system`, the accessibility
surface and its AT-SPI probe, the icon-button treatment and the picker frame, the keyboard rings,
and the fixes the audit's findings became. Six captures of the finished surfaces ship -
`v0.8.0_1.png` (a fresh launch) through `v0.8.0_6.png` (the four agent badges) - every one taken by
`scripts/screenshot-gpty` in its sandbox, and `docs/content/blog/v0.8.0/index.md` carries the
narrative.

Commits: 6cecfd6, ae22ac5, 697125c

## DOCS-12

**The v0.8.1 changelog records the chrome, palette and discoverability work** - released 2026-11-10:
`docs/content/docs/changelog/v0.8.1.md` (linked from `CHANGELOG.md`; the weight ladder moved up one
step for every existing page - 190 down to 20 - so the new page takes 10) covers the three-control
pane bar and its one action menu, the 15-entry palette with its glyphs, chords and keyboard cursor,
the saved-command store and its Settings tab, the Add Pane header and help table with the About
shortcut list, the search strip's `n/m` count and the toast contrast, the Feedback row, the
return-to-live-output chevron, the window and toolbar keyboard rings, the scrollbar geometry, the
`ExternalLink` refusal path, both stores' `.corrupt` recovery, the fitted spawn size, and the IPC
refusal-code rule; the captures are `v0.8.1_1.png` (home), `v0.8.1_2.png` (the palette with saved
commands), `v0.8.1_3.png` (the search strip), `v0.8.1_4.png` (the Add Pane help table),
`v0.8.1_5.png` (the four badges) and `v0.8.1_6.png` (return to live output).

Commits: 6cecfd6, e81de90, 88b9b06, aea17ed, 0b50855

## DOCS-13

**The v0.8.2 changelog records the interaction and responsiveness fixes** - released 2026-11-12:
`docs/content/docs/changelog/v0.8.2.md` (linked from `CHANGELOG.md`; the weight ladder moved up one
step for every existing page - now 200 down to 20 - so the new page takes 10) covers the
empty-workspace shortcut guide and its keycap action, the explicit workspace and pane close
affordances with the zero-workspace first run, the seeded default layouts and plugin-profile
uninstall, the active-pane, close-fallback and empty-restore repairs, the clamped dialogs, the flood
cadence under typing, the workspace-switch cost and its measured fixes, the FPS-only status bar, and
the sidebar rename and centering repairs.

Commits: 8dc74eb

## DOCS-14

**The IPC page says event subscribers receive agent state and the OMP event set** - fixed 2026-11-14
(build 0.8.3). `docs/content/wiki/gpty/ipc.md`'s second-socket paragraph now names the three types
`GptyTerminal.emit_event` actually fans out - pane spawn, pane kill and concept matches, a
notify-only match included - and says `state.declared` and the `omp.*` submissions are consumed by
the GUI's drain (Reasoning pane, agent-state badge) and never queued for a subscriber, leaving the
fan-out extension to the v0.14 row **Nothing streams workspace, pane and agent state to a
consumer**. `docs/content/wiki/gpty/omp-events.md`'s Vocabulary section carries the same
clarification where the event names are listed, so a reader of either page gets one answer. Gates:
`./scripts/build-wiki --check` (bundle rebuilt, 52 notes) and `python3 scripts/docs-check`.

Commits: 84013e8, 8572362

## DOCS-15

**The v0.8.3 changelog records the remaining window and pane work** - shipped 2026-11-14 with the
release. `docs/content/docs/changelog/v0.8.3.md` is linked from `CHANGELOG.md` and covers every item
this row named: the small-window layout (cards clamp, titles ellipsize, the sidebar scrolls, floor
560x340), the foldable Workspaces/Profiles/Panes sections (persisted in `sidebar_folded`), the
resize cursor and drag band, the spawn-cost and workspace-switch work, the toast queue (every
message in turn, bounded at eight), the two scroll chevrons and the terminal's jump-to-start arrow,
the pane-configuration verbs (`new-pane --setting` / `pane-set` / `pane-settings`, one vocabulary,
user-owned keys refused, the answer reads the pane back), and the row-granular repaint - plus the
pane move, `pane-view`, the Inspector backend dropdown, the first-switch primer and the OMP channel
fix the commit range added. The blog entry `docs/content/blog/v0.8.3/index.md` carries four
captures: `v0.8.3_1.png` (fresh launch), `_2.png` (Workspaces and Profiles folded), `_3.png` (four
panes at 560x340) and `_4.png` (the terminal's two chevrons). The changelog weight ladder was
shifted one slot so the new page sorts first (v0.8.2/v0.8.1/v0.8.0 now 20/30/40; unique 10..210
across 21 pages). Gates: `python3 scripts/docs-check`, `./scripts/build-wiki --check` and
`./scripts/ci-check`.

Commits: 8dc74eb, e0d1088, 6dd2b15, 4d035b5, b823d5f, 84af2bf

## DOCS-16

**The profile docs say one built-in and still describe the pre-plugin split** - fixed 2026-11-15
(build 0.8.4). `docs/content/wiki/gpty/profile.md` now describes two shipped profiles
(`Agent Workspace`, `Knowledge Base`) in `res://profiles.default.json`, wires the Agent Workspace to
`agent-terminal`/`agent-inspector`/`agent-reasoning`, and frames it as core geometry rather than an
OMP feature ("its terminal is a plain shell, and the Inspector's default backend happens to be OMP,
the first adapter the observability panes support"). The installed-with-a-plugin paragraph lists
`godot-pty/gpty-omp`'s **OMP Workspace** beside its single-pane **OMP** launcher with its own
`omp-ws-*` ids, keeps the `godot-pty/gpty-agent-workspace` / `gpty-knowledge-base` twins and the
"does not install the OMP event extension" caveat, and its Automation section is a plain
`gpty profile save\|load\|list` block with the `profile-*` MCP tools (the "layout commands operate
on profiles" preamble is gone). `docs/content/wiki/panes/reasoning.md` names the default source
`agent-terminal`, calls the stream an agent session, and says the session id is the envelope's
`omp_session_id`; `docs/content/wiki/panes/inspector.md` no longer claims to attach to "the OMP
conversation", and its Backends table now matches the three the panel offers (`omp`, `cli`, `mock`)
with a paragraph on the `GptyAi.list_backends()` dropdown, the ` (not found)` suffix and the kept
`Custom: <value>` row. `docs/content/docs/agents/inspector-reasoning-omp.md`'s two identity rows are
generic while the `@gpty/omp-events` row and the `omp_session_id` bullet stay adapter-accurate.
`godot/knowledge.json` regenerated: `./scripts/build-wiki --check` OK (52 notes, version
`7524e18476d60592`), `python3 scripts/docs-check` OK (193 files / 580 roadmap rows). The README's
five-preset paragraph is **The README's persistence and shipped-preset paragraphs describe v0.4**,
not this row.

Commits: 6232fd3, 6cecfd6, a2bfbb3

## DOCS-17

**`pitfalls.md` is 126 flat bullets with no index by failure class** - fixed 2026-11-15 (build
0.8.4): the 126 bullets that were flat now sit under `## By defect class` and one of the 14
`### <id>` headings (the old `## Agent tool notes` section is gone; each bullet's text is
byte-for-byte unchanged and its order inside a class preserved), and the CORE fix added a 127th
input-backpressure bullet under `unbounded`. Distribution of the 126: wrong-constant 18,
silent-failure 17, missed-call-site 14, input-ownership 11, untrusted-input 10, stale-state 10, race
10, unbounded 7, platform-parity 7, one-fact-two-copies 7, lifecycle 7, gate-lies 5, doc-drift 2,
external 1. The guide's control map links each prose-only class to its heading. Verified by a sorted
bullet-line diff against the previous file (identical) and 14 headings; `python3 scripts/docs-check`
validates the anchor links.

Commits: d1ccbbb

## DOCS-18

**Two demo clips show the command line the script no longer types** - recaptured 2026-11-16 (build
0.8.4) for `showcase`, `cli-view` and `profiles` from `scripts/record-demo` on this tree. The clips
now type `gpty new-pane -t cli_view -c git --arg=status --title status --split bottom >/dev/null`
(showcase), `… -c git --arg log --arg=--oneline --arg=-5 …` and
`… -c git --arg show --arg=--stat --arg=--oneline --arg=HEAD~3 …` (cli-view), and the profiles clip
contains no `gpty layout load`. The recapture found four script defects, fixed in the same change:
(1) the seeded workspace named no directory, so the showcase's `git status` pane ran in the GUI's
own `godot/` directory and listed the developer's checkout (first pass, measured in the capture) -
the seed now writes `"cwd": <sandbox home>` and both backends start in the sandbox repo; (2) an
inherited `GPTY_SECRET` made every typed CLI call answer "GUI requires GPTY_SECRET authentication"
while the clip still encoded, so the sandbox unsets it; (3) the cli-view spawns printed their JSON
reply over the terminal, so both now end `>/dev/null` like the showcase's lines; (4) `profile load`
replaces the workspace in the same frame, so its typed line is never painted - the scenario now
opens with `gpty profile list` (`Agent Workspace`, `Knowledge Base`), which is the vocabulary on
screen, and the toast names each load. Verified frame by frame from the kept `.raw.mkv` captures:
the showcase's status pane reports the sandbox repo (`modified: src/main.rs`), the cli-view panes
show the sandbox's four commits and the `git show --stat` file list, and the profiles clip shows the
list and the `Profile 'Agent Workspace' activated` toast. Assets: `demo-showcase` 667/362/376 KB,
`demo-cli-view` 221/97/113 KB, `demo-profiles` 638/261/237 KB (gif/mp4/webm). `README.md`'s cli-view
alt now reads `git log and git show --stat`; it named `git status`, which that pane does not run.
Recorded with `DEMO_KEEP=1` into a temp dir so no `.raw.mkv`/`.cues.tsv` entered the tree.

Commits: 52efe76, a2bfbb3, 47092ee

## DOCS-19

**The v0.8.4 changelog names the genericized workspace and the OMP plugin profile** - shipped
2026-11-16 (build 0.8.4): `docs/content/docs/changelog/v0.8.4.md` is written and linked from
`CHANGELOG.md` (the weight ladder shifted one step), covering the genericized built-in (id,
description, ids, dropped `backend`), the Inspector backend dropdown and its availability hint, and
the new `OMP Workspace` plugin profile; state that saved layouts and workspaces keep their own ids
and are unaffected by the rename. Also record the profile/layout nomenclature: the sidebar's "More
profiles \u2192" entry point, the workspace-set trust dialog's wording, the plugin review's
"(geometry only)" line, and the public verbs moving from `gpty layout save\|load\|list` and the
`layout-*` tools to `gpty profile save\|load\|list` and the `profile-*` tools, with a one-line
migration note for anything that called the old spelling (no alias stays behind). Screenshot change:
`issue-v0.8.4-palette-filtered.png` and `issue-v0.8.4-settings-short-tab.png` evidence the
content-sized cards and the harness fix; the Agent Workspace geometry is unchanged, so Pane Settings
is recaptured only if the backend dropdown is shown in the existing *Pane Settings* capture, and the
backend dropdown and the OMP Workspace profile are captured as `v0.8.4_<n>.png`. Also cover the
pre-release fixes pulled forward from v0.8.6 so that release stays feature work: the no-directory
spawn fallback (a terminal and a `cli_view` now start in the user's home), the short-scheme palette
reset, the content-sized Settings and palette cards, and the capture-harness compile fix that put
pane bodies back into every capture. Also cover the launch command work: the Launch command field in
Pane Settings, the profile editor's launch lines, the line-only saved tile, and the Workspace Trust
and install-review coverage of a launch line. The Inspector backend dropdown shipped in v0.8.3 (its
page and `backend_choice.gd` are both present at the `v0.8.3` tag), so the v0.8.4 page records the
closed-set refusal that followed it rather than re-claiming the dropdown as new.

Commits: 8dc74eb, d099a9f, c6d0d8f, e333e0b, 8c58684

## DOCS-20

**The v0.8.6 changelog records the visual identity work** - shipped 2026-11-23 with the release:
`docs/content/docs/changelog/v0.8.6.md` (linked from `CHANGELOG.md`) covers the closed effect table
and its Off/Subtle/Full intensity, the transition registry and its Motion switch, reactive
environments, the orbital vault graph and its adapter-driven auto mode, window opacity and terminal
padding, colour-scheme import with the terminal's light/dark pair, the branded launch frame, the
About docs viewer and the Getting Started guide. It records the renderer bake-off's decision:
Forward+ stays the default, and Compatibility is the 2.2x-lighter opt-in (310 against 667 MB warm on
the v0.8.5 bake-off build). The blog entry `docs/content/blog/v0.8.6/index.md` uses the
`v0.8.6_1..5.png` captures, recaptured 2026-11-23 on the 0.8.6 build.

Commits: 8c58684, d3a7b05, 5451047

## DOCS-21

**`RELEASING.md` has drifted from what a release actually does** - found 2026-11-16 while cutting
v0.8.4, two instances. (1) §3 says "The site's home page carries exactly one image: the current
release's `vX.Y.Z_1.png`", but `docs/content/_index.md` carries demo clips through the `video`
shortcode and no image at all, so the sentence is unexecutable - v0.8.4 left it alone rather than
adding a screenshot the page was never built to hold. (2) §8's `git add` list omits
`docs/data/cost-history.json` and `docs/static/images/cost-history.svg`, both of which
`scripts/measure-cost --record` writes, so following it verbatim ships a README naming the new build
while the published ledger and chart still stop at the previous release. Fixed 2026-11-21: §3 now
names the blog entry as the only carrier of `vX.Y.Z_1.png` and describes the home page's demo clips
instead of claiming a screenshot; §8's staging list includes `docs/data/cost-history.json` and
`docs/static/images/cost-history.svg`. `scripts/docs-check`, `build-docs --check` and the full gate
pass.

Commits: e333e0b, 1a1b2dd

## DOCS-22

**The v0.8.7 changelog records the finish pass** - release-time: write
`docs/content/docs/changelog/v0.8.7.md`, link it from `CHANGELOG.md`, cover the single Motion
switch, the Getting Started typewriter, the chrome arrivals, the scheme backdrop, elevation for
floating surfaces, the focus sweep, the Settings rail and its previews, the effect scope and the
expanded effect table, the sidebar's expanded/icons/collapsed modes, and use the captured images.

## DOCS-23

**The v0.9.0 changelog records the instrumentation release** - release-time: write
`docs/content/docs/changelog/v0.9.0.md`, link it from `CHANGELOG.md`, cover the diagnostics pane,
the timer registry, the power-source rules, the idle render loop, the gated budget and the hot-path
scans, and capture the pane as `v0.9.0_<n>.png`.

## DOCS-24

**The v0.9.1 changelog records the rendering work** - release-time: write
`docs/content/docs/changelog/v0.9.1.md`, link it from `CHANGELOG.md`, cover the default shell, the
exit footer and restart, the drawn attributes, box/block/braille drawing, the font fallback chain
and the per-pane font fix, and capture them as `v0.9.1_<n>.png`.

## DOCS-25

**The v0.9.2 changelog records the protocol work** - release-time: write
`docs/content/docs/changelog/v0.9.2.md`, link it from `CHANGELOG.md`, cover the colour and text-area
replies, the bell, OSC 52, OSC 7, the kitty/focus/synchronized-output checks and the regression
suite, and use the `v0.9.2_<n>.png` captures.

## DOCS-26

**The v0.9.3 changelog records the security and release-integrity work** - release-time: write
`docs/content/docs/changelog/v0.9.3.md`, link it from `CHANGELOG.md`, and cover the repository
settings, the release-integrity controls that landed, the consolidated PR tooling and the
workflow-push path.

## DOCS-27

**The dependency and support policy is stated** - added 2026-11-04: CONTRIBUTING's "Dependencies"
section covers crates.io-only sources, the `deny.toml` licence allow-list and named FFmpeg
exceptions, the weekly grouped Dependabot pull requests, the `cargo audit`/`cargo deny` gates, and
the release artifacts (archives, `SHA256SUMS`, build-provenance attestations; the SBOM is tracked
separately in the v0.9.3 row "No SBOM ships with a release"). The supported-versions table already
states the latest-release and no-routine-backports policy in `SECURITY.md#supported-versions`.
`python3 scripts/docs-check` passes.

Commits: 25adc85

## DOCS-28

**The session workflow's own output is not budgeted** - the 2026-11-25 session printed the full
`commit` selection five times (`draft` plus four `only`/`take`/`drop` calls, ~1.5 KB each), and the
approved plan repeated full code sketches. Fix: `skill://commit` step 5 prescribes `silent=True` on
`draft`/`only`/`take`/`drop` and one compact `d.commit` record, with `d.show(path)` only for a file
that must be split; `docs/content/docs/agents/roadmap-workflow.md` and `skill://gpty-roadmap-task`
state the plan-handoff convention (signatures, edge cases, exact commands and acceptance, not
bodies); `scripts/pr` (row B) prints one compact line per step and JSON summaries, not full
`gh pr checks` tables. Test: `python3 scripts/docs-check` and a read of the skill/page diff.

## DOCS-29

**The input-refusal causes are copied into the wiki and drift** - the v0.8.7 CORE change made a dead
writer a second refusal cause; the handler and the gdext README were updated, but
`docs/content/wiki/gpty/control-api.md` still said only "input queue is full" until the 2026-11-25
wrap-up, and the wiki now restates both causes, so a third copy exists. Fix: the wiki
`inject`/`broadcast` rows say the input was not accepted without enumerating causes; the causes stay
in the gdext README and the handler's sentence; extend `scripts/check-ffi-surface` so the `inject`
handler's `refused("Pane ...")` literal and the `send_text` README row both contain `not reading`
and `writer`, failing on either missing token. Tests: `scripts/check-ffi-surface` passes; a temp
README copy missing one token fails naming it; `python3 scripts/docs-check`.

## DOCS-30

**The v0.9.4 changelog records the project-files and build-hygiene work** - release-time: write
`docs/content/docs/changelog/v0.9.4.md`, link it from `CHANGELOG.md`, and cover the project files,
the policies, the CI/test fixes, the release profile and dev linker, the CI cache and classifier
split, the macOS runner gating, the tooling-script smoke, the dependency-duplicate audit, the
session tooling (the stamped/narrowable local gate, the roadmap tool, the tooling help contract),
the capture-gate self-test and parallel check, the PTY writer-dead refusal and the input-refusal doc
seam.

## DOCS-31

**The v0.9.5 changelog records the ergonomics work** - release-time: write
`docs/content/docs/changelog/v0.9.5.md`, link it from `CHANGELOG.md`, and cover input, sensitive
workspaces, clipboard and links, shell integration, notifications, pane rearrangement and
keybindings, project workspaces and recent directories.

## DOCS-32

**Demo videos: one per workflow, not one hero GIF** - the README's 704 KB `demo-hero.gif` shows a
script driving panes. It proves the API and shows no reason to install: a visitor cannot see why
anyone would want panes to be drivable. Needs several short captioned videos, each one workflow end
to end (parallel agents with state badges; `pane-run` + `pane-wait` as a build loop; a concept
capturing output into an adjacent pane; the bundled wiki vault), recorded from `scripts/record-demo`
against a seeded sandbox workspace, with one OMP-specific cut for the OMP community. Closed
2026-11-06 with the decision the row was waiting on (owner, in session): seven workflows, one
scenario each, CLI-driven from a seeded sandbox, plus the OMP cut as its own PLUGIN row below.
`scripts/record-demo` is now a scenario registry
(`showcase panes agents concepts wiki media cli-view`) with a `LAYOUTS` entry, a cue arm and a size
knob per scenario; a scenario needed three fixtures the old script could not express and now
carries: a `vaults.json` root for the wiki clip (the pane settings UI is the registry's only writer,
so a restored pane cannot register one and every `vault search` answered `vault is not registered`),
`git -C "$HOME"` in the cli_view cues (a cli_view child runs in the GUI's cwd, not the workspace
directory - folded into **A pane can choose its own directory, with the workspace directory as the
fallback**), and `testsrc` instead of `testsrc2` for the media fixture (a rotating pattern defeats a
GIF palette: 2.1 MB to 1.2 MB with the same proof of playback). Layout: `demo-hero.*` is deleted;
the README shows `demo-showcase.gif` (615 KB, the only GIF it loads) and puts the six feature clips
behind `<details>` + `<summary>`, so GitHub fetches one image at page load; the homepage lost
`demo-tour` and the `hextra/feature-grid`, gained seven `###` sections that play each clip as
WebM/MP4 through the `video` shortcode, and `docs/hugo.yaml` enables goldmark `unsafe` so the README
mirror's `<details>` and badge row render instead of `<!-- raw HTML omitted -->`; `demo-tour.*`
stays in git and now plays from the v0.7.2 post. Measured on the development build: 21 files, 6.73
MiB total (showcase 615 KB GIF/338 KB MP4/319 KB WebM, features 230-1210 KB GIF), durations 11-25 s;
every clip's frames read back for legibility and no cue prints an error. Verified with `hugo`: the
homepage lists all seven `demo-*.webm` and neither `demo-hero` nor `demo-tour`; `/docs/overview/`
has six `<details>` and seven `/images/demo-*.gif` with no omitted-HTML marker; `/blog/v0.7.2/`
plays `demo-tour.webm`; `scripts/docs-check` clean and the README mirror byte-identical.

Commits: c44dcd4, 6cecfd6, f6ff07a

## DOCS-33

**A first technical post exists to point at** - SignPath's open-source signing programme is on hold
for exactly this: it wants articles or posts that establish the project, and nothing published so
far is longer than a release note. The post to write: one real workflow end to end (four agent
panes, a state badge calling for attention, that pane's status read and answered through
`paneStatus`/`pane-read`), the same actions as the CLI and MCP calls a reader can copy, what the
concept engine does and does not do (display only, it never types into a shell), and a short honest
status paragraph (side project, LLM-assisted, unsigned binaries, install path). It shows only
behaviour that exists on a tagged build - no roadmap promises - and the commands it records become
the script for the demo-video row, so both ship from one sitting. **Not drafted yet (owner,
2026-10-25):** draft it together with the recording and the seed workspace, then point SignPath at
the published URL.

## DOCS-34

**The README's persistence and shipped-preset paragraphs describe v0.4** - `godot/README.md` still
says "Layout is auto-saved on close and auto-restored on startup via `user://layout.json`" (the
store is `WorkspaceStore`'s `user://workspaces.json`, one named pane set per workspace, and
`layout.json` survives only as a one-shot legacy import), and the paragraph below it says five
ecosystem presets (herdr, lazygit, nvim, claude, OMP) "ship alongside" the built-ins, while v0.5
moved them to plugin repos - `profiles.default.json` ships only Agent Workspace and Knowledge Base.
Found 2026-10-26 while adding the profile row's new-workspace action (the bullet added there is
correct; these two paragraphs were left as they were rather than silently rewritten). The
shipped-preset half was corrected on 2026-11-12 by the profile-seeding work. Fix: rewrite the
persistence paragraph against `WorkspaceStore`, and re-read the rest of the page for the same drift.

## DOCS-35

**The v0.9.6 changelog records the distribution and reach work** - release-time: write
`docs/content/docs/changelog/v0.9.6.md`, link it from `CHANGELOG.md`, and cover the installer, GUI
discovery, the MCP bundle and listings, the plugin registry metadata, the README corrections and the
recordings and posts.

## DOCS-36

**Enterprise compliance and deployment governance guide** - write
`docs/content/docs/enterprise/governance.md` covering enterprise threat modeling, SOC2 and ISO 27001
compliance controls (audit logging, least privilege, secret isolation), Group Policy / policy.json
deployment templates, commercial dual-licensing FAQ, and air-gapped installation procedures.

## DOCS-37

**The v0.9.7 changelog records the enterprise readiness release** - release-time: write
`docs/content/docs/changelog/v0.9.7.md`, link it from `CHANGELOG.md`, and cover the commercial
license terms, immutable audit logging, administrative guardrails, headless token authentication,
and air-gapped packaging.

## DOCS-38

**The v0.10.0 changelog records the daemon extraction** - release-time: write
`docs/content/docs/changelog/v0.10.0.md`, link it from `CHANGELOG.md`, and cover the extraction, the
grid wire protocol and attach/reattach.

## DOCS-39

**The v0.10.1 changelog records the permission and validation work** - release-time: write
`docs/content/docs/changelog/v0.10.1.md`, link it from `CHANGELOG.md`, and cover the caller
permission and the Rust-side validation.

## DOCS-40

**The v0.11.0 changelog records the game host and Snake** - release-time: write
`docs/content/docs/changelog/v0.11.0.md`, link it from `CHANGELOG.md`, and cover the pane type, the
host contract, Snake, focus and pause, and high scores.

## DOCS-41

**Docs, soak and a release gate** - A docs page for the game pane (games, keys, settings, control
surface), the host contract recorded in AGENTS.md, and a 10-minute headless soak per game with flat
memory and no frame stalls recorded here, with GUT coverage for all of the above in the gate.

## DOCS-42

**The v0.11.1 changelog records the games and release gate** - release-time: write
`docs/content/docs/changelog/v0.11.1.md`, link it from `CHANGELOG.md`, and cover Minesweeper,
falling blocks, the picker and settings, the attention pause, the control surface, the trust
boundary and the soak.

## DOCS-43

**Capability catalogue: AGENT** - record the agent surface the way TERM, IPC, GUI and WIKI are
recorded: the event socket's vocabulary and its capability scoping
(`crates/gpty-gdext/src/omp_events.rs`), the four badge silhouettes and what each is derived from
(`godot/scenes/ui/agent_badge.gd`), capture routing (`crates/gpty-core/src/concept.rs`,
`crates/gpty-gdext/src/capture_api.rs`), the private Inspector bridge
(`crates/gpty-gdext/src/ai.rs`, `godot/scenes/panes/inspector_pane.gd`) and the Reasoning
projection. Schema, statuses and gate are in `docs/content/docs/agents/testing.md`; acceptance is
`./scripts/check-capabilities` green with the new area.

## DOCS-44

**Capability catalogue: CONCEPT** - the concept engine is the one place gPTY acts on program output,
and no record states its contract: trigger matching and capture routing as pure functions
(`crates/gpty-core/src/concept.rs`), the capture state machine and its modes
(`crates/gpty-core/src/engine.rs`), the default concept set (`godot/concepts.default.json`), the
routing that decides which pane receives a capture (`godot/scenes/terminal/concept_router.gd`) and
the `gpty_state` OSC as the declaration path (`crates/gpty-core/src/parser.rs`).

## DOCS-45

**Two shipped GUI capabilities are still recorded as planned** - found 2026-11-21 while adding the
effects record: `docs/data/capabilities/GUI.json` says `gui.chrome.opacity` is planned ("neither
setting exists") and `gui.scheme.import` is planned ("only three schemes ship and no importer
exists"), while both owning rows closed in v0.8.6 (**Window fit: opacity and inner padding**,
**Colour schemes: import, and light mode that follows the system**). `scripts/check-capabilities`
validates shape, ids and evidence but never compares a record's `status` with its `row`'s ✅/⬜ mark,
so a closed row leaves a stale claim that the docs page and every catalogue reader repeat. Fix:
correct both records (status done, mechanism and evidence current), and teach `check-capabilities`
to fail a `planned` record whose roadmap row is ✅ (or a `done` record whose row is ⬜) by parsing the
roadmap pages it already joins against; then re-check the other three areas for the same drift.

## DOCS-46

**Capability catalogue: MEDIA** - the media backend's properties are its allowlists and its bounds,
not its features: the path gate and component allowlists (`crates/gpty-media/src/lib.rs`), stream
selection and demuxer aliases (`probe.rs`), the decode thread's bounded queues and seek epochs
(`session.rs`), the packed RGBA/PCM wire (`crates/gpty-gdext/src/media_api.rs`) and what the pane
refuses (`godot/scenes/panes/media_files.gd`). Several of these are security properties, so the
record is the place a regression would show up as a missing capability rather than a silent
widening.

## DOCS-47

**Capability catalogue: CLI** - the command surface is a published contract (27 MCP tools, a skill
printed by `gpty --skill`) with no inventory behind it: argv-only spawn and the stale-binary check
(`crates/gpty-cli/src/main.rs`), the argument translation and its refusals (`commands/wire.rs`), the
tool-name gate (`commands/schema.rs`), daemon start/stop/status, plugin verbs and the layout verbs.

## DOCS-48

**Capability catalogue: PLUGIN** - record what a plugin may and may not do: manifest validation and
its caps (`godot/scenes/terminal/plugin_review_text.gd` and the shipped validator), the
clone-review-consent handshake and the trust store (`godot/scenes/autoloads/trusted_store.gd`), the
registry index and its policies (`godot/assets/registry.json`), and the per-plugin config/state/log
directories. The record is the audit surface for the next `plugins.md` change.

## DOCS-49

**Capability catalogue: SEC** - the trust boundaries are currently described in prose in
`SECURITY.md` and `docs/content/docs/agents/security.md`, so a control can be weakened without a
record noticing: workspace trust, the plugin review, the vault root registry, the OSC 52 write
policy, owner-only store files (`crates/gpty-core/src/owner_only.rs`) and the log-hygiene rule. Each
becomes a record whose `mechanism` names the enforcement point and whose `evidence` is the code, so
deleting the enforcement breaks the gate rather than the documentation's accuracy.

## DOCS-50

**Capability catalogue: CORE** - the engine's own contract: PTY spawn and validation
(`crates/gpty-core/src/pty.rs`), the vte-to-grid feed and damage tracking (`term.rs`), capture modes
and the capture state machine (`engine.rs`), scrollback store plumbing and damaged-file recovery
(`store.rs`, `history.rs`), and the keymap. This is the area where a `partial` record is a fidelity
bug with a name.

## DOCS-51

**The agent-state page describes one declaration channel where there are now two** - `docs/content/wiki/gpty/agent-state.md`
lists Tier 2 as the private `gpty_state` OSC only and `docs/content/wiki/gpty/ipc.md`'s `paneStatus`
paragraph names the old nine fields, so a program author reading the wiki cannot discover the
generic channel and an API consumer cannot find `program_status`. Fix: the wiki gains the OSC 7501
Tier 2 channel (states, `kind`, `progress`, records and ids, lifetimes, projection and the
attention-first display rule, why the pty is the generic path and why it is still spoofable), the
`paneStatus` field list and the `get_program_status` display cap, and
`docs/content/docs/agents/security.md:41` plus the `parser.rs` comment name the reviewed second OSC
and its no-writeback/no-log rule; `AGENTS.md`'s data-flow block gains the line from a pane program's
OSC 7501 to the badge and sidebar. Acceptance: `./scripts/docs-check` and
`python3 scripts/build-wiki --check`.

## DOCS-52

**Docs** - agent guide, plugin authoring guide, socket API reference (from the existing schema
generator), 60-second quick start.
