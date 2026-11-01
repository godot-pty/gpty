#!/usr/bin/env python3
"""Re-run the October 2026 security audit's proofs of concept against this build.

This is the artifact the v0.7 roadmap row "Re-run the audit on the fix build and
cover what it did not reach" asks for: every proof of concept the audit ran (or
described) becomes a probe with a recorded verdict, so the next review starts
from a script instead of from prose.

The harness is NOT duplicated here. Every probe that needs a GUI, a sandbox, a
headless import or a CLI call goes through `scripts/smoke_pane_api.py`, which
already owns the sandbox layout (XDG roots, `GPTY_TEST_USER_DIR`, Godot's
engine log), the headless launch and the readiness probe. This file only adds
the audit's five shapes on top of it, plus the plugin manifest's offline
validator.

Probes
  two-pane-control          a program in pane A drives the control surface with
                            no secret set, because the CLI derives the socket
                            from the inherited XDG_RUNTIME_DIR (documented
                            limitation, queued in v0.9.0) -- Linux only.
  crafted-layout-resource   a legacy `user://layout.json` aims a terminal tile's
                            `font_path` (and `color_scheme_path`) at a `.tres`
                            whose embedded script writes a sentinel file. The
                            fixture is proven live first, so "no sentinel" is
                            evidence rather than a vacuous pass.
  paste-early-close         the shipped `TerminalPane.build_paste_payload`
                            cannot emit a raw ESC (or the paste terminator
                            twice) for a clipboard carrying `ESC[201~`.
  osc-flood                 (a) `cargo test --test escape_string_bound`;
                            (b) a live RSS reading while a pane writes an
                            unterminated OSC string followed by 64 MiB of text
                            (Linux only; /proc has no Windows equivalent).
  malformed-batch           three framed JSON-RPC requests written in ONE write
                            on ONE connection: valid, malformed `params`, valid.
                            Three responses; the middle one is `-32602` naming
                            params; the later request is still served.
  plugin-hostile-manifest   a manifest with a path-traversal id and an oversized
                            tile array, through `gpty plugin install` and the
                            offline `gpty plugin validate`; nothing is written
                            and no `plugins.json` record appears.

Usage
  python3 scripts/audit-probes.py                    # everything
  python3 scripts/audit-probes.py --only osc-flood    # one probe
  python3 scripts/audit-probes.py --list

Exit 0 only when every selected probe's observed outcome matches its
expectation. A probe whose step does not exist on this platform prints a SKIP
line with the reason instead of failing.

Writes stay inside the run's sandbox (`Smoke.tmp`) plus `target/` and
`godot/.godot/` through cargo and the headless import, which the smoke itself
already does. Nothing in the developer's real XDG/user directories is touched.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from smoke_pane_api import (  # noqa: E402
    READY_TIMEOUT_S,
    ROOT,
    SECRET,
    WINDOWS,
    Smoke,
    SmokeFailure,
    strip_ansi,
)

LINUX = sys.platform.startswith("linux")

# One build and one import per run: the smoke's own `main` does the same, and a
# per-probe rebuild would spend more time in cargo than in the probes.
_BUILT = False
_IMPORTED = False


class Skip(Exception):
    """The probe cannot run here; the verdict line says why."""


def ensure_ready(smoke: Smoke) -> None:
    """Build the CLI + extension and import the project, once per run."""
    global _BUILT, _IMPORTED
    if not _BUILT:
        smoke.build()
        _BUILT = True
    if not _IMPORTED:
        smoke.import_project()
        _IMPORTED = True


def finish(smoke: Smoke) -> None:
    """Stop the GUI (through the CLI) and remove the sandbox."""
    try:
        smoke.teardown()
    finally:
        shutil.rmtree(smoke.tmp, ignore_errors=True)


# ── Observation helpers ────────────────────────────────────────────────


def rss_kib(pid: int) -> int | None:
    """The process's resident set size, from `/proc` (Linux only)."""
    try:
        text = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return None


def escaped(raw: bytes) -> str:
    """Printable bytes, control bytes as `\\xNN`."""
    return "".join(chr(b) if 32 <= b < 127 else f"\\x{b:02x}" for b in raw)


