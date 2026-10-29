# Security Policy

This document states what the project defends against, what it deliberately does not, 
and how to report a problem.

Implementation rules for contributors live in [the security rules](docs/content/docs/agents/security.md). This file is the
policy: the (currently limited) threat model, the limits, and the reporting process.

## Supported versions

| Version | Support |
| ------- | --------- |
| > 0.5   | :white_check_mark: Security and correctness fixes |
| < 0.5   | :x: |

Generally, fixes will land on `main` and ship in the immediate next release. There is no plan to 
have maintenance branches and/or backports to older minor versions - if a fix matters to you, 
please upgrade.

That said, if there is an issue with a significant severity and implications, the fix will be 
backported to prior releases as feasible.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting**: repository **Security** tab → **Report a
vulnerability**. It opens a private advisory thread visible only to the maintainers. Please do not
open a public issue, pull request, or discussion for a suspected vulnerability - that exposes every
user before a fix exists.

If private reporting is unavailable to you, open an issue titled `Security Request` with
**no technical details** and a maintainer will establish a private channel. In this channel,
be prepared to privately share:

- The affected version(s), commit(s), and platform(s);
- What an attacker could potentially control (a file the user opens, a program running inside a pane, 
 a remote response, another local user, etc.);
- A minimal set of reproduction steps, and the impact you believe it has.

### What to expect

This is a single-maintainer project, so these are best-effort targets, definitely not a contract or 
a guarantee:

| Stage | Target |
| ----- | ------ |
| Acknowledgement of the report | ~7 days |
| First assessment (in scope / not, severity, planned fix) | ~30 days |
| Fix for confirmed issues | On the immediate next release |
| Public disclosure | A GitHub security advisory published with the fix |

We credit reporters in the advisory unless you prefer otherwise. If a reported behaviour turns out
to be intentional and documented, we will explain the reasoning in the thread and record it here.

## Threat model

