# Contributing

gPTY is a Rust engine behind a Godot frontend. Contributing means cloning the repo, building the GDExtension, running the same checks CI runs, and landing a change through a hook-enforced commit format. This note is the short path; the authoritative rules live in `AGENTS.md` and `docs/content/docs/agents/`.

## Repository layout

The split follows the process boundary: everything that touches a PTY, a grid, or a parser is Rust; everything that draws is GDScript.

| Path | What lives there |
|---|---|
| `crates/gpty-core` | PTY spawn, ANSI/vte parsing, terminal grid, concepts, history, vault index |
| `crates/gpty-ipc` | JSON-RPC protocol, socket transport, client, server |
| `crates/gpty-gdext` | The Godot extension: FFI surface, IPC bridge, event socket, vault API |
| `crates/gpty-cli` | The `gpty` binary: workspace control, MCP server, plugin tooling |
| `crates/gpty-ai` | Inspector backends (no tools) |
| `crates/gpty-media` | Pinned FFmpeg media backend |
| `godot/` | Scenes, GDScript, the tiling workspace (`workspace.gd`), pane bodies |
| `extensions/` | First-party agent extensions (the OMP events forwarder) |
| `docs/content/docs/` | Agent guides, release notes, roadmap pages |
| `docs/content/wiki/` | This wiki vault |
| `scripts/` | Build, CI, hook, and media-dependency scripts |

The entry point is `godot/scenes/main.tscn` → `workspace.gd`, a root `Control` node. Rust code never touches a node; GDScript never touches a PTY directly. [[architecture|Architecture]] explains the seam.

## Build and run

Prerequisites are Rust 1.85 or newer (edition 2024) and Godot 4.7 with GDExtension support.

```bash
./scripts/media-deps                 # builds the pinned FFmpeg, once per checkout
source dist/ffmpeg/<platform>-<arch>/env.sh

cargo build -p gpty-gdext
cd godot && godot -e                 # open the editor
```

After a rebuild, restart the editor so it remaps the extension library. To launch the app directly:

```bash
godot --path godot
godot --path godot --headless
```

A one-shot standalone build is the script's job — it detects the host, builds release, stages the binary, exports into `dist/`, and bundles the media runtime:

```bash
./scripts/build
```

That requires export templates matching the editor version exactly; a 4.7.2 editor needs 4.7.2 templates, and a symlinked older directory silently exports with the wrong engine.

For day-to-day control of a running GUI, build the CLI and use it — it is the fastest way to see whether a bridge change works:

```bash
cargo run --bin gpty -- version
cargo run --bin gpty -- new-pane --pane-type terminal
cargo run --bin gpty -- list-panes
```

If a `cargo install`ed `gpty` shadows the checkout, reinstall it after a version bump; a stale binary fails opaquely in clap before any IPC.

## Tests and gates

One script is the contract:

```bash
./scripts/ci-check          # fmt, workflow lint, clippy, Rust tests, GUT, audit
./scripts/ci-check --fast   # fmt, workflow lint, clippy only
```

Narrower loops while iterating:

```bash
cargo test --workspace
cargo test -p gpty-core
cargo check
./scripts/gut-check                 # GDScript tests; fails if the run aborted
./scripts/lint-workflows            # workflow YAML + permissions block
(cd extensions/gpty-omp-events && node --test)
```

Two details worth knowing. GUT exits 0 even when a run aborts, which is why `scripts/gut-check` exists and why it is the command to trust. And `godot --headless --path godot --import` must run once before the first headless test, or the project has no imported resources and every scene load fails.

Two more that cost real CI runs. A test that writes an executable and then spawns it can see `ETXTBSY` while another test thread forks holding a dup of the write descriptor: retry that one error inside the test, bounded, and leave the product reporting it. And an escape-string assertion cannot be made end to end on Windows - the console host buffers an unterminated string before gPTY sees it ([[conpty]]) - so the guard's coverage lives in `escstring` unit tests and the live smoke skips that arm on that platform.

Tests are written `Given / When / Then` with expected output stated. Behaviour changes come with a test that would fail without them; a fix that only moves a symptom is not done.

## Hooks

Install the repository's git hooks once per clone:

```bash
./scripts/install-hooks
```

| Hook | Runs |
|---|---|
| `pre-commit` | Formatting, workflow lint, clippy |
| `commit-msg` | Conventional Commits check |
| `pre-push` | The full CI suite |

The hooks are symlinks into `githooks/`, so they update with the repo. Running `./scripts/ci-check` by hand before committing is equivalent and faster to iterate on.

## Commits

Format is Conventional Commits: `type(scope): summary`. Types follow the usual set (`feat`, `fix`, `chore`, `docs`, `test`, `refactor`, `ci`), and the scope names the area you touched:

| Scope | Area |
|---|---|
| `core` | `gpty-core` engine |
| `ipc` | Protocol, sockets, transport |
| `gdext` | The Godot extension and FFI |
| `cli` | The `gpty` binary and plugin tooling |
| `settings`, `terminal`, `layout`, `workspace`, `sidebar`, `ui` | GDScript frontend areas |
| `profiles`, `concepts`, `icons` | Feature verticals |
| `ai`, `inspector` | Inspector and reasoning backends |
| `ci` | Workflows, scripts, hooks |

One commit per coherent change. If a diff spans a refactor and a behaviour change, split it: the reviewer and `git bisect` both benefit.

## Where documentation goes

Three separate places, with different jobs:

| Location | Purpose |
|---|---|
| `docs/content/docs/agents/` | Developer guides: Rust, GDScript, security, testing, pitfalls, plugin manifest |
| `docs/content/docs/roadmap/` and `ROADMAP.md` | One page per release chain; the root file links them |
| `docs/content/docs/changelog/` | One page per release; `CHANGELOG.md` links them |
| `docs/content/wiki/` | This vault — durable explanation for a reader |

A behaviour change updates the page that describes it. A new feature that a user can reach gets a release-changelog entry; a new capability an agent can call updates the skill text under `skills/` and the schema it prints.

The wiki vault is source, not generated: after editing a note under `docs/content/wiki/`, run `./scripts/build-wiki` to refresh `godot/knowledge.json`. The CI gate fails when the bundle is stale, and release builds use the committed bundle.

## Your first change

Read `AGENTS.md` first, then the guide for the layer you are touching — `security.md` before anything near IPC, PTYs, plugins, or the filesystem. Build the extension, open the editor, install hooks. Make the smallest change that demonstrates the behaviour, run `./scripts/ci-check --fast` while iterating and the full `./scripts/ci-check` before pushing, write a Conventional Commit, and open the PR. If the change has a security dimension, the [[security-model|Security Model]] lists the threat boundaries it must not weaken.

## Related

[[gpty]] · [[architecture]] · [[security-model]] · [[ipc]]