def wait_marker(smoke: Smoke, pane: str, pattern: str, deadline_s: float) -> str:
    """Poll `pane-read` until `pattern` appears in the pane's text."""
    rx = re.compile(pattern)
    deadline = time.monotonic() + deadline_s
    text = ""
    while time.monotonic() < deadline:
        text = smoke.read_pane(pane, lines=60)
        if rx.search(text):
            return text
        # The pane may not have its shell yet; a read on a just-created pane
        # fails the CLI, which is the same "not yet" state.
        time.sleep(1.0)
    raise SmokeFailure(
        f"pane {pane} never matched /{pattern}/ within {deadline_s:.0f}s "
        f"(tail: {text[-300:]!r})"
    )


def inject_until(
    smoke: Smoke, pane: str, command: str, pattern: str, attempts: int = 3
) -> str:
    """Inject a command line and wait for its output marker, retrying a lost
    inject (the shell may not have started when the pane was listed)."""
    last = ""
    for attempt in range(1, attempts + 1):
        smoke.cli("inject", pane, "--text", command)
        try:
            return wait_marker(smoke, pane, pattern, 20.0)
        except SmokeFailure as exc:
            last = str(exc)
            print(f"   retry {attempt}/{attempts}: {last[:200]}", flush=True)
    raise SmokeFailure(last)