**Trusted: Your own user account.** `gPTY` trusts same-UID processes by design. A process running as
**you** can already read your files, attach to your terminals, and drive the control socket, so "another
program running as me can control the workspace" shouldn't be a vulnerability on its own (please open a 
discussion post if you think otherwise). Setting `GPTY_SECRET` raises the bar for *other users* of the
machine, and on Linux and Windows it also keeps the secret out of reach of code running in your
panes: the GUI and the CLI harden themselves at startup (a non-dumpable process on Linux, a process
DACL without memory access on Windows), so a pane program cannot read `GPTY_SECRET` from their
environment and therefore cannot authenticate to the control socket. That is a credential barrier, not
pane isolation, and it only exists when a secret is set (the default install sets none). The trust
above is for processes *outside* gPTY; code running *inside* a pane is not separated from the control
surface by a permission model yet, which is a known, tracked gap (see "A program in a pane can read and
drive every other pane" under Known limitations).

**Untrusted - must never gain authority:**

- **Terminal output.** Every byte a program prints, including escape sequences, is attacker-controlled
  if any program you run can be induced to print attacker-chosen text.
- **Files.** Saved layouts, profiles, workspaces, concept definitions, markdown, scrollback: files
  can arrive from a repository, a chat message, or a shared dotfiles setup. A file cannot turn that
  into code by naming a resource: pane settings go through a closed per-type allowlist
  (`PaneTypes.settings_schema`), and a data-supplied font path is read as bytes by `TerminalFonts`,
  never through `load()` - a `.tres` with an embedded script runs during `load()`, and Workspace
  Trust does not examine a font.
- **Remote responses.** Release metadata, documentation, anything fetched over the network.
- **Other users** on a shared machine, and any file or socket they could have written.

**In scope:**

- All untrusted data reaching a privileged action: Executing a process, writing a file outside the
  app's own `user://` store, gaining the control socket, or delivering input to a pane the user did
  not target;
- Cross-user attacks on shared hosts: socket squatting, world-writable paths, `PATH`/env manipulation;
- remote content driving a local action;
- A lower-trust pane influencing a higher-trust one (an ordinary shell pane feeding a root shell or
  an SSH session). This is in scope as a goal and has **no per-pane permission model yet**: with the
  default install (no `GPTY_SECRET`) a program in any pane can drive every other pane. Setting a
  secret closes the environment path that used to leak it on Linux and Windows (see Hardening in
  place), so the socket gate becomes real for pane programs - but that is a credential, not a
  boundary, and it is a documented known limitation rather than an unreported bug. Enforcement is on
  the roadmap (see Known limitations);
- Denial of service that locks the GUI thread or grows memory without a bound.

**Out of scope (by design, or accepted):**

- Processes *outside* gPTY that run as the same user controlling it (see above). A process *inside* a
  pane is the in-scope case listed earlier, not this one;
- Spoofable display state: the `gpty_state=<value>` OSC declaration and the heuristic agent-state
  tiers may be set by anything that can print; they are labelled display-only and are never an input
  to a decision. `gpty state` declares the same (display-only) state over the event socket, where the
  per-PTY event capability a pane injects into its children is the gate rather than the output
  stream; it is the declaration path on Windows, where ConPTY consumes the OSC before gpty sees it;
- What happens after a user approves a **Workspace Trust** prompt, activates a downloaded profile,
  or installs a third-party extension. Those prompts exist so the decision is explicit; after
  consent, gPTY runs what the file asks for;
- Unsigned release artifacts and the absence of code signing (see Known limitations);
- Third-party CLIs, editors, agents, and plugins the user runs inside a pane, and the files they
  write;
- A user pasting content into a shell, or running a command they typed.

## What gPTY deliberately does not do

- **No sandboxing.** A pane is a shell running as you, with your permissions. gPTY never claims
  otherwise.
- **No OSC 52 clipboard access.** Terminal escape sequences cannot read or write your clipboard;
  `parser.rs` interprets exactly one OSC sequence (`gpty_state=`) and it changes a badge.
- **No command execution from concept definitions.** A concept is data: a regex trigger, a stop
  condition, and a routing target. It can capture terminal output and hand it to a pane that
  displays it. It cannot write to a PTY. (This capability existed in earlier builds; see
  [CHANGELOG.md](CHANGELOG.md).)
- **No scraping of agent TUIs.** Pane output is presentation, not a structured event source.
  Observability comes only from documented hooks (the OMP event extension) and the control API.
- **No shell evaluation of configured "commands".** A saved tile or profile names a program and an
  argv array; there is no shell string anywhere in the spawn path. A saved file cannot supply
  environment at all: a tile's `shell_env` is dropped on restore with a notice, and the environment
  a pane gets - the inherited one plus your own global and per-pane settings - passes through one
  blocklist before it reaches a child.

## Hardening in place

These are load-bearing guards. Reports that require removing one of them should say so explicitly.

- **Control socket**: per-user path, `0600`, cross-UID peers rejected (fail-closed on Linux and
  macOS), 64 KiB request cap, 16 concurrent connections, optional shared secret compared in constant
  time; clients validate the socket path and the GUI binary before trusting either.
- **Event socket**: separate listener; *submitting* an event requires a per-PTY capability that is
  never reused and is compared in constant time. Reading the fan-out is open to same-UID processes -
  treat the event channel as non-confidential from your own user.
- **Child processes**: `LD_*`/`DYLD_*`, event-channel, pane-marker, and control-credential variables
  are stripped from every child, and startup-evaluation variables (`PROMPT_COMMAND`, `BASH_ENV`,
  `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`,
  `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `PAGER`) are refused from
  configuration. Absolute programs restored from files must not be group/other-writable and must be
  owned by you or root.
- **The GUI's and the CLI's own environment**: both harden themselves at startup
  (`gpty_core::hardening::harden_process`, called from the GDExtension's init and the CLI's `main`).
  A pane's shell is a child of the GUI and runs as you, so without this it can recover `GPTY_SECRET`
  from the parent's environment. On Linux the call clears the dumpable bit (`PR_SET_DUMPABLE 0`), so
  `/proc/<gui pid>/environ` and `/proc/<gui pid>/maps` are root-owned and a pane program gets
  `EACCES` (measured 2026-10-29), while the pane's own `exec`ed shell - and the programs it starts -
  returns to dumpable and stays debuggable. On Windows it installs a process DACL that withholds
  `PROCESS_VM_READ`, `PROCESS_VM_WRITE`, `PROCESS_VM_OPERATION` and `PROCESS_CREATE_THREAD` from the
  user (the rights a memory read or code injection needs) while keeping
  `PROCESS_QUERY_LIMITED_INFORMATION` (the socket's peer check opens a client with it),
  `PROCESS_TERMINATE` (a hung GUI stays endable), `SYNCHRONIZE` and `READ_CONTROL`, in one ACE for
  the process owner. There is no blanket `SYSTEM` ACE: `SYSTEM` holds `SeDebugPrivilege`, and a full
  grant would re-grant everything whenever gPTY itself runs as `SYSTEM` (the owner then matches it).
  A process that *enables* `SeDebugPrivilege` can open any process regardless of its DACL - that is
  an elevated debugger, not a normal pane, and the Windows test and smoke drop the privilege before
  probing. The cost is deliberate: a non-dumpable process on Linux produces no core dump and
  cannot be attached to by a same-user debugger or profiler, and a hardened Windows process cannot
  be opened for memory reads by the same user, so `GPTY_ALLOW_DEBUG=1` opts out for a developer who
  needs one. The Windows DACL is compile-verified; a dedicated Windows integration test asserts the
  split on its own process (the default DACL grants memory access, the hardened one refuses it, the
  installed DACL read back has one owner ACE without memory rights, and the peer-check and terminate
  masks still open), and the smoke's `process hardening` step asserts it for the GUI and a client on
  a real Windows run. macOS has no mechanism wired up; see Known
  limitations.
- **Restored layouts and profiles**: tile types, settings, and grid geometry are validated; a tile
  that starts a different program or passes extra arguments raises the Workspace Trust prompt before
  it runs, and `layoutLoad` over the control socket refuses such a profile (a caller cannot answer a
  dialog, so naming the profile is not consent to what the file asks for) - unless the consent memory
  covers it: a built-in profile approved at this app version, or a profile whose every untrusted
  tile's exact program+argv was approved, loads, because the record is proof the user approved that
  content in the GUI. A new app version or plugin revision re-prompts by construction. Environment is
  not a file decision: a tile's `shell_env` is dropped on restore with a notice naming what was
  dropped, and per-pane environment is the user's own - `user://pane_env.json`, written only by the
  pane settings UI and keyed by the pane's id, applied at spawn over the user's global environment.
- **Concepts**: the standard Rust `regex` crate only (no backtracking engine), bounded counts and
  lengths, a 16 KiB line cap before matching, 4 MiB capture buffers, and a 64 KiB OSC cap in the
  parser.
- **Markdown**: rendered from Markdown to escaped BBCode - never raw HTML or unescaped tags; links
  are scheme-checked and opened only after an explicit confirmation.

- **Media decoding**: the media backend links a pinned FFmpeg (LGPLv3, dynamically linked) built
  with `--disable-everything --disable-network`, so only the containers and codecs in
  `crates/gpty-media/components.txt` exist in the shipped libraries. A media path must be an absolute
  local **regular file** (a FIFO or device is refused before FFmpeg sees it), the demuxer's alias
  list is checked after opening, and the selected stream's codec id is checked against the same
  list before a decoder runs. Caps: 16 streams, 4096 px per side, 34 MiB per decoded frame, 8 audio
  channels, bounded queues and a 10 s open/probe budget. Decode runs on its own thread; no hardware
  decoder and no network protocol is compiled in.

## Known limitations

Each is either accepted for the current scope or tracked as a roadmap item.

- **Media decoding is in-process C code.** FFmpeg is a large memory-unsafe decoder stack and is a
  deliberate exception to the memory-safety preference the rest of the untrusted-input path follows.
  The minimal build and the allowlists reduce the surface; they are not a sandbox. A decoder bug
  would be a same-process memory-safety bug, and media files should be treated as untrusted input.
- **Peer verification by platform.** The control socket checks that the connecting process runs as
  the same user, and fails closed on a lookup error, on Linux and Android (`SO_PEERCRED`), macOS and
  the BSDs (`getpeereid`), illumos and Solaris (`getpeerucred`), and Windows (the client process id
  the pipe reports, then its token's user SID compared with gPTY's own). Windows named pipes also
  reject remote clients and carry a default ACL for the creating user, SYSTEM and Administrators,
  but that ACL is inherited rather than verified - the explicit check is what makes it a gate.
  Remaining Unix targets (AIX, Haiku, QNX) have no peer-credential API wired up and still fail
  *open*, so file permissions are the only gate there. Windows environment keys are
  case-insensitive (and the PTY layer normalises them), so the `GPTY_*` credential and marker
  namespace is not case-sensitive there. On Windows the check is compile-verified locally and
  exercised by the `windows-smoke` CI job (a same-user client must be accepted); the rejection case
  needs a second user account and is not covered.
- **Shared-`/tmp` fallback.** The control socket's directory is chosen in order: `$XDG_RUNTIME_DIR`,
  `/run/user/<uid>` (Linux) or `$TMPDIR` (macOS), then a private state directory of your own
  (`$XDG_STATE_HOME/gpty` or `$HOME/.local/state/gpty`, created 0700), and only then
  `/tmp/gpty-<uid>.sock`. That last path is predictable in a world-writable directory: socket
  ownership and mode are validated before use, so nobody can read or spoof traffic, but another user
  can pre-create the path and deny service. It is reached only when no private directory exists or
  can be created.
- **A program in a pane can read and drive every other pane.** Every pane's shell is a child of the
  GUI and runs as you, so it passes the control socket's one gate (same user). The PTY layer strips
  `GPTY_SOCKET` and `GPTY_SECRET` from a pane's environment, but the default socket path is derived
  from `XDG_RUNTIME_DIR`, which is inherited, so the `gpty` CLI inside a pane finds the socket anyway.
  The secret closes that path on Linux and Windows: the GUI and the CLI harden themselves at
  startup, so on Linux a pane program's read of `/proc/<pid>/environ` fails with `EACCES` (measured
  2026-10-29; see Hardening in place), and on Windows the process DACL refuses the `PROCESS_VM_READ`
  a memory read needs, so with a secret set on the GUI the program cannot authenticate and is
  refused. That barrier is narrow: the default install sets no secret; on macOS the environment is
  readable by same-user processes through `KERN_PROCARGS2` (`ps -E`, `pgrep`); on both Linux and
  Windows the marking lands a moment after `exec`, so a process polling the platform's access check
  while a client starts can still catch that client's secret (the GUI outlives that window, and its
  panes do not exist while it opens); and an rc file that exports `GPTY_SECRET` puts it back into
  every pane's own shell, because
  the PTY strip happens before that shell starts. The reach is the whole control surface - `inject`, `pane-run`,
  `broadcast`, `new-pane`, `kill-pane` and `pane-read` - so another pane's input *and* its output. Any
  process that can run in a pane (an install script, a `curl | sh`, a compromised dependency, an agent
  following an injected prompt) can type into your other panes, including a root shell or an SSH
  session, and read what they print. gPTY does not separate panes from each other and makes no such
  claim today. Workspaces do not help: all of a window's workspaces share one control socket, and
  every pane in every workspace is addressable by its id, which is matched across all of them. A
  label that two workspaces share (`T1`) is refused with an error naming every candidate rather than
  guessed from the active workspace, so an accidentally misdirected command fails loudly - that is a
  correctness rule, not a boundary, since any process can read `list-panes`' ids or guess them.
  Until enforcement lands, keep untrusted code and root shells or authenticated sessions apart by
  running one of them outside gPTY: without a secret set, the control surface is open to every program
  you run. A secret is not the fix either - it locks out the agents running in panes. The control
  surface is the intended agent workflow (an agent in a pane calling `gpty inject` or `gpty mcp`), so
  the planned fix is a per-pane permission the user grants, not removing the surface.
  Even then it will be a speed bump against opportunistic scripts and injected agents, not a boundary
  against a determined local attacker. Real isolation from code you do not trust has to come from the
  operating system - run it as another user, in a container or VM, or under a sandbox such as
  bubblewrap, away from the terminal that holds your root and SSH sessions. gPTY may one day offer an
  opt-in isolated pane (a shell started where the control socket is not visible); that is an idea, not
  a plan or a promise, and it would not change the "No sandboxing" statement above until it exists.
  A *sensitive workspace* flag is planned (see the roadmap) with one fixed rule: the panes of a workspace
  the user marks sensitive are not reachable over the control socket by any client - pane or outside, with
  no exception - and are not written to the history store. It is not implemented yet, so today no
  workspace has this property.
  Tracked in [ROADMAP.md](ROADMAP.md).
