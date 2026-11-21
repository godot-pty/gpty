---
title: "Pitfalls: Platform & CI"
weight: 84
---

Traps and invariants across Linux, Windows, macOS, continuous integration runners, build scripts, and headless execution.

## Platform Parity & Packaging

- **Linux user namespaces and overflowuid:** In rootless Podman, Docker, Flatpak, or user namespaces where root is unmapped, system binaries (`/bin/sh`, `/usr/bin/env`) map to overflowuid 65534 (`nobody`). Path validation must permit `overflow_uid` alongside UID `me` and `0` - **but only where the kernel really substitutes it**: `pty::unmapped_owner_uid` reads `/proc/sys/fs/overflowuid` (default 65534) and accepts it only when that UID is outside `/proc/self/uid_map`, so a host with the identity map (`0 0 4294967295`) accepts nothing new and an unreadable `/proc` fails closed. The rule lives once, in `pty::validate_executable_file`; `validate_untrusted_executable` adds the no-writable-ancestor walk for paths saved data chose, while `validate_gui_binary`/`validate_omp_binary` keep only the file rule (`GPTY_GUI`/`GPTY_OMP` are the user's own choice and macOS's `/Applications` is group-writable). `crates/gpty-core/tests/userns_executable.rs` re-execs itself under `unshare -Ur` and proves a 65534-owned system binary is accepted. Do not add an overflow arm to the socket-path or peer-credential checks: those compare against this process exactly.
- **Windows process DACL hardening:** On Windows, gPTY withholds `PROCESS_VM_READ` from same-user processes to prevent unprivileged token snooping. Profilers and debuggers must run with elevated permissions or use `GPTY_ALLOW_DEBUG=1`.
- **macOS bundle naming and discovery:** On macOS, the application bundle is named `gPTY.app`, while the command-line interface binary is `gpty`. GUI binary discovery checks inside the bundle and standard application directories.
- **macOS Mach-O minimum deployment target:** Mixing object files or dynamic libraries built against different deployment targets can silently raise the minimum supported macOS version. `scripts/check-macos-minos` validates Mach-O slices against the 10.13 (x86_64) / 11.0 (arm64) deployment floor.
- **BSD `mode_t` types:** `libc::mode_t` is `u16` on BSD systems and `u32` on Linux. Raw casts like `fchmod(fd, want as libc::mode_t)` ensure cross-platform compatibility across UNIX targets.

## CI Runners, Caching & Build Hygiene

- **Runner image cache isolation:** CI caches compiled shared libraries (such as FFmpeg) and Cargo build artifacts. Caches must not be shared across incompatible OS images (e.g. `ubuntu-22.04` and `ubuntu-24.04`), as newer GLIBC symbol versions (such as `GLIBC_2.38`) break binary compatibility on older base images.
- **Self-modifying shell script execution:** Modifying a shell script (such as `scripts/ci-check`) while it is running causes bash to read offset blocks and execute corrupted commands. Always allow a test run to complete before saving edits to runner scripts.
- **Shell function exit status:** Under `set -e`, a shell function is judged by its final command. Ending a cleanup helper on `[ -n "$TMP" ] && rm -rf "$TMP"` causes the entire script to exit 1 if `$TMP` is unset. Conclude step functions with an explicit `return 0`.
- **Stable PATH symlinks vs. extract folders:** Creating a PATH symlink directly into an extracted release directory breaks when the directory is purged or updated. `scripts/install-cli` installs binaries behind a stable link (`~/.local/opt/gpty/current`).
- **Sandboxed launches and operator credentials:** Launching test harnesses or screenshot scripts from an existing terminal pane can leak `GPTY_SECRET` into child processes. Sandbox runners (`scripts/ui-sandbox`) must explicitly unset credential environment variables.

## Headless Execution Boundaries

- **Zero-size viewports:** Running Godot with `--headless` initializes the root viewport to 0×0 (or 64×64 for `-s` script probes). Layout calculations, divider positions, and responsive UI adapters cannot be validated under headless execution; use windowed capture probes (`scripts/ui-capture`).
- **Missing display drivers and hover events:** Headless execution runs without a window display driver. `Viewport.gui_get_hovered_control()` returns `null`, tooltips never trigger, and `frame_post_draw` notifications never fire. Automated UI tests should assert control properties (`mouse_filter`, `tooltip_text`) rather than simulating pointer hovers.
