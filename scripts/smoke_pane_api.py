#!/usr/bin/env python3
"""Live pane-API smoke: boots the GUI headless and drives the JSON-RPC CLI
end-to-end (new-pane -> status -> inject -> wait -> read -> scrollback ->
broadcast -> pane-run exit code -> concept from output -> cli_view stdout ->
plugin-provided profile -> kill), plus subscribe/eventsPoll on the event
listener.

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
tree. On Unix user data and state are sandboxed with XDG_DATA_HOME and
XDG_STATE_HOME; on Windows Godot resolves its user data through the Known
Folder API, which the APPDATA environment variable does not redirect, and the
plugin store lives under `%LOCALAPPDATA%`, so a Windows run uses the real
per-user directories — fine on a disposable CI runner, worth knowing on a
dev box. The stores the harness writes itself (a concept, and an installed
plugin's record) are backed up and put back in teardown, so a dev-box run
leaves no trace.

Exit 0 and "PASS" on success; non-zero with "FAIL [step]: ..." and the tail of
the Godot log otherwise. Reads and writes only inside the repo (plus the
sandbox directory, and `target/` and `godot/bin/` via cargo).
"""

from __future__ import annotations

import json
import os
import re
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
            # The plugin store lives in the state directory; sandbox it too, so
            # the seeded record (and anything the GUI writes) never touches the
            # developer's real store.
            self.env["XDG_STATE_HOME"] = str(self.tmp / "state")
        # The seeded stores (see `seed_concepts` / `seed_plugin`): each path
        # and the bytes to put back in teardown.
        self.concepts_path: Path | None = None
        self.concepts_backup: bytes | None = None
        self.plugins_path: Path | None = None
        self.plugins_backup: bytes | None = None

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

    # ── Diagnostics ───────────────────────────────────────────────────
    # Failure-time evidence, kept permanently: the Windows-only failures so
    # far have been races between what pane-read shows (raw grid bytes) and
    # what pane-wait scans (committed lines), and the shape below
    # distinguishes late arrival (idle_ms ~0: the bytes just landed) from a
    # line the parser never committed (idle_ms ~= the wait's own duration,
    # and a fresh short wait still misses). Every wait failure path calls it.

    def diag(self, pane_id: str, pattern: str | None = None) -> dict:
        status = self.cli("pane-status", pane_id, "--json", check=False).get("result", {})
        tail = self.read_pane(pane_id, lines=50).splitlines()[-15:]
        diag: dict = {
            "idle_ms": int(status.get("idle_ms") or 0),
            "echo_reached": any(("%i" in line or "%s" in line) for line in tail),
            "pane_tail": tail,
        }
        if pattern is not None:
            diag["fresh_wait"] = self.wait_for_output(pane_id, pattern, timeout_ms=2000)
        return diag

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
            # A failure between seeding and launch still has to put the stores
            # back.
            self.restore_concepts()
            self.restore_plugin()
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
        # After the GUI is gone, so nothing overwrites the stores behind us.
        self.restore_concepts()
        self.restore_plugin()

    # ── Concept seed ──────────────────────────────────────────────────
    # The smoke needs a concept it can trigger from real *output*. The only
    # registration route that exists is the store the GUI reads at startup
    # (`concept toggle` flips a shipped rule, it cannot add one), so it is
    # seeded before launch and put back in teardown: on Windows `user://` is
    # the real per-user directory — Godot resolves it through the Known
    # Folder API, which APPDATA does not redirect — and a dev-box run must
    # leave no trace.

    CONCEPT_NAME = "smoke_concept"
    ## The trigger demands the digit the shell appends at runtime: the typed
    ## line builds `SMOKE_CONCEPT_8K3%s` / `...%i`, which this cannot match, so
    ## only a real output line — the one a ConPTY parser regression stops
    ## committing — can fire the concept.
    CONCEPT_TRIGGER = r"SMOKE_CONCEPT_8K3[0-9]"

    def user_dir(self) -> Path:
        """Godot's `user://` for this project, as the platform resolves it."""
        project = re.search(
            r'config/name="([^"]+)"',
            (ROOT / "godot" / "project.godot").read_text(encoding="utf-8"),
        )
        if project is None:
            self.fail("godot/project.godot has no config/name to derive user:// from")
            raise  # unreachable — fail() raises
        data_home = os.environ["APPDATA"] if WINDOWS else self.env["XDG_DATA_HOME"]
        return Path(data_home) / "godot" / "app_userdata" / project.group(1)

    def seed_concepts(self) -> None:
        path = self.user_dir() / "concepts.json"
        self.concepts_path = path
        self.concepts_backup = path.read_bytes() if path.exists() else None
        store: dict = {}
        if path.exists():
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    store = loaded
            except (json.JSONDecodeError, UnicodeDecodeError):
                # A hand-broken store reads as empty in the GUI too.
                store = {}
        concepts = store.get("concepts")
        if not isinstance(concepts, list):
            concepts = []
        concepts.append(
            {
                "name": self.CONCEPT_NAME,
                "trigger": self.CONCEPT_TRIGGER,
                "enabled": True,
                "capture_mode": "until_stop",
                "stop_timeout_ms": 400,
                "stop_on_input": True,
                "actions": [{"target": "code_viewer"}],
            }
        )
        store["concepts"] = concepts
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(store), encoding="utf-8")

    def restore_concepts(self) -> None:
        if self.concepts_path is None:
            return
        try:
            if self.concepts_backup is None:
                self.concepts_path.unlink(missing_ok=True)
            else:
                self.concepts_path.write_bytes(self.concepts_backup)
        except OSError as error:
            print(
                f"warning: could not restore {self.concepts_path}: {error}",
                file=sys.stderr,
            )

    # ── Plugin store seed ─────────────────────────────────────────────
    # The profiles migration moved the five tool layouts onto plugin repos, and
    # the GUI reads what `gpty plugin install` recorded in the store (it never
    # parses a manifest). Seeding a record is therefore the whole install as far
    # as the GUI is concerned — the step below proves store -> FFI ->
    # ProfileManager -> layoutList/layoutLoad live. On Windows the state dir is
    # the real per-user one (`%LOCALAPPDATA%\gpty`), so the file is backed up
    # and restored like the concept store.

    PLUGIN_ID = "godot-pty/smoke-plugin"
    PLUGIN_REVISION = "0123456789abcdef0123456789abcdef01234567"
    PLUGIN_PROFILE = "Smoke Layout"
    PLUGIN_TILE_ID = "smoke-tile"

    def state_dir(self) -> Path:
        """gpty's state directory, as `transport::state_dir()` resolves it."""
        if WINDOWS:
            return Path(os.environ["LOCALAPPDATA"]) / "gpty"
        return Path(self.env["XDG_STATE_HOME"]) / "gpty"

    def seed_plugin(self) -> None:
        path = self.state_dir() / "plugins.json"
        self.plugins_path = path
        self.plugins_backup = path.read_bytes() if path.exists() else None
        store: dict = {}
        if path.exists():
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    store = loaded
            except (json.JSONDecodeError, UnicodeDecodeError):
                store = {}
        plugins = store.get("plugins")
        if not isinstance(plugins, list):
            plugins = []
        plugins.append(
            {
                "id": self.PLUGIN_ID,
                "revision": self.PLUGIN_REVISION,
                "enabled": True,
                "installed_at": 0,
                "profiles": [
                    {
                        "name": self.PLUGIN_PROFILE,
                        "tiles": [
                            {
                                "col": 0,
                                "row": 0,
                                "cspan": 60,
                                "rspan": 60,
                                "settings": {
                                    "type": "terminal",
                                    "attachment_id": self.PLUGIN_TILE_ID,
                                    "pane_name": "From a plugin",
                                },
                            }
                        ],
                    }
                ],
            }
        )
        store["plugins"] = plugins
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(store), encoding="utf-8")

    def restore_plugin(self) -> None:
        if self.plugins_path is None:
            return
        try:
            if self.plugins_backup is None:
                self.plugins_path.unlink(missing_ok=True)
            else:
                self.plugins_path.write_bytes(self.plugins_backup)
        except OSError as error:
            print(
                f"warning: could not restore {self.plugins_path}: {error}",
                file=sys.stderr,
            )

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
        # The concept store is read at GUI startup, so the seed must land
        # before the launch (and it is restored in teardown).
        smoke.seed_concepts()
        # Same for the plugin store: its records are what the GUI lists as
        # installed-plugin profiles.
        smoke.seed_plugin()
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

        # ── shell readiness: a line typed before the child attaches is read ──
        # by nothing (the repo's documented cold-shell hazard — measured past
        # 10 s on a cold runner). Quiescing is necessary but not sufficient:
        # the banner can finish while a quiet rc phase (no output) is still
        # running, so the shell must *answer* a probe before real input is
        # trusted. `idle_ms` is 0 until the first output and stays ~0 while
        # the shell keeps printing, so a quarter second of silence is the
        # fast path; the probe loop below is the proof.
        smoke.enter("shell readiness")
        idle_ms = 0
        for _ in range(120):
            payload = smoke.cli("pane-status", pane_id, "--json", check=False)
            idle_ms = int(payload.get("result", {}).get("idle_ms") or 0)
            if idle_ms >= 250:
                break
            time.sleep(0.25)
        smoke.require(
            idle_ms >= 250,
            "the shell must quiesce before input is injected",
            idle_ms,
        )
        # The probe retries until the shell answers: a probe typed before the
        # shell attaches is discarded (the same hazard as any injected line),
        # so a cold runner may need several rounds before one is read.
        # The marker is BUILT at shell runtime (`printf %s` / `for /l %i`), so
        # the typed command text never contains it — only the output line can
        # match, on every platform and line discipline, with no anchors. The
        # marker ends in a DIGIT: the cmd loop can only append its loop
        # variable, so the POSIX and cmd forms must build the same final
        # character (a letter ending made `...9X7%i` print `...9X77`).
        probe_cmd = (
            r"for /l %i in (7,1,7) do @echo SMOKE_READY_4Q%i"
            if WINDOWS
            else "printf 'SMOKE_READY_4Q%s\\n' 7"
        )
        answered = False
        for _ in range(10):
            smoke.cli("inject", pane_id, "--text", probe_cmd, "--json")
            if (
                smoke.wait_for_output(pane_id, "SMOKE_READY_4Q7", timeout_ms=3000).get(
                    "matched"
                )
                is True
            ):
                answered = True
                break
            time.sleep(1.0)
        if not answered:
            smoke.fail(
                "the shell must answer the readiness probe",
                smoke.diag(pane_id, "SMOKE_READY_4Q7"),
            )

        # ── inject -> pane-wait -> pane-read ──────────────────────────
        smoke.enter("inject + pane-wait")
        # The marker is built at shell runtime (see the probe): the typed
        # command's echo cannot contain it, so the wait matches only the
        # output line — the echo-spoof and wrap-splitting hazards are
        # designed out, not regexed around.
        first_cmd = (
            r"for /l %i in (2,1,2) do @echo SMOKE_7X9Q%i"
            if WINDOWS
            else "printf 'SMOKE_7X9Q%s\\n' 2"
        )
        smoke.cli("inject", pane_id, "--text", first_cmd, "--json")
        first_wait = smoke.wait_for_output(pane_id, "SMOKE_7X9Q2")
        if first_wait.get("matched") is not True:
            smoke.fail(
                "pane-wait must match the injected marker",
                {"wait": first_wait, **smoke.diag(pane_id, "SMOKE_7X9Q2")},
            )
        smoke.require(
            first_wait.get("matched") is True,
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
        # Both markers are BUILT at shell runtime (see the probe), so the
        # typed line's echo never contains them: the wait can only match the
        # real output lines, and the wrap of the long echoed command cannot
        # split a marker that is not in it.
        fill = (
            r"for /l %i in (2,1,2) do @echo SMOKE_OLDEST_A1B%i&(for /l %i in (1,1,120) do @echo scroll_%i)&for /l %i in (4,1,4) do @echo SMOKE_NEWEST_C3D%i"
            if WINDOWS
            else "printf 'SMOKE_OLDEST_A1B%s\\n' 2; seq 1 120; printf 'SMOKE_NEWEST_C3D%s\\n' 4"
        )
        smoke.cli("inject", pane_id, "--text", fill, "--json")
        fill_wait = smoke.wait_for_output(pane_id, "SMOKE_NEWEST_C3D4")
        if fill_wait.get("matched") is not True:
            smoke.fail(
                "the scrollback fill must reach the pane",
                {"wait": fill_wait, **smoke.diag(pane_id, "SMOKE_NEWEST_C3D4")},
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
                    **smoke.diag(pane_id, "SMOKE_NEWEST_C3D4"),
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
            #
            # The budget is sized for a process launch, not for the round trip
            # this step is about: it starts a cold `node` on the runner, and on
            # `windows-smoke` that outran the 10 s this used to allow — the pane
            # tail showed the echoed `node "…/send-event.mjs"` line and nothing
            # else, `idle_ms` 9837, so the step reported "the event never
            # arrived" for a Node.js that was still starting. The same mistake
            # was fixed in `test_bracketed_paste.gd` when a cold
            # `powershell.exe` outran its 10 s.
            for _ in range(120):
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

        # ── gpty state: a program declaring its own pane state ────────
        # The CLI reads the credentials its parent pane injected
        # (GPTY_EVENT_SOCKET / GPTY_TERMINAL_SESSION_ID /
        # GPTY_EVENT_CAPABILITY) and submits a declaration on the event
        # socket. This is the Windows declaration path — ConPTY consumes the
        # `gpty_state` OSC before gpty's parser can see it — and the value is
        # deliberately not `working`, which the Tier 3 heuristic can report on
        # its own while output flows.
        smoke.enter("gpty state")
        smoke.cli(
            "inject",
            pane_id,
            "--text",
            f'"{smoke.cli_bin}" state needs-attention',
            "--json",
        )
        state = {}
        for _ in range(20):
            state = smoke.cli("pane-status", pane_id, "--json", check=False).get("result", {})
            if state.get("agent_state") == "needs-attention" and state.get("agent_state_tier") == 1:
                break
            time.sleep(0.5)
        if state.get("agent_state") != "needs-attention":
            smoke.fail(
                "`gpty state needs-attention` must declare the pane's state",
                {"status": state, "pane_tail": smoke.read_pane(pane_id, lines=20)[-600:]},
            )
        smoke.require(
            state.get("agent_state_tier") == 1,
            "a declaration must arrive over the capability-authenticated channel",
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
        if run_status.get("running") is not False:
            # Report the pane's own text as well as its status: "the command
            # never ran" and "it ran but the exit was never reported" look
            # identical in the status alone.
            smoke.fail(
                "the pane-run pane must exit",
                {
                    "status": run_status,
                    "pane_tail": smoke.read_pane(run_id, lines=20)[-400:],
                },
            )
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

        # ── a concept fires from real output ──────────────────────────
        # ConPTY renders line breaks as cursor moves (no LF), so the parser
        # only commits real command output after the row-advancing CSI fix;
        # before it, only CRLF-terminated input echoes matched. The seeded
        # concept's trigger demands the digit the shell appends at runtime, so
        # nothing typed can match it — the event below can only come from an
        # output line, and a parser regression fails this step instead of
        # shipping.
        smoke.enter("concept from output")
        concepts = smoke.result(
            smoke.cli("concept", "list", "--json"), "concept list"
        ).get("concepts", [])
        smoke.require(
            any(
                c.get("name") == smoke.CONCEPT_NAME and c.get("enabled") is True
                for c in concepts
            ),
            "the seeded concept must be loaded and enabled",
            [c.get("name") for c in concepts],
        )
        # Route it for real: with no receiver the capture is flushed back to
        # the terminal and toasted instead of consumed.
        viewer = smoke.result(
            smoke.cli("new-pane", "-t", "code_viewer", "--json"),
            "new-pane (code_viewer)",
        )
        viewer_id = viewer.get("pane_id")
        smoke.require(bool(viewer_id), "the code_viewer receiver must spawn", viewer)
        concept_cmd = (
            r"for /l %i in (1,1,1) do @echo SMOKE_CONCEPT_8K3%i"
            if WINDOWS
            else "printf 'SMOKE_CONCEPT_8K3%s\\n' 8"
        )
        smoke.cli("inject", pane_id, "--text", concept_cmd, "--json")
        matched = False
        for _ in range(40):
            events = smoke.result(
                smoke.event_rpc(
                    "eventsPoll", {"subscription_id": subscription, "limit": 64}
                ),
                "eventsPoll",
            ).get("events", [])
            if any(
                e.get("type") == "concept"
                and e.get("name") == smoke.CONCEPT_NAME
                and e.get("target") == "code_viewer"
                for e in events
            ):
                matched = True
                break
            time.sleep(0.5)
        if not matched:
            smoke.fail(
                "a concept must fire from the child's output on this platform",
                {"pane_tail": smoke.read_pane(pane_id, lines=20)[-400:]},
            )
        smoke.cli("kill-pane", viewer_id, "--json")

        # ── cli_view: a command's stdout streamed into a pane body ────
        # The pane runs argv directly (no shell, no PTY), so this step also
        # pins the two API halves that make it usable: `new-pane` carrying
        # `--arg` argv for the cli_view type, and `pane-read` serving the body
        # text of a pane that is not a terminal. The marker is read *after*
        # the child has printed and exited, which is what pins the view as a
        # retained ring rather than a live-only stream.
        smoke.enter("cli_view")
        if WINDOWS:
            view_program = os.environ.get("COMSPEC", "cmd.exe")
            view_argv = ["/c", "echo SMOKE_CLI_VIEW_5F2"]
        else:
            view_program = "/bin/sh"
            view_argv = ["-c", "printf 'SMOKE_CLI_VIEW_5F2\\n'"]
        view_cmd = ["new-pane", "-t", "cli_view", "--command", view_program]
        for arg in view_argv:
            view_cmd += ["--arg", arg]
        view_cmd += ["--json"]
        view = smoke.result(smoke.cli(*view_cmd), "new-pane (cli_view)")
        view_id = view.get("pane_id")
        smoke.require(bool(view_id), "new-pane must return a cli_view pane_id", view)
        smoke.require(view.get("type") == "cli_view", "the pane must report the cli_view type", view)
        view_text = ""
        for _ in range(40):
            view_text = smoke.read_pane(view_id, lines=50)
            if "SMOKE_CLI_VIEW_5F2" in view_text:
                break
            time.sleep(0.5)
        smoke.require(
            "SMOKE_CLI_VIEW_5F2" in view_text,
            "cli_view must stream the child's stdout into the pane body",
            view_text[-500:],
        )
        smoke.cli("kill-pane", view_id, "--json")

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

        # ── profiles provided by an installed plugin ──────────────────
        # The profiles migration moved the five tool layouts out of the app and
        # onto plugin repos, and the GUI lists what `gpty plugin install`
        # recorded in the store (it never parses a manifest). Running this last
        # also proves `layoutLoad` works on a plugin-sourced profile: the tile
        # below is a plain terminal, so activation starts a pane rather than
        # asking for trust in a dialog nobody can answer here.
        smoke.enter("plugin-provided profile")
        names = smoke.result(smoke.cli("layout", "list", "--json"), "layout list").get(
            "layouts", []
        )
        smoke.require(
            smoke.PLUGIN_PROFILE in names,
            "the installed plugin's profile must be listed",
            names,
        )
        smoke.result(
            smoke.cli("layout", "load", smoke.PLUGIN_PROFILE, "--json"), "layout load"
        )
        panes = smoke.result(smoke.cli("list-panes", "--json"), "list-panes").get(
            "panes", []
        )
        smoke.require(
            any(p.get("id") == smoke.PLUGIN_TILE_ID for p in panes),
            "the plugin profile's tile must be the pane that exists",
            panes,
        )

        # ── plugin admin notice ───────────────────────────────────────
        # The other half of the store's read path: `gpty plugin uninstall`
        # rewrites it while the GUI is running, and the notification the CLI
        # fires afterwards is what makes the row leave the list without a
        # restart (before that, a running GUI read the store only at launch
        # and after an install review, so `disable` looked like it did
        # nothing). The answer to the notification is sent after the refresh,
        # so the next `layout list` must already be missing the profile.
        smoke.enter("plugin admin notice")
        # `plugin` prints its payload directly (no RPC envelope) — unlike the
        # pane-API commands, which answer with one.
        removed = smoke.cli("plugin", "uninstall", smoke.PLUGIN_ID, "--json")
        smoke.require(
            removed.get("removed") is True,
            "uninstall must report the record removed",
            removed,
        )
        names = smoke.result(smoke.cli("layout", "list", "--json"), "layout list").get(
            "layouts", []
        )
        smoke.require(
            smoke.PLUGIN_PROFILE not in names,
            "a running GUI must drop an uninstalled plugin's profile",
            names,
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