- **A pane inherits your environment.** The PTY layer snapshots the GUI process's environment and
  strips only the `GPTY_*` keys, so everything else reaches every pane: `SSH_AUTH_SOCK`, cloud
  credential pointers, proxy variables, `DISPLAY`. Launch gPTY from a shell that holds credentials
  you would not hand to a pane (or from inside a pane, or over SSH) and those panes inherit them.
  The same applies to the GUI the CLI auto-spawns: it is a child of the CLI and inherits *its*
  environment, so a `gpty` run from a credential-holding shell hands that context to every pane
  opened afterwards. On top of that inherited environment a pane gets your global `shell_env`
  overlaid by the pane's own entry from the user-owned `pane_env.json` store; saved files cannot
  supply environment. This is the user's own context, not a file's - but it bounds what any
  per-pane environment model can claim, and it is why environment is treated as authority rather
  than configuration.
- **Scrollback is plaintext** in `user://`. The store, its WAL siblings and the JSON stores beside
  it are created owner-only (0600) rather than with your umask, but the content is not encrypted:
  anything printed in a pane - tokens included - is stored on disk the same way a shell history file
  would be.
- **The update check is notify-only.** It fetches release metadata over TLS and shows a toast; it
  never downloads or executes anything, and the response is treated as display data.
- **Release artifacts are not code-signed, but carry build provenance.** There is no Authenticode or
  notarization. Each release publishes a `SHA256SUMS` listing every asset, and every asset is attested
  with GitHub's build-provenance attestation (SLSA v1), signed by the release workflow's OIDC identity -
  verify with `gh attestation verify <asset> --repo godot-pty/gpty`. That binds a download to the
  workflow, commit and runner that produced it; checksums without the attestation only catch corruption
  in transit. Verify the source or build locally if provenance is not enough for you.
