# Security Policy

This document states what the project defends against, what it deliberately does not, 
and how to report a problem.

Implementation rules for contributors live in [AGENTS.md](AGENTS.md#security). This file is the
policy: the (currently limited) threat model, the limits, and the reporting process.

## Supported versions

| Version | Support |
| ------- | --------- |
| > 0.5   | :white_check_mark: Security and correctness fixes |
| < 0.5   | :x: |

Generally, fixes will land on `main` and ship in the immediate next release. There is no plan to 
have maintenance branches and/or backports to older minor versions — if a fix matters to you, 
please upgrade.

That said, if there is an issue with a significant severity and implications, the fix will be 
backported to prior releases as feasible.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting**: repository **Security** tab → **Report a
vulnerability**. It opens a private advisory thread visible only to the maintainers. Please do not
open a public issue, pull request, or discussion for a suspected vulnerability — that exposes every
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
discussion post if you think otherwise). Setting `GPTY_SECRET` raises the bar for the control socket; 
but it does not and cannot change the trust class.

**Untrusted — must never gain authority:**

- **Terminal output.** Every byte a program prints, including escape sequences, is attacker-controlled
  if any program you run can be induced to print attacker-chosen text.
- **Files.** Saved layouts, profiles, workspaces, concept definitions, markdown, scrollback: files
  can arrive from a repository, a chat message, or a shared dotfiles setup.
- **Remote responses.** Release metadata, documentation, anything fetched over the network.
- **Other users** on a shared machine, and any file or socket they could have written.

**In scope:**

- All untrusted data reaching a privileged action: Executing a process, writing a file outside the
  app's own `user://` store, gaining the control socket, or delivering input to a pane the user did
  not target;
- Cross-user attacks on shared hosts: socket squatting, world-writable paths, `PATH`/env manipulation;
- remote content driving a local action;
- A lower-trust pane influencing a higher-trust one (an ordinary shell pane feeding a root shell or
  an SSH session);
- Denial of service that locks the GUI thread or grows memory without a bound.

**Out of scope (by design, or accepted):**

- Same-UID processes controlling gPTY (see above);
- Spoofable display state: the `gpty_state=<value>` OSC declaration and the heuristic agent-state
  tiers may be set by anything that can print; they are labelled display-only and are never an input
  to a decision;
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
  that starts a different program or passes extra arguments raises the Workspace Trust prompt before
  it runs, and `layoutLoad` over the control socket refuses such a profile outright (a caller cannot
  answer a dialog, so naming the profile is not consent to what the file asks for). A tile's
  `shell_env` is currently overwritten by your own global environment setting before the shell
  starts, so it neither runs nor needs consent; the ordering that discards it is tracked in
  [ROADMAP.md](ROADMAP.md) with the v0.5.5 environment model.
- **Concepts**: the standard Rust `regex` crate only (no backtracking engine), bounded counts and
  lengths, a 16 KiB line cap before matching, 4 MiB capture buffers, and a 64 KiB OSC cap in the
  parser.
- **Markdown**: rendered from Markdown to escaped BBCode — never raw HTML or unescaped tags; links
  are scheme-checked and opened only after an explicit confirmation.

## Known limitations

Each is either accepted for the current scope or tracked as a roadmap item.

- **Windows peer verification.** The control socket rejects remote clients and lives in the user's
  named-pipe namespace, but Windows pipes have no peer-UID check to fail closed on; on Windows the
  same-UID trust model is the whole gate. Windows environment keys are case-insensitive (and the PTY
  layer normalises them), so the `GPTY_*` credential and marker namespace is not case-sensitive
  there. Windows runtime behaviour is compile-checked, not yet exercised in CI.
- **Other Unix platforms.** `peer_uid_matches` fails *open* on Unix systems that are neither Linux,
  Android, nor macOS (no portable peer-credential API is wired up), leaving file permissions as the
  gate.
- **Shared-`/tmp` fallback.** When `$XDG_RUNTIME_DIR` and `/run/user/<uid>` are unavailable, the
  control socket falls back to a predictable path in a world-writable directory. Socket ownership
  and mode are validated before use, but another user can pre-create the path and deny service (not
  read or spoof traffic).
- **A pane inherits your environment.** The PTY layer snapshots the GUI process's environment and
  strips only the `GPTY_*` keys, so everything else reaches every pane: `SSH_AUTH_SOCK`, cloud
  credential pointers, proxy variables, `DISPLAY`. Launch gPTY from a shell that holds credentials
  you would not hand to a pane (or from inside a pane, or over SSH) and those panes inherit them.
  This is the user's own context, not a file's — but it bounds what any per-pane environment model
  can claim, and it is why the roadmap treats environment as authority rather than configuration.
- **Scrollback is plaintext** in `user://` and the file mode follows your umask. Anything printed in
  a pane — tokens included — is stored on disk the same way a shell history file would be.
- **The update check is notify-only.** It fetches release metadata over TLS and shows a toast; it
  never downloads or executes anything, and the response is treated as display data.
- **Release artifacts are unsigned.** No code signing and no build attestation. Each release publishes
  a `SHA256SUMS` listing every asset, so a download can be checked for corruption or tampering in
  transit — but nothing binds an artifact to the source it was built from. Verify the source or build
  locally if that matters to you.
- **Resource bounds are per-path, not global.** A program that floods a pane can still make that
  pane expensive: the PTY channel is unbounded, so output that outruns the engine's reader grows
  memory, and the scrollback store takes one blocking write per line. The render loop is no longer
  part of it — a pane whose own grid work exceeds its per-frame budget repaints less often instead
  of spending every frame on it (v0.5.3) — but the other two are open DoS items in
  [ROADMAP.md](ROADMAP.md).
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
