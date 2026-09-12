# @gpty/omp-events

An explicit, user-installed [Oh-My-Pi](https://omp.sh) extension that forwards a
small allowlist of semantic lifecycle events to gpty. It uses OMP's current
`ExtensionAPI` event hooks and `omp.extensions` package manifest.

It does not register tools or commands and is dormant unless all four activation
variables are present:

- `GPTY_EVENT_SOCKET`: absolute Unix socket path from gpty (see platform note below)
- `GPTY_TERMINAL_SESSION_ID`: gpty terminal session identifier
- `GPTY_EVENT_CAPABILITY`: per-session capability supplied by gpty
- `GPTY_EVENT_PROTOCOL=1`: exact supported protocol version

## Install

This package is not loaded automatically by gpty. The user must explicitly link
or select it with OMP:

```sh
omp plugin link /absolute/path/to/gpty/extensions/gpty-omp-events
```

For a one-off run, OMP also supports:

```sh
omp --extension /absolute/path/to/gpty/extensions/gpty-omp-events
```

Restart OMP after changing installed extensions. gpty should launch the terminal
with the four activation variables; setting only some of them does nothing.

## Platform support

gpty injects `GPTY_EVENT_*` only when its OMP event listener is running, and the
listener runs on every platform: `gpty-events.sock` beside `gpty.sock` on
Linux/macOS, `\\.\pipe\gpty-events` (derived from the control pipe) on Windows.

The transport is one code path for both, because `net.connect(path)` opens a
Unix domain socket for a socket path and a named pipe for a pipe path. The only
platform branch is validation: on Windows the path must be a `\\.\pipe\` name
(answered from the path alone — a pipe cannot be `stat`ed), while on Unix the
socket must exist, be a socket, and be owned and mode-restricted by this user.

`scripts/smoke_pane_api.py` runs the shipped extension inside a gpty pane and
asserts the pane reports Tier 1 `working`, so this chain is observed live on
both platforms (the `windows-smoke` CI job is the Windows leg).

## Forwarded data

The JSON-RPC method is `ompEvent`. Every event opens a fresh socket connection,
writes one newline-terminated JSON-RPC 2.0 request, and closes it. Parameters
contain protocol version, capability, terminal session ID, the current OMP
session ID, and one event.

The event allowlist is:

- session start, switch, branch, and shutdown
- agent start/end and turn start/end
- tool execution start/update/end with tool name, call ID, and error state only
- `message_update` events whose subtype is `thinking_delta`, including only the
  bounded reasoning delta and content index

Prompts, answer text, tool arguments/results, provider/model/context objects,
session file paths, environment variables, and credentials are never copied
from OMP events. The capability is the sole authentication value in the
transport envelope.

Strings, complete requests, and the 128-entry outbox are bounded. Transport uses
only Node/Bun built-ins, validates private same-owner Unix sockets where the
platform exposes ownership and mode, applies a short timeout, drops oldest
queued events under pressure, and swallows all transport errors.

## Test

No install step is required:

```sh
npm test
# or
node --test
```

The source is dependency-free ESM and requires Node 20+ or a compatible Bun
runtime when loaded outside OMP.