- **Resource bounds are per-path, not global.** A program that floods a pane can still make that
  pane expensive: the output queue is bounded per pane (256 × 4 KiB, enforced by blocking the
  reader, so the child waits on the PTY buffer rather than the process growing - v0.5.4), and the
  render loop repaints less often when a pane's own grid work exceeds its per-frame budget instead
  of spending every frame on it (v0.5.3), and scrollback is committed by a per-pane writer thread
  whose pending queue is bounded by the store's retention window (v0.5.4) instead of one blocking
  insert per line under the grid lock. Concept matching still costs lines × enabled concepts per
  burst, which remains an open DoS item in [ROADMAP.md](ROADMAP.md).
- **Parallel test runs are wall-clock sensitive.** The Inspector backend tests spawn real child
  processes and wait on them; the budgets are generous enough for a loaded parallel CI run, but a
  machine that is oversubscribed far beyond CI's shape can still time a turn out.

## Safe harbor

We will not pursue or support legal action against researcher(s) who, in good faith:

- Test against their own installation and their own data;
- Avoid accessing, modifying, or exfiltrating data that is not theirs;
- Report a discovered issue privately and give us a reasonable window to fix it before disclosing;
- Do not degrade the service for anyone else.

Security research that follows this policy is welcome. Please contribute via Issues and Discussions.