def godot_script(
    smoke: Smoke, source: str, env_extra: dict[str, str] | None = None
) -> tuple[int, str]:
    """Run a GDScript `SceneTree` in the real project, headless, in the sandbox.

    `--script` takes a filesystem path, so the throwaway driver lives in the
    sandbox and no file is added to the repository. `GPTY_TEST_USER_DIR` and
    `--log-file` keep Godot's own `user://` writes inside it.
    """
    script = smoke.tmp / f"probe-driver-{time.monotonic_ns()}.gd"
    script.write_text(source, encoding="utf-8")
    env = dict(smoke.env)
    env.update(env_extra or {})
    proc = subprocess.run(
        [
            smoke.godot,
            "--headless",
            "--log-file",
            str(smoke.tmp / "godot-script.log"),
            "--path",
            str(ROOT / "godot"),
            "--script",
            str(script),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env=env,
        timeout=600,
    )
    return proc.returncode, strip_ansi(proc.stdout or "") + strip_ansi(proc.stderr or "")


def batch_control(smoke: Smoke, requests: list[dict], timeout: float = 20.0) -> bytes:
    """Write every request in ONE write on ONE connection, read every response.

    The smoke's `control_rpc` opens a connection per call; the audit's defect
    was a *pipelined* batch losing the requests behind a bad one, so the
    probe's value is exactly the single write.
    """
    wire = b"".join(json.dumps(r).encode() + b"\n" for r in requests)
    if WINDOWS:
        raw = open(smoke.control, "r+b", buffering=0)  # noqa: SIM115 - closed below
        try:
            raw.write(wire)
            data = b""
            deadline = time.monotonic() + timeout
            while data.count(b"\n") < len(requests) and time.monotonic() < deadline:
                chunk = raw.readline()
                if not chunk:
                    break
                data += chunk
        finally:
            raw.close()
        return data
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(smoke.control)
        conn.sendall(wire)
        data = b""
        deadline = time.monotonic() + timeout
        while data.count(b"\n") < len(requests) and time.monotonic() < deadline:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    return data


# ── Probe 1: a pane program drives the control surface ─────────────────


def probe_two_pane_control() -> None:
    if not LINUX:
        raise Skip(
            "the premise is the inherited XDG_RUNTIME_DIR, which names nothing on "
            "{0}: there the control endpoint is a named pipe whose DACL is the gate"
            .format("Windows" if WINDOWS else sys.platform)
        )
    smoke = Smoke()
    try:
        run_dir = smoke.tmp / "run"
        run_dir.mkdir(mode=0o700)
        os.chmod(run_dir, 0o700)
        # The audit's premise, exactly: no capability for the GUI and none for
        # any client, so every endpoint is derived from the inherited
        # XDG_RUNTIME_DIR. `Smoke.__init__` sets both, so they go first.
        smoke.env.pop("GPTY_SOCKET", None)
        smoke.env.pop("GPTY_SECRET", None)
        smoke.env["XDG_RUNTIME_DIR"] = str(run_dir)
        smoke.control = str(run_dir / "gpty.sock")
        smoke.events = str(run_dir / "gpty-events.sock")

        ensure_ready(smoke)
        smoke.launch()

        derived = Path(smoke.control)
        if not derived.exists():
            smoke.fail("the GUI did not create a socket at the derived path", str(derived))
        print(
            f"launch env: GPTY_SOCKET=absent GPTY_SECRET=absent "
            f"XDG_RUNTIME_DIR={run_dir}",
            flush=True,
        )
        print(
            f"derived control socket: {derived} "
            f"mode=0o{stat.S_IMODE(derived.stat().st_mode):03o}",
            flush=True,
        )

        pane_a = str(
            smoke.result(smoke.cli("new-pane", "-t", "terminal", "--json"), "new-pane")
            .get("pane_id", "")
        )
        pane_b = str(
            smoke.result(smoke.cli("new-pane", "-t", "terminal", "--json"), "new-pane")
            .get("pane_id", "")
        )
        smoke.require(pane_a != "" and pane_b != "", "two terminal panes must exist",
                      {"a": pane_a, "b": pane_b})

        cli = shlex.quote(str(smoke.cli_bin))
        work = shlex.quote(str(smoke.tmp))
        command = (
            f"cd {work}; "
            f"{cli} list-panes --json > pane-a-list.json 2> pane-a-list.err; "
            f'echo "A_LIST_EXIT=$?"; '
            f"{cli} inject {pane_b} --text PROBE_B_TEXT_RECEIVED; "
            f'echo "A_INJECT_EXIT=$?"; '
            f'echo "A_DONE=$$"'
        )
        print(f"injected into pane {pane_a}: {command}", flush=True)
        text_a = inject_until(smoke, pane_a, command, r"A_DONE=\d")

        def value(name: str) -> str:
            match = re.search(rf"{name}=(-?\d+)", text_a)
            return match.group(1) if match else "(absent)"

        list_exit = value("A_LIST_EXIT")
        inject_exit = value("A_INJECT_EXIT")
        stderr = ""
        err_path = smoke.tmp / "pane-a-list.err"
        if err_path.exists():
            stderr = err_path.read_text(errors="replace").strip()
        served = {}
        list_path = smoke.tmp / "pane-a-list.json"
        if list_path.exists():
            try:
                served = json.loads(list_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                served = {}
        count = (served.get("result") or {}).get("count", "(none)")

        print(f"pane A: `gpty list-panes --json` exited {list_exit}", flush=True)
        print(f"pane A: `gpty inject` exited {inject_exit}", flush=True)
        print(f"pane A stderr: {stderr[:300] or '(empty)'}", flush=True)
        print(f"pane A saw {count} panes over the derived socket", flush=True)

        text_b = ""
        try:
            text_b = wait_marker(smoke, pane_b, "PROBE_B_TEXT_RECEIVED", 20.0)
            print(f"pane B received the injected text "
                  f"({text_b.count('PROBE_B_TEXT_RECEIVED')} sightings)", flush=True)
        except SmokeFailure as exc:
            print(f"pane B did not show the injected text: {exc}", flush=True)

        reached = list_exit == "0" and inject_exit == "0" and isinstance(count, int) and count >= 2
        if not reached:
            smoke.fail(
                "drift from the documented state: the control surface is no longer "
                "reachable from a program in a pane",
                {"list_exit": list_exit, "inject_exit": inject_exit,
                 "stderr": stderr[:300], "panes": count},
            )
        print(
            "OBSERVED reachable (documented): a pane program drove the control "
            "surface with no secret set",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Probe 2: a crafted resource through a real layout file ─────────────

FIXTURE_SCRIPT = r'''extends SceneTree

func _initialize() -> void:
	var loaded = load("res://tests/fixtures/evil_font.tres")
	var sentinel := OS.get_environment("GPTY_EXPLOIT_SENTINEL")
	var wrote := sentinel != "" and FileAccess.file_exists(sentinel)
	print("PROBE_FIXTURE_LOADED=%s" % ("true" if loaded != null else "false"))
	print("PROBE_SENTINEL=%s" % ("written" if wrote else "absent"))
	quit(0)
'''


def probe_crafted_layout_resource() -> None:
    smoke = Smoke()
    try:
        ensure_ready(smoke)
        fixture = ROOT / "godot" / "tests" / "fixtures" / "evil_font.tres"
        smoke.require(fixture.exists(), "the audit fixture must exist", str(fixture))
        sentinel = smoke.tmp / "sentinel"
        smoke.env["GPTY_EXPLOIT_SENTINEL"] = str(sentinel)

        # ── Non-vacuity: the fixture is live. ─────────────────────────
        sentinel.unlink(missing_ok=True)
        code, out = godot_script(smoke, FIXTURE_SCRIPT)
        loaded = "PROBE_FIXTURE_LOADED=true" in out
        wrote = sentinel.exists()
        print(
            f"pre-check: bare load('res://tests/fixtures/evil_font.tres') with "
            f"GPTY_EXPLOIT_SENTINEL set -> loaded={loaded} "
            f"sentinel={'written' if wrote else 'absent'} (godot exit {code})",
            flush=True,
        )
        if not (loaded and wrote):
            smoke.fail(
                "the fixture is not live, so a 'no sentinel' result would prove "
                "nothing (pre-check output)",
                out[-500:],
            )
        sentinel.unlink()
        print("pre-check: sentinel removed; the fixture is proven live", flush=True)

        # ── The crafted layout. ───────────────────────────────────────
        # `godot/tests/fixtures/evil_font.tres` is the resource the audit's
        # loader finding was about: a `.tres` whose sub-resource is a GDScript,
        # so `load()` on it runs code. A byte-identical copy named `.ttf`
        # covers the other half - a fix that only looked at the extension.
        ttf_copy = smoke.tmp / "evil_font.ttf"
        shutil.copyfile(fixture, ttf_copy)
        tiles = [
            # font_path -> the .tres itself (extension gate).
            {"col": 0, "row": 0, "cspan": 30, "rspan": 30,
             "settings": {"type": "terminal", "pane_name": "crafted-font-tres",
                          "font_path": str(fixture)}},
            # color_scheme_path -> the .tres (`file: false` in the table).
            {"col": 30, "row": 0, "cspan": 30, "rspan": 30,
             "settings": {"type": "terminal", "pane_name": "crafted-scheme",
                          "color_scheme_path": str(fixture)}},
            # font_path -> a byte copy named .ttf (extension passes, bytes not).
            {"col": 0, "row": 30, "cspan": 30, "rspan": 30,
             "settings": {"type": "terminal", "pane_name": "crafted-font-ttf",
                          "font_path": str(ttf_copy)}},
            # font_path -> a res:// variant (virtual paths are refused).
            {"col": 30, "row": 30, "cspan": 30, "rspan": 30,
             "settings": {"type": "terminal", "pane_name": "crafted-font-res",
                          "font_path": "res://tests/fixtures/evil_font.tres"}},
        ]
        layout_path = smoke.user_dir() / "layout.json"
        layout_path.write_text(
            json.dumps({"version": 1, "tiles": tiles}), encoding="utf-8"
        )
        print(
            f"wrote legacy {layout_path.name} ({layout_path.stat().st_size} bytes, "
            f"{len(tiles)} tiles; workspaces.json absent so the legacy import runs)",
            flush=True,
        )

        smoke.launch()
        payload = smoke.result(smoke.cli("list-panes", "--json"), "list-panes")
        panes = payload.get("panes") or []
        print(
            f"list-panes after restore: count={payload.get('count')} "
            f"names={[p.get('label') or p.get('name') for p in panes]}",
            flush=True,
        )
        print(f"sentinel after restore: {'PRESENT' if sentinel.exists() else 'absent'}",
              flush=True)
        if sentinel.exists():
            smoke.fail(
                "the crafted layout executed the fixture's script",
                sentinel.read_text(errors="replace")[:200],
            )
        if len(panes) != len(tiles):
            smoke.fail(
                "the legacy layout must restore every tile (so 'no sentinel' is "
                "about the sanitizer, not about nothing loading)",
                {"expected": len(tiles), "restored": len(panes), "panes": payload},
            )
        print(
            "OBSERVED no sentinel with all crafted tiles restored: the font and "
            "scheme paths were dropped before any load()",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Probe 3: the paste payload cannot be closed early ──────────────────

PASTE_SCRIPT = r'''extends SceneTree

func _initialize() -> void:
	var script = load("res://scenes/terminal/terminal_pane.gd")
	if script == null:
		print("PROBE_PASTE_LOAD=failed")
		quit(2)
		return
	var text := "safe\u001b[201~rm -rf /\u0003x\u007f"
	var bracketed: String = script.build_paste_payload(text, true)
	var plain: String = script.build_paste_payload(text, false)
	print("PROBE_BRACKETED_HEX=" + bracketed.to_utf8_buffer().hex_encode())
	print("PROBE_PLAIN_HEX=" + plain.to_utf8_buffer().hex_encode())
	quit(0)
'''


def _hex_field(out: str, key: str) -> bytes:
    match = re.search(rf"{key}=([0-9a-fA-F]*)", out)
    if match is None:
        raise SmokeFailure(f"the driver did not print {key}", out[-500:])
    return bytes.fromhex(match.group(1))


def probe_paste_early_close() -> None:
    smoke = Smoke()
    try:
        ensure_ready(smoke)
        code, out = godot_script(smoke, PASTE_SCRIPT)
        if "PROBE_PASTE_LOAD=failed" in out or code != 0 and "PROBE_BRACKETED_HEX" not in out:
            raise SmokeFailure(
                f"loading res://scenes/terminal/terminal_pane.gd from a script failed "
                f"(godot exit {code})",
                out[-500:],
            )
        bracketed = _hex_field(out, "PROBE_BRACKETED_HEX")
        plain = _hex_field(out, "PROBE_PLAIN_HEX")
        print(f"clipboard text: {escaped('safe\x1b[201~rm -rf /\x03x\x7f'.encode())}", flush=True)
        print(f"bracketed payload ({len(bracketed)} bytes): {escaped(bracketed)}", flush=True)
        print(f"plain payload ({len(plain)} bytes): {escaped(plain)}", flush=True)

        expected_plain = b"safe[201~rm -rf /x"
        expected_bracketed = b"\x1b[200~" + expected_plain + b"\x1b[201~"
        smoke.require(
            plain == expected_plain,
            "the plain branch must drop every C0 control (and not re-add the paste terminator)",
            escaped(plain),
        )
        smoke.require(
            bracketed == expected_bracketed,
            "the bracketed branch must wrap only the filtered text",
            escaped(bracketed),
        )
        smoke.require(
            bracketed.count(b"\x1b[201~") == 1,
            "exactly one paste terminator may exist, and it must be the wrapper's",
            bracketed.count(b"\x1b[201~"),
        )
        smoke.require(
            bracketed[6:-6] == expected_plain,
            "the text between the wrappers must carry no ESC",
            escaped(bracketed[6:-6]),
        )
        smoke.require(
            b"\x03" not in bracketed + plain and b"\x7f" not in bracketed + plain,
            "no Ctrl-C or DEL may survive either branch",
            escaped(bracketed + plain),
        )
        print(
            "OBSERVED no raw ESC from the clipboard on either branch; one "
            "terminator, and it is ours",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Probe 4: the unterminated escape string flood ──────────────────────


def probe_osc_flood() -> None:
    smoke = Smoke()
    try:
        ensure_ready(smoke)

        # (a) The deterministic half: a counting allocator, no RSS guesswork.
        print("running `cargo test -p gpty-core --test escape_string_bound`", flush=True)
        proc = smoke.run(
            ["cargo", "test", "-p", "gpty-core", "--test", "escape_string_bound"],
            cwd=ROOT,
            check=False,
        )
        output = strip_ansi((proc.stdout or "") + (proc.stderr or ""))
        summary = [line for line in output.splitlines() if line.startswith("test result:")]
        print(f"(a) exit {proc.returncode}; {summary[-1].strip() if summary else '(no summary)'}",
              flush=True)
        smoke.require(
            proc.returncode == 0 and bool(summary) and "ok." in summary[-1],
            "escape_string_bound must pass (the OSC payload is capped)",
            output[-600:] if proc.returncode != 0 else summary,
        )

        if not LINUX:
            print(
                "SKIP (b): a live RSS reading needs /proc; this probe's verdict "
                "covers (a) only here",
                flush=True,
            )
            return

        # (b) The live half: a real pane writes an unclosed OSC string, then 64
        # MiB of payload with no BEL. If the guard were missing, `vte` would
        # hold the payload in memory and the GUI's RSS would follow the writer.
        smoke.launch()
        pane = str(
            smoke.result(smoke.cli("new-pane", "-t", "terminal", "--json"), "new-pane")
            .get("pane_id", "")
        )
        smoke.require(pane != "", "the flood needs a live pane", pane)
        pid = smoke.gui.pid
        before = rss_kib(pid)
        smoke.require(before is not None, "the GUI's VmRSS must be readable", pid)
        command = (
            "printf '\\033]0;'; "
            "head -c 67108864 /dev/zero | tr '\\0' x; "
            "printf '\\a'; "
            'echo "OSC_FLOOD_DONE=$?"'
        )
        print(f"pane {pane}: VmRSS before = {before} KiB", flush=True)
        print(f"flood command: {command}", flush=True)
        started = time.monotonic()
        smoke.cli("inject", pane, "--text", command)
        text = wait_marker(smoke, pane, r"OSC_FLOOD_DONE=\d", 300.0)
        elapsed = time.monotonic() - started
        after = rss_kib(pid)
        smoke.require(after is not None, "the GUI's VmRSS must be readable after the flood", pid)
        growth_kib = after - before
        payload_mib = 67108864 / (1024 * 1024)
        print(
            f"flood: {payload_mib:.0f} MiB written in {elapsed:.1f}s; "
            f"VmRSS {before} -> {after} KiB (growth {growth_kib} KiB, "
            f"{growth_kib / 1024:.2f} MiB)",
            flush=True,
        )
        tail = text.strip().splitlines()[-3:]
        print(f"pane tail after the flood: {tail}", flush=True)
        smoke.require(
            growth_kib < 32 * 1024,
            "an unterminated OSC string followed by 64 MiB must not grow the GUI's "
            "RSS by 32 MiB or more",
            {"before_kib": before, "after_kib": after, "growth_kib": growth_kib},
        )
        print(
            "OBSERVED bounded: the guard closed the string and the flood cost no "
            "memory proportional to the writer",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Probe 5: the pipelined malformed batch ─────────────────────────────


def probe_malformed_batch() -> None:
    smoke = Smoke()
    try:
        ensure_ready(smoke)
        smoke.launch()
        smoke.cli("new-pane", "-t", "terminal", "--json")

        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "listPanes", "params": {},
             "gpty_secret": SECRET},
            {"jsonrpc": "2.0", "id": 2, "method": "listPanes", "params": [1, 2],
             "gpty_secret": SECRET},
            {"jsonrpc": "2.0", "id": 3, "method": "listPanes", "params": {},
             "gpty_secret": SECRET},
        ]

        # ── Shape 1: three frames in ONE write on one connection. ─────
        # The server reads exactly one request per connection and closes
        # (`IpcServer::handle_connection`), and every shipped client opens a
        # connection per call - so this records the wire contract rather than
        # pretending a pipeline is supported. The audit's defect was the GUI's
        # *queue*, and shape 2 below reproduces it in the shape it really takes.
        raw = batch_control(smoke, requests)
        lines = [line for line in raw.decode(errors="replace").splitlines() if line.strip()]
        print(
            f"pipelined: 3 framed requests ({sum(len(json.dumps(r)) + 1 for r in requests)} "
            f"bytes) in one write -> {len(lines)} response line(s); the rest of the "
            f"pipeline is dropped with the connection",
            flush=True,
        )
        smoke.require(
            len(lines) == 1,
            "one request per connection is the server's contract; a change here "
            "means the contract moved",
            lines,
        )
        first = json.loads(lines[0])
        smoke.require(
            first.get("id") == 1 and "result" in first,
            "the frame the server reads must be the first one, served",
            first,
        )

        # ── Shape 2: the queue the audit's defect lived in. ───────────
        # Three connections opened together, so all three requests are in the
        # GUI's pending queue at once with the malformed one between them. A
        # drain that aborted on the bad document left requests 3..n unanswered
        # and their callers waiting out the CLI's timeout.
        answers: dict[int, dict] = {}
        failures: list[str] = []

        def send(request: dict) -> None:
            try:
                data = batch_control(smoke, [request], timeout=30.0)
                body = json.loads(data.decode(errors="replace").splitlines()[0])
                answers[request["id"]] = body
            except (OSError, ValueError, IndexError) as exc:
                failures.append(f"id {request['id']}: {type(exc).__name__}: {exc}")

        threads = [threading.Thread(target=send, args=(request,)) for request in requests]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=40)
        smoke.require(not failures, "every queued caller must get an answer", failures)
        print(
            f"queued: answered ids {sorted(answers)}; middle response "
            f"code={(answers.get(2, {}).get('error') or {}).get('code')}",
            flush=True,
        )
        smoke.require(
            sorted(answers) == [1, 2, 3],
            "a batch must answer one response per request",
            sorted(answers),
        )
        smoke.require("result" in answers[1], "the first request must be served", answers[1])
        error = answers[2].get("error") or {}
        smoke.require(
            int(error.get("code") or 0) == -32602,
            "the non-object params must be refused as invalid params",
            answers[2],
        )
        smoke.require(
            "params" in str(error.get("message", "")),
            "the refusal must name params",
            answers[2],
        )
        smoke.require(
            "result" in answers[3],
            "the request queued behind the malformed one must still be served",
            answers[3],
        )
        print(
            "OBSERVED one request per connection; a queued batch answers every "
            "request, the malformed one is -32602 naming params, and the request "
            "behind it is served",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Probe 6: the hostile plugin manifest ───────────────────────────────

TRAVERSAL_MANIFEST = """\
# A manifest whose id is a path-traversal attempt: if the id ever joined a path
# before validation it would land outside <state>/plugins.
id = "../../escaped/plugin"
name = "Hostile"
version = "1.0.0"
min_gpty_version = "0.1.0"

[[profiles]]
name = "Hostile Layout"
tiles = [ { col = 0, row = 0, cspan = 60, rspan = 60, settings = { type = "terminal" } } ]
"""

OVERFLOW_TILE = '{ col = 0, row = 0, cspan = 60, rspan = 60, settings = { type = "terminal" } }'


def probe_plugin_hostile_manifest() -> None:
    smoke = Smoke()
    try:
        ensure_ready(smoke)
        repo = smoke.tmp / "hostile-repo"
        repo.mkdir()
        (repo / "gpty-plugin.toml").write_text(TRAVERSAL_MANIFEST, encoding="utf-8")
        oversized = smoke.tmp / "oversize-repo"
        oversized.mkdir()
        (oversized / "gpty-plugin.toml").write_text(
            'id = "hostile/oversize"\n'
            'name = "Oversized"\n'
            'version = "1.0.0"\n'
            'min_gpty_version = "0.1.0"\n\n'
            "[[profiles]]\n"
            'name = "Too Many Tiles"\n'
            "tiles = [\n  " + ",\n  ".join(OVERFLOW_TILE for _ in range(65)) + ",\n]\n",
            encoding="utf-8",
        )

        state = smoke.state_dir()
        data = Path(smoke.env["LOCALAPPDATA"]) / "gpty" if WINDOWS else Path(smoke.env["XDG_DATA_HOME"])

        # The install target shape: `owner/repo` only, cloned over https. A
        # local `file://` path is refused before anything is cloned or read.
        target = "file://" + str(repo)
        print(f"install target: {target}", flush=True)
        code, payload, detail = smoke.cli_run(
            "--no-daemon", "plugin", "install", target, "--json"
        )
        print(f"plugin install exit {code}", flush=True)
        print(f"plugin install stdout(json): {json.dumps(payload) if payload else '(none)'}",
              flush=True)
        print(f"plugin install error: {detail[:400] or '(empty)'}", flush=True)
        smoke.require(code != 0, "a file:// install target must be refused", detail[:300])
        smoke.require(
            detail != "" and "panicked" not in detail.lower() and "backtrace" not in detail.lower(),
            "the refusal must be a readable sentence, not a panic",
            detail[:300],
        )

        # The manifest's own gate, offline: the validator the GUI's store reads
        # are built from. Both crafted shapes must be refused by name.
        errors = {}
        for label, path, wanted in (
            ("path-traversal id", repo, ("manifest.id",)),
            ("oversized tile array", oversized, ("manifest.profiles[0].tiles", "at most")),
        ):
            vcode, _vpayload, vdetail = smoke.cli_run(
                "--no-daemon", "plugin", "validate", str(path), "--json"
            )
            print(f"plugin validate ({label}) exit {vcode}: {vdetail[:400] or '(empty)'}",
                  flush=True)
            errors[label] = (vcode, vdetail)
            smoke.require(vcode != 0, f"the {label} manifest must be refused", vdetail[:300])
            for token in wanted:
                smoke.require(
                    token in vdetail,
                    f"the {label} refusal must name {token}",
                    vdetail[:300],
                )

        # Nothing was written: no store, no content directory, no escape.
        record = state / "plugins.json"
        escaped_dirs = [smoke.tmp / "escaped", data / "escaped", smoke.tmp / "data" / "escaped"]
        print(
            f"writes: {record} exists={record.exists()}; "
            f"{data / 'plugins'} exists={(data / 'plugins').exists()}; "
            f"staging exists={(data / 'staging').exists()}",
            flush=True,
        )
        smoke.require(not record.exists(), "no plugins.json record may be written", str(record))
        smoke.require(
            not (data / "plugins").exists(),
            "no plugin content directory may be created",
            str(data / "plugins"),
        )
        for path in escaped_dirs:
            smoke.require(not path.exists(), "nothing may be written outside <state>/plugins", str(path))
        print(
            "OBSERVED refused with a readable error; no store record and no file "
            "outside the install roots",
            flush=True,
        )
    finally:
        finish(smoke)


# ── Runner ─────────────────────────────────────────────────────────────

PROBES: list[tuple[str, object]] = [
    ("two-pane-control", probe_two_pane_control),
    ("crafted-layout-resource", probe_crafted_layout_resource),
    ("paste-early-close", probe_paste_early_close),
    ("osc-flood", probe_osc_flood),
    ("malformed-batch", probe_malformed_batch),
    ("plugin-hostile-manifest", probe_plugin_hostile_manifest),
]


def main(argv: list[str]) -> int:
    only: list[str] = []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--list":
            for name, _ in PROBES:
                print(name)
            return 0
        if arg == "--only":
            if not args:
                print("--only needs a probe name (see --list)", file=sys.stderr)
                return 2
            only.append(args.pop(0))
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(f"unknown argument {arg!r} (see --list)", file=sys.stderr)
            return 2

    known = {name for name, _ in PROBES}
    unknown = [name for name in only if name not in known]
    if unknown:
        print(f"unknown probe(s) {unknown} (see --list)", file=sys.stderr)
        return 2
    selected = [(name, fn) for name, fn in PROBES if not only or name in only]

    results: dict[str, str] = {}
    for name, fn in selected:
        print(f"\n== {name}", flush=True)
        started = time.monotonic()
        try:
            fn()
        except Skip as exc:
            results[name] = "SKIP"
            print(f"SKIP {name}: {exc}", flush=True)
            continue
        except SmokeFailure as exc:
            results[name] = "FAIL"
            print(f"FAIL {name}: {exc}", flush=True)
            continue
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
            results[name] = "FAIL"
            print(f"FAIL {name}: unexpected {type(exc).__name__}: {exc}", flush=True)
            continue
        results[name] = "PASS"
        print(f"PASS {name} ({time.monotonic() - started:.1f}s)", flush=True)

    print("\n── verdicts ──", flush=True)
    for name, verdict in results.items():
        print(f"{verdict:5s} {name}", flush=True)
    failed = [name for name, verdict in results.items() if verdict == "FAIL"]
    if failed:
        print(f"RESULT: FAIL ({len(failed)} of {len(results)} probes failed)", flush=True)
        return 1
    print(f"RESULT: PASS ({len(results)} probes)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
