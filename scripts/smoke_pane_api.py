#!/usr/bin/env python3
"""Live pane-API smoke: boots the GUI headless and drives the JSON-RPC CLI
end-to-end (new-pane -> status -> inject -> wait -> read -> scrollback ->
broadcast -> pane-run exit code -> kill), plus subscribe/eventsPoll on the
event listener.

One harness for every platform: the transport is the only difference between
Unix and Windows (named pipe vs Unix socket), so the flow is written once and
runs on both — `python3 scripts/smoke_pane_api.py` on Unix,
`python scripts/smoke_pane_api.py` on Windows (whose Godot binary is an .exe
and whose interpreter is `python`). The pane commands it injects are the only
branch that has to know the shell family: the Windows default shell is
`cmd.exe`, which has no `seq`.

The event listener has no auth and is read-only, so the client here is a plain
line-delimited JSON-RPC call over the platform transport.

Requires: godot on PATH (or GODOT=<path>), cargo, and the CLI built from this
tree. On Unix user data is sandboxed with XDG_DATA_HOME; on Windows Godot
resolves its user data through the Known Folder API, which the APPDATA
environment variable does not redirect, so a Windows run uses the real
per-user data directory — fine on a disposable CI runner, worth knowing on a
dev box.

Exit 0 and "PASS" on success; non-zero with "FAIL [step]: ..." and the tail of
the Godot log otherwise. Reads and writes only inside the repo (plus the
sandbox directory, and `target/` and `godot/bin/` via cargo).
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
SECRET = "smoke-secret"
READY_TIMEOUT_S = 60.0


class SmokeFailure(Exception):
    """A step failed; the message is the report."""


class Smoke:
    def __init__(self) -> None:
        self.step = "boot"
        self.tmp = Path(tempfile.mkdtemp(prefix="gpty-smoke-"))
        # A per-run endpoint name: the event listener derives its own endpoint
        # from this one, so both are private to this process.
        self.control = (
            rf"\\.\pipe\gpty-smoke-{os.getpid()}"
            if WINDOWS
            else str(self.tmp / "gpty.sock")
        )
        # Mirrors `transport::default_event_socket_path()`: the listener is
        # named after the control endpoint, with `.sock` swapped for
        # `-events.sock` and the suffix appended when there is none (Windows
        # pipes).
        if self.control.endswith(".sock"):
            self.events = self.control[: -len(".sock")] + "-events.sock"
        else:
            self.events = self.control + "-events"
        self.godot_log = self.tmp / "godot.log"
        self.gui: subprocess.Popen | None = None
        self.cli_bin = ROOT / "target" / "debug" / ("gpty.exe" if WINDOWS else "gpty")
        self.godot = os.environ.get("GODOT") or shutil.which("godot")
        if not self.godot:
            raise SmokeFailure("godot not found on PATH (set GODOT=<path>)")
        self.env = dict(os.environ)
        self.env["GPTY_SOCKET"] = self.control
        self.env["GPTY_SECRET"] = SECRET
        if not WINDOWS:
            self.env["XDG_DATA_HOME"] = str(self.tmp / "data")

    # ── Reporting ─────────────────────────────────────────────────────

    def enter(self, step: str) -> None:
        self.step = step
        print(f"== {step}", flush=True)

    def fail(self, what: str, got: object = None) -> None:
        detail = f" (got: {got!r})" if got is not None else ""
        raise SmokeFailure(f"{what}{detail}")

    def require(self, condition: bool, what: str, got: object = None) -> None:
        if not condition:
            self.fail(what, got)

    # ── CLI ───────────────────────────────────────────────────────────

    def cli(self, *args: str, check: bool = True) -> dict:
        """Run the CLI and return its JSON response."""
        proc = subprocess.run(
            [str(self.cli_bin), *args],
            capture_output=True,
            text=True,
            env=self.env,
        )
        if proc.returncode != 0:
            if not check:
                return {}
            self.fail(
                f"`gpty {' '.join(args)}` exited {proc.returncode}",
                (proc.stderr or proc.stdout).strip()[:300],
            )
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            self.fail(f"`gpty {' '.join(args)}` did not print JSON", proc.stdout[:300])
            raise  # unreachable — fail() raises

    def result(self, payload: dict, what: str) -> dict:
        result = payload.get("result")
        if not isinstance(result, dict):
            self.fail(f"{what} must answer a result object", payload)
        return result

    # ── Event listener ────────────────────────────────────────────────

    def event_rpc(self, method: str, params: dict | None = None) -> dict:
        """One line-delimited JSON-RPC call on the event listener."""
        request = (
            json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
            )
            + "\n"
        ).encode()
        if WINDOWS:
            # Named pipes take the same open() the POSIX path uses, so the
            # framing (a JSON line each way) is identical on both.
            raw = open(self.events, "r+b", buffering=0)  # noqa: SIM115 - closed below
            try:
                raw.write(request)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = raw.readline()
                    if not chunk:
                        break
                    data += chunk
            finally:
                raw.close()
        else:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(10.0)
                conn.connect(self.events)
                conn.sendall(request)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
        try:
            return json.loads(data.decode())
        except json.JSONDecodeError:
            self.fail(f"event {method} did not answer JSON", data[:300])
            raise  # unreachable

    def subscribe(self) -> str:
        """Wait for the event listener, then subscribe to it.

        The listener is started by the first terminal spawn, so the endpoint may
        not exist yet: a connection refused means "not up yet", anything else is
        a failure.
        """
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline:
            try:
                payload = self.event_rpc("subscribe")
            except OSError:
                time.sleep(0.3)
                continue
            subscribed = self.result(payload, "subscribe").get("subscription_id")
            self.require(subscribed is not None, "subscribe must return a subscription id", payload)
            return str(subscribed)
        self.fail("the event listener never accepted a connection", self.events)
        raise  # unreachable

    # ── Lifecycle ─────────────────────────────────────────────────────

    def build(self) -> None:
        self.enter("build")
        self.run(["cargo", "build", "-p", "gpty-gdext", "-p", "gpty", "--quiet"], cwd=ROOT)
        self.require(self.cli_bin.exists(), f"the CLI was not built at {self.cli_bin}")
        # The editor looks up the library under the name in gpty.gdextension.
        bin_dir = ROOT / "godot" / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        if WINDOWS:
            shutil.copyfile(
                ROOT / "target" / "debug" / "gpty_gdext.dll",
                bin_dir / "gpty_gdext.windows.x86_64.dll",
            )
        else:
            link = bin_dir / "libgpty_gdext.linux.x86_64.so"
            link.unlink(missing_ok=True)
            link.symlink_to(Path("../../target/debug/libgpty_gdext.so"))

    def import_project(self) -> None:
        self.enter("import")
        self.run([self.godot, "--headless", "--path", "godot", "--import"], cwd=ROOT)

    def launch(self) -> None:
        self.enter("launch")
        log = self.godot_log.open("w")
        self.gui = subprocess.Popen(
            [self.godot, "--headless", "--path", "godot"],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=self.env,
        )
        deadline = time.monotonic() + READY_TIMEOUT_S
        while time.monotonic() < deadline:
            if self.gui.poll() is not None:
                self.fail(f"the GUI exited with {self.gui.returncode} during startup")
            # --no-daemon: a probe must not auto-spawn a second GUI.
            status = self.cli("--no-daemon", "daemon", "status", "--json", check=False)
            if status.get("result", {}).get("version"):
                return
            time.sleep(0.5)
        self.fail(f"the GUI did not become reachable within {READY_TIMEOUT_S:.0f}s")

    def teardown(self) -> None:
        if self.gui is None:
            return
        # A failed build may leave no CLI to ask; the process kill below still
        # has to happen, and a missing binary must not mask the real failure.
        if self.cli_bin.exists():
            self.cli("--no-daemon", "daemon", "stop", "--json", check=False)
        try:
            self.gui.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.gui.kill()
            self.gui.wait(timeout=10)

    def log_tail(self, lines: int = 40) -> str:
        try:
            text = self.godot_log.read_text(errors="replace").splitlines()
        except OSError:
            return "(no Godot log)"
        return "\n".join(text[-lines:])

    def run(
        self, argv: list[str], cwd: Path | None = None, check: bool = True
    ) -> subprocess.CompletedProcess:
        proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=self.env)
        if check and proc.returncode != 0:
            self.fail(
                f"`{' '.join(str(a) for a in argv)}` exited {proc.returncode}",
                (proc.stderr or proc.stdout).strip()[-300:],
            )
        return proc

    # ── Pane API ──────────────────────────────────────────────────────

    def wait_for_output(self, pane_id: str, pattern: str, timeout_ms: int = 10000) -> dict:
        payload = self.cli(
            "pane-wait", pane_id, "--pattern", pattern, "--timeout-ms", str(timeout_ms), "--json"
        )
        return self.result(payload, "pane-wait")

    def read_pane(self, pane_id: str, lines: int = 50) -> str:
        payload = self.cli("pane-read", pane_id, "--lines", str(lines), "--json")
        return str(self.result(payload, "pane-read").get("text", ""))

    def pane_count(self) -> int:
        payload = self.cli("list-panes", "--json")
        return int(self.result(payload, "list-panes").get("count", -1))


def main() -> int:
    smoke = Smoke()
    subscription = None
    try:
        smoke.build()
        smoke.import_project()
        smoke.launch()

        # ── Event listener ────────────────────────────────────────────
        smoke.enter("event listener")
        subscription = smoke.subscribe()

        # ── new-pane (the default shell for this platform) ─────────────
        smoke.enter("new-pane")
        pane_id = None
        for _ in range(5):
            payload = smoke.cli(
                "new-pane", "-t", "terminal", "--tags", "smoke", "--json", check=False
            )
            if payload.get("result", {}).get("pane_id"):
                pane_id = payload["result"]["pane_id"]
                break
            time.sleep(1.0)
        smoke.require(pane_id is not None, "new-pane must return a pane_id", payload)

        spawn_events = smoke.result(
            smoke.event_rpc("eventsPoll", {"subscription_id": subscription, "limit": 64}),
            "eventsPoll",
        ).get("events", [])
        smoke.require(
            any(e.get("type") == "pane" and e.get("event") == "spawned" for e in spawn_events),
            "eventsPoll must deliver the pane spawn event",
            spawn_events[:3],
        )

        smoke.enter("pane-status (running)")
        status = {}
        for _ in range(20):
            payload = smoke.cli("pane-status", pane_id, "--json", check=False)
            status = payload.get("result", {})
            if status.get("running") is True:
                break
            time.sleep(0.5)
        smoke.require(status.get("running") is True, "the pane must be running", status)

        # ── inject -> pane-wait -> pane-read ──────────────────────────
        smoke.enter("inject + pane-wait")
        smoke.cli("inject", pane_id, "--text", "echo SMOKE_7X9Q2", "--json")
        smoke.require(
            smoke.wait_for_output(pane_id, "SMOKE_7X9Q2").get("matched") is True,
            "pane-wait must match the injected marker",
        )

        smoke.enter("pane-read")
        smoke.require(
            "SMOKE_7X9Q2" in smoke.read_pane(pane_id),
            "pane-read must contain the injected marker",
        )

        # ── scrollback: content that scrolled off the screen ──────────
        smoke.enter("pane-read (scrollback)")
        # Exactly 120 lines between the markers, on both platforms. The Windows
        # side used to list System32 — thousands of lines on a runner — which
        # pushed the oldest marker far outside the 200-line read, so the
        # assertion failed on content the test never meant to generate: what is
        # under test is that lines scrolled off the screen come back, not how
        # much output a directory happens to have. cmd needs the loop
        # parenthesised, or the trailing `& echo` joins the loop body.
        fill = (
            r"echo SMOKE_OLDEST_A1B2 & (for /l %i in (1,1,120) do @echo scroll_%i)"
            r" & echo SMOKE_NEWEST_C3D4"
            if WINDOWS
            else "echo SMOKE_OLDEST_A1B2; seq 1 120; echo SMOKE_NEWEST_C3D4"
        )
        smoke.cli("inject", pane_id, "--text", fill, "--json")
        smoke.require(
            smoke.wait_for_output(pane_id, "SMOKE_NEWEST_C3D4").get("matched") is True,
            "the scrollback fill must reach the pane",
        )
        scrollback = smoke.read_pane(pane_id, lines=200)
        if "SMOKE_OLDEST_A1B2" not in scrollback:
            # Report the shape of what came back: a missing oldest marker means
            # either the read window missed it (too many lines between the
            # markers) or the grid kept no scrollback at all, and the first two
            # and last two lines tell those apart from the log alone.
            returned = scrollback.splitlines()
            smoke.fail(
                "pane-read must return scrollback, not just the visible screen",
                {
                    "lines_returned": len(returned),
                    "first": returned[:2],
                    "last": returned[-2:],
                },
            )
        smoke.require("SMOKE_NEWEST_C3D4" in scrollback, "pane-read must return the newest line")

        # ── the shipped extension's transport ─────────────────────────
        # Runs the extension's own code inside the pane, where the per-PTY
        # GPTY_EVENT_* variables live, and asserts the pane reports Tier 1
        # `working` — the whole chain in one observable: pane environment ->
        # extension transport (socket or named pipe) -> capability check ->
        # translation -> GDScript drain -> agent state.
        smoke.enter("extension transport")
        sender = ROOT / "extensions" / "gpty-omp-events" / "tools" / "send-event.mjs"
        if shutil.which("node") is None:
            print("  node not on PATH — skipping; the extension cannot run here", flush=True)
        else:
            smoke.cli("inject", pane_id, "--text", f'node "{sender.as_posix()}"', "--json")
            state = {}
            # Both fields: Tier 3 (output is flowing, the node process is
            # printing) can also report `working`, and only Tier 1 proves the
            # capability-authenticated channel carried the event.
            for _ in range(20):
                state = smoke.cli("pane-status", pane_id, "--json", check=False).get("result", {})
                if state.get("agent_state") == "working" and state.get("agent_state_tier") == 1:
                    break
                time.sleep(0.5)
            if state.get("agent_state") != "working":
                smoke.fail(
                    "the extension's event must reach the pane as Tier 1 working",
                    {"status": state, "pane_tail": smoke.read_pane(pane_id, lines=20)[-600:]},
                )
            smoke.require(
                state.get("agent_state_tier") == 1,
                "the state must come from the capability-authenticated channel",
                state,
            )

        # ── broadcast to a tagged pane ────────────────────────────────
        smoke.enter("broadcast")
        broadcast = smoke.result(
            smoke.cli("broadcast", "--tags", "smoke", "--text", "echo BROADCAST_OK", "--json"),
            "broadcast",
        )
        smoke.require(broadcast.get("count") == 1, "broadcast must hit exactly the tagged pane", broadcast)
        smoke.require(
            smoke.wait_for_output(pane_id, "BROADCAST_OK").get("matched") is True,
            "broadcast text must reach the pane",
        )

        # ── pane-run: through the configured shell, exit code intact ──
        smoke.enter("pane-run")
        run = smoke.result(
            smoke.cli("pane-run", "--command", "echo SMOKE_COMPOUND && exit 7", "--json"),
            "pane-run",
        )
        run_id = run.get("pane_id")
        smoke.require(bool(run_id), "pane-run must return a pane_id", run)
        run_status = {}
        for _ in range(30):
            payload = smoke.cli("pane-status", run_id, "--json", check=False)
            run_status = payload.get("result", {})
            if run_status.get("running") is False:
                break
            time.sleep(0.5)
        smoke.require(run_status.get("running") is False, "the pane-run pane must exit", run_status)
        smoke.require(
            run_status.get("exit_code") == 7,
            "the compound command must exit 7",
            run_status,
        )
        smoke.require(
            "SMOKE_COMPOUND" in smoke.read_pane(run_id),
            "pane-run output must contain the compound marker",
        )
        smoke.cli("kill-pane", run_id, "--json")

        # ── kill-pane ─────────────────────────────────────────────────
        smoke.enter("kill-pane")
        before = smoke.pane_count()
        smoke.cli("kill-pane", pane_id, "--json")
        after = smoke.pane_count()
        smoke.require(after == before - 1, f"kill-pane must decrement the pane count ({before} -> {after})")
        killed = smoke.result(
            smoke.event_rpc("eventsPoll", {"subscription_id": subscription, "limit": 64}),
            "eventsPoll",
        ).get("events", [])
        smoke.require(
            any(e.get("type") == "pane" and e.get("event") == "killed" for e in killed),
            "eventsPoll must deliver the pane killed event",
            killed[:3],
        )

        smoke.enter("teardown")
        print("PASS")
        return 0
    except SmokeFailure as failure:
        print(f"FAIL [{smoke.step}]: {failure}", file=sys.stderr)
        print("--- Godot log (tail) ---", file=sys.stderr)
        print(smoke.log_tail(), file=sys.stderr)
        return 1
    finally:
        smoke.teardown()
        shutil.rmtree(smoke.tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
