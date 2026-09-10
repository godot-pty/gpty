# Security Policy

gPTY is a local terminal workspace: it spawns PTY-backed shells, draws their grids, and exposes a
local control socket so CLI tools, agents, and scripts can drive panes. This document states what
the project defends against, what it deliberately does not, and how to report a problem.

Implementation rules for contributors live in [AGENTS.md](AGENTS.md#security). This file is the
policy: the threat model, the limits, and the reporting process.

## Supported versions

| Version | Supported |
| ------- | --------- |
| 0.5.x   | :white_check_mark: security and correctness fixes |
| < 0.5   | :x: |

Pre-1.0: fixes land on `main` and ship in the next release. There are no maintenance branches and
no backports to older minor versions — if a fix matters to you, upgrade.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting**: repository **Security** tab → **Report a
vulnerability**. It opens a private advisory thread visible only to the maintainers. Please do not
open a public issue, pull request, or discussion for a suspected vulnerability — that exposes every
user before a fix exists.

If private reporting is unavailable to you, open an issue titled `security contact request` with
**no technical details** and a maintainer will establish a private channel.

Please include:

- affected version, commit, and platform;
- what an attacker controls (a file the user opens, a program running inside a pane, a remote
  response, another local user, …);
- a minimal reproduction, and the impact you believe it has.

### What to expect

This is a single-maintainer project, so these are best-effort targets, not a contract:

| Stage | Target |
| ----- | ------ |
| Acknowledgement of the report | ~7 days |
| First assessment (in scope / not, severity, planned fix) | ~14 days |
| Fix for confirmed issues | next scheduled release |
| Public disclosure | a GitHub security advisory published with the fix |

We credit reporters in the advisory unless you prefer otherwise. If a reported behaviour turns out
to be intentional and documented, we will explain the reasoning in the thread and record it here.

## Threat model

**Trusted: your own user account.** gPTY trusts same-UID processes by design. A process running as
you can already read your files, attach to your terminals, and drive the control socket, so "another
program running as me can control the workspace" is not a vulnerability on its own. Setting
`GPTY_SECRET` raises the bar for the control socket; it does not change the trust class.

**Untrusted — must never gain authority:**

- **Terminal output.** Every byte a program prints, including escape sequences, is attacker-controlled
  if any program you run can be induced to print attacker-chosen text.
- **Files.** Saved layouts, profiles, workspaces, concept definitions, markdown, scrollback: files
  can arrive from a repository, a chat message, or a shared dotfiles setup.
- **Remote responses.** Release metadata, documentation, anything fetched over the network.
- **Other users** on a shared machine, and any file or socket they could have written.

**In scope:**

- untrusted data reaching a privileged action: executing a process, writing a file outside the
  app's own `user://` store, gaining the control socket, or delivering input to a pane the user did
  not target;
- cross-user attacks on shared hosts: socket squatting, world-writable paths, `PATH`/env manipulation;
- remote content driving a local action;
- a lower-trust pane influencing a higher-trust one (an ordinary shell pane feeding a root shell or
  an SSH session);
- denial of service that locks the GUI thread or grows memory without a bound.

**Out of scope (by design, or accepted):**

- same-UID processes controlling gPTY (see above);
- spoofable display state: the `gpty_state=<value>` OSC declaration and the heuristic agent-state
  tiers may be set by anything that can print; they are labelled display-only and are never an input
  to a decision;
- what happens after a user approves a **Workspace Trust** prompt, activates a downloaded profile,
  or installs a third-party extension. Those prompts exist so the decision is explicit; after
  consent, gPTY runs what the file asks for;
- unsigned release artifacts and the absence of code signing (see Known limitations);
- third-party CLIs, editors, agents, and plugins the user runs inside a pane, and the files they
  write;
- a user pasting content into a shell, or running a command they typed.

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
  argv array; there is no shell string anywhere in the spawn path. Restored environments pass
  through one blocklist before they reach a child.

## Hardening in place

These are load-bearing guards. Reports that require removing one of them should say so explicitly.

- **Control socket**: per-user path, `0600`, cross-UID peers rejected (fail-closed on Linux and
  macOS), 64 KiB request cap, 16 concurrent connections, optional shared secret compared in constant
  time; clients validate the socket path and the GUI binary before trusting either.
- **Event socket**: separate listener; *submitting* an event requires a per-PTY capability that is
  never reused and is compared in constant time. Reading the fan-out is open to same-UID processes —
  treat the event channel as non-confidential from your own user.
- **Child processes**: `LD_*`/`DYLD_*`, event-channel, pane-marker, and control-credential variables
  are stripped from every child, and startup-evaluation variables (`PROMPT_COMMAND`, `BASH_ENV`,
  `ENV`, `SHELLOPTS`, `PS4`, `ZDOTDIR`, `PERL5OPT`, `PYTHONSTARTUP`, `NODE_OPTIONS`, `RUBYOPT`,
  `LESSOPEN`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_PAGER`, `PAGER`) are refused from
  configuration. Absolute programs restored from files must not be group/other-writable and must be
  owned by you or root.
- **Restored layouts and profiles**: tile types, settings, and grid geometry are validated; a tile
  that starts a different program, passes extra arguments, or sets a different environment raises the
  Workspace Trust prompt before it runs.
- **Concepts**: the standard Rust `regex` crate only (no backtracking engine), bounded counts and
  lengths, a 16 KiB line cap before matching, 4 MiB capture buffers, and a 64 KiB OSC cap in the
  parser.
- **Markdown**: rendered from Markdown to escaped BBCode — never raw HTML or unescaped tags; links
  are scheme-checked and opened only after an explicit confirmation.

## Known limitations

Recorded honestly; each is either accepted for the current scope or tracked as a roadmap item.

- **Windows peer verification.** The control socket rejects remote clients and lives in the user's
  named-pipe namespace, but Windows pipes have no peer-UID check to fail closed on; on Windows the
  same-UID trust model is the whole gate. Windows runtime behaviour is compile-checked, not yet
  exercised in CI.
- **Other Unix platforms.** `peer_uid_matches` fails *open* on Unix systems that are neither Linux,
  Android, nor macOS (no portable peer-credential API is wired up), leaving file permissions as the
  gate.
- **Shared-`/tmp` fallback.** When `$XDG_RUNTIME_DIR` and `/run/user/<uid>` are unavailable, the
  control socket falls back to a predictable path in a world-writable directory. Socket ownership
  and mode are validated before use, but another user can pre-create the path and deny service (not
  read or spoof traffic).
- **Scrollback is plaintext** in `user://` and the file mode follows your umask. Anything printed in
  a pane — tokens included — is stored on disk the same way a shell history file would be.
- **The update check is notify-only.** It fetches release metadata over TLS and shows a toast; it
  never downloads or executes anything, and the response is treated as display data.
- **Release artifacts are unsigned** (no code signing, no published checksums beyond the GitHub
  release page). Verify the source or build locally if that matters to you.
- **Resource bounds are per-path, not global.** A program that floods a pane can still push the
  render loop and the scrollback store hard; see the DoS items in [ROADMAP.md](ROADMAP.md).
- **Test flakiness under parallel load.** The Inspector adapter tests spawn real child processes with
  timing assumptions and can fail in a heavily loaded parallel run; CI runs the suite serialised.

## Safe harbor

We will not pursue or support legal action against researchers who, in good faith:

- test against their own installation and their own data;
- avoid accessing, modifying, or exfiltrating data that is not theirs;
- report a discovered issue privately and give us a reasonable window to fix it before disclosing;
- do not degrade the service of anyone else.

Security research that follows this policy is welcome. Thank you.
