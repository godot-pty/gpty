# Security Model

The security model is a short list of what gPTY trusts, what it does not, and which control stands at each boundary. It is a threat model, not a promise of isolation: a pane is a shell running as you, and the app says so rather than sandboxing it.

## What is trusted

Your own user account. gPTY trusts same-UID processes by design — a process running as you can already read your files and attach to your terminals, so "another program of mine can drive my workspace" is not treated as a vulnerability. `GPTY_SECRET` raises the bar for *other users* on a shared machine. On Linux and Windows it also keeps the secret out of a pane program's reach (see below), which makes the socket gate real for panes when a secret is set — a credential, not isolation. It never changes the trust class.

Untrusted by default: everything printed in a pane, every saved file (layouts, profiles, workspaces, concepts, notes, scrollback), remote responses such as release metadata, and other users on the machine.

## Boundaries

| Boundary | What crosses it | Primary control |
|---|---|---|
| Control socket | Workspace commands: panes, input, layouts, queries | Owner-only socket in a private directory, peer UID check, one-instance ownership, size and connection caps |
| Event socket | Agent metadata and declarations | Per-PTY capability for submission; field allowlist; bounded queues |
| Pane programs | Whatever a shell can do, as you | Environment scrub, argv instead of shell strings, executable validation, Workspace Trust |
| Plugins | Code you chose to install, running as you | Human review, pinned revisions, validated manifest, published tool surface |
| Untrusted files | Tile settings, paths, vault and media locations | Validation, clamping, path gates, trust prompts |
| Rendered content | Markdown, captures, decoded media | Escaping, scheme checks, codec and container allowlists |

## The control socket

This is the highest-value target: it can type into any pane and read any pane. Its hardening is layered.

- **Location.** The socket lives in a per-user directory — the runtime directory when one exists, otherwise a private state directory created owner-only. Only when no private directory can be used does it fall back to a predictable `/tmp/gpty-<uid>.sock`; that path is a denial-of-service target for another user but never a spoof, because ownership and mode are validated before use.
- **Permissions and peers.** Mode 0600, and the connecting process must run as the same user. The peer check fails closed on a lookup error on Linux, macOS, the BSDs, Solaris, and Windows.
- **One owner.** The server probes an existing socket before replacing it and refuses when another server answers, so a second instance cannot take over a live endpoint, while a stale file left by a crash is replaced after the probe finds nobody listening.
- **Bounds.** Requests cap at 64 KiB, at most 16 connections are served at once, and I/O has time bounds so a stalled client cannot hold the GUI.
- **Optional secret.** `GPTY_SECRET` is compared in constant time when set. Clients also validate the socket path and the GUI binary before connecting or spawning.

The protocol itself is documented in [[ipc|IPC]]; the point here is that none of these guards make the socket safe against a process running as you.

## The event socket

The second listener registers exactly three methods and nothing else. Submitting an event requires the per-PTY capability; payloads pass a field allowlist, so a future extension field is dropped rather than forwarded. Reading the fan-out is open to same-UID processes: the channel is non-confidential from your own user. Its methods cannot create panes, inject input, read output, or stop gPTY.

## Pane programs

Every pane is a child of the GUI running with your permissions — there is no sandbox, and the app never claims one. What is controlled is the path *into* a child:

- Environment is sanitized at one choke point. Dynamic-loader keys (`LD_*`, `DYLD_*`), startup-evaluation keys a shell or tool would execute (`PROMPT_COMMAND`, `BASH_ENV`, `ENV`, `NODE_OPTIONS`, `PERL5OPT`, `GIT_SSH_COMMAND`, and similar), the event-channel credentials, and the pane markers are removed from untrusted environment sources.
- Spawns take a program and an argv array. Nothing in the spawn path evaluates a shell string, and absolute programs restored from files must be regular files owned by you or root and not group- or other-writable.
- Concepts cannot execute anything, and the parser interprets exactly one escape sequence — the state declaration that paints a badge. There is no clipboard access via escape sequences.
- Restored tiles and profiles pass the [[workspace-trust|Workspace Trust]] gate before they run.

## Keeping the secret out of a pane's reach

A pane's shell is a child of the GUI and runs as you, so no file permission separates them: whether the shell can read the GUI's environment is decided by the kernel. The GUI and the CLI therefore call `gpty_core::hardening::harden_process()` once at startup, and on Linux that clears the process's *dumpable* bit (`PR_SET_DUMPABLE 0`).

| | Linux | macOS | Windows |
|---|---|---|---|
| How a same-user process reads another process's environment | `/proc/<pid>/environ` | sysctl `KERN_PROCARGS2` (`ps -E`, `pgrep`) | `ReadProcessMemory`, after `OpenProcess` into the PEB |
| What decides same-user access | the target's dumpable bit | the target's user id | the target's process DACL |
| Hardened by gPTY | yes | no | yes |
| Effect on `GPTY_SECRET` | a pane cannot recover it | still readable | a pane cannot recover it |

On Linux a non-dumpable process also loses `/proc/<pid>/maps`, `/proc/<pid>/mem`, and same-user `ptrace` attachment. Measured 2026-10-29 with `GPTY_SECRET` set: before, a program in a pane read the GUI's environment and recovered the secret; after, that file is owned by root, the read fails with `EACCES`, `/proc/<gui>/maps` fails too — and a child of the pane shell can still read the shell's environment. That last part is what makes the trade acceptable: a pane's shell is a separate `exec`ed program, and `exec` restores dumpability, so the GUI is hidden while the user's own code stays debuggable.

### Why the macOS analogue does not carry over

`ptrace(PT_DENY_ATTACH)` denies *tracing*: a debugger cannot attach to the process. It has no effect on `KERN_PROCARGS2`, which is how `ps -E` and `pgrep` return argv and the environment block to any same-UID reader. So on macOS the environment stays readable and `GPTY_SECRET` remains protection against other users only. Unsetting the variable after reading it does not help: `KERN_PROCARGS2` — like Linux's `/proc/<pid>/environ` — reads the initial environment block a process was started with, not the `environ` pointer array that `setenv`/`unsetenv` edits.

### The Windows equivalent

Windows exposes the environment only by reading process memory. gPTY therefore gives the process a DACL that withholds `PROCESS_VM_READ`, `PROCESS_VM_WRITE`, `PROCESS_VM_OPERATION` and `PROCESS_CREATE_THREAD` from the owner — so `ReadProcessMemory` into the PEB is refused, and so is code injection — while keeping `PROCESS_QUERY_LIMITED_INFORMATION` (the mask the control socket's peer check opens a client with), `PROCESS_TERMINATE` (Task Manager can still end a hung GUI), `SYNCHRONIZE` and `READ_CONTROL`. It is one ACE, for the process owner: `SYSTEM` gets no blanket entry, because it holds `SeDebugPrivilege` and a full grant would re-grant everything when the app itself runs as SYSTEM. A process that enables that privilege overrides any process DACL; that is an elevated debugger, not a pane.

### Cost and limits

A non-dumpable process on Linux produces no core dump and cannot be attached to by a same-user debugger or profiler; a hardened Windows process cannot be opened for memory reads by the same user. `GPTY_ALLOW_DEBUG=1` (also `true`, `yes`, `on`) opts out for a developer who needs one; an empty value or `0` does not.

The barrier is not absolute on either platform. `exec` resets the dumpable bit (and the DACL is installed from `main`/init), so the marking lands a moment after a client starts and a process polling the platform's access check can catch a short-lived client's secret. And a shell rc file that exports `GPTY_SECRET` puts it back into every pane that reads that file, because the PTY strip happens before the shell starts.

## Plugins

Plugins are arbitrary code running as you; that is the trust model, stated plainly in [[plugins|Plugins]]. Install clones into a staging directory with git invoked by argv, validates the manifest against the engine's own vocabularies and caps, and requires a human review in the GUI; the store pins the revision, so a moved tag re-prompts. A manifest's actions can only name the published MCP tool surface, and its commands are argv arrays rather than shell strings.

## Untrusted files and rendered content

Saved tiles are validated before they are trusted: the pane type must be known, grid geometry is clamped, arguments are capped, and viewer paths must be absolute. Media paths must be absolute local regular files — no URLs, no device nodes — and the decoder is built without network protocols. Markdown renders to escaped text: raw HTML is not interpreted, images become alt text, only `http`, `https`, and `mailto` links become metadata, and a link opens only after an explicit confirmation. Captured output handed to the Inspector is fenced so that content cannot close the fence and become instructions.

## Known limitations

These are the ones that matter, and they are documented rather than implied.

- **A program in a pane can drive every other pane, unless a secret is set on Linux or Windows.** Panes are children of the GUI, so they pass the control socket's same-user gate, and the default socket path is derivable from the inherited runtime directory. With `GPTY_SECRET` set, the hardened GUI and CLI keep the secret out of a pane program's reach — a credential, not pane isolation. The default install sets no secret; macOS still exposes the environment to same-user processes; and the startup window and rc-file re-export described above still apply. When it is reachable, the reach is the whole surface: inject, pane-run, broadcast, new-pane, kill-pane, and pane-read. Workspaces do not isolate panes from each other. Per-pane permission and a "sensitive workspace" that no client can reach are tracked, not implemented.
- **A pane inherits your environment** other than the stripped keys — `SSH_AUTH_SOCK`, cloud credential pointers, proxy settings, and `DISPLAY` all reach every pane, including a GUI auto-spawned by the CLI.
- **Scrollback is plaintext.** The store and its SQLite siblings are owner-only, but anything printed in a pane — tokens included — is on disk like a shell history file.
- **Media decoding is in-process C.** The pinned FFmpeg build is minimal and allowlisted, but it is not a sandbox.
- **Peer verification has gaps.** A few Unix targets have no peer-credential API wired up and fail open, leaving file permissions as the only gate. The shared-`/tmp` fallback allows pre-creation denial of service.
- **Release artifacts are unsigned**, though they carry build provenance and checksums.
- **Concept matching cost is lines × enabled concepts per burst**, which remains a denial-of-service item under load.

## Related

- [[gpty]]
- [[workspace-trust]]
- [[ipc]]
- [[plugins]]
- [[history]]
