"""MMA runner — the one windowless Python process that starts every Python tool.

MMA used to start each tool through its own .vbs, and every .vbs found Python with
`shell.Exec("cmd /c where pythonw.exe")`. WScript's Exec ALWAYS opens a console, so
startup flashed one console window per service, sometimes two. MMA now starts this
file once (pythonw, hidden) and asks it, over a named pipe, to start and stop tools.

What it does
  * Starts each tool as its own pythonw child with CREATE_NO_WINDOW. Every tool is a
    PROCESS, never a thread: three of them set process-wide DPI awareness while the
    chat reader depends on NOT having it, autoword runs on a different interpreter
    (its .venv), two run Tk event loops, and module names collide across folders
    (llm/reword.py vs autoword/reword.py).
  * Services sit in a Job Object with KILL_ON_JOB_CLOSE: if this process dies, so
    do they. The GUI tools (TestFlow, Shift Viewer, ...) do not. They are windows the
    user opened, and they outlive MMA exactly as they did when a .vbs started them.
  * Restarts a service that exits while it is wanted, with exponential backoff
    (1s doubling to 60s), and resets the backoff after 60s of stable uptime.
  * Stops a service the way MMA always has: it SETS THE TOOL'S OWN STOP EVENT, waits,
    and only then kills it. The tools need no changes for any of this.

Logs (all under debuglogs\\)
  runner.log          this process, rotating. Every start, exit and restart, plus the
                      tail of a tool's stderr when it exits with an error, tagged by
                      tool name.
  runner\\<tool>.log   that tool's stderr: tracebacks from before it set up its own
                      logging (a missing numpy, a syntax error). Rolled at 1 MB.

Their stdout is deliberately NOT captured. The services decide they are headless by
checking `sys.stdout is None` (that is what pythonw gives them) and then send their
lines to error_log.txt. A captured stdout would silently move those lines out of
error_log.txt, so `--child` below hands each tool a None stdout, as pythonw did.

Control pipe  \\\\.\\pipe\\MMA.runner, one line in, one line out:
  status | start <tool> | stop <tool> | restart <tool> | quit
The host side is src\\core\\runner.ahk.

Command line
  runner.pyw                 run the supervisor (single instance; a second exits)
  runner.pyw --start TOOL    ask the running runner; with none running, a GUI tool
                             is started directly (desktop shortcuts use this)
  runner.pyw --status / --stop TOOL / --restart TOOL / --quit
  runner.pyw --child SCRIPT [ARGS...]   internal: how each tool is started
"""
from __future__ import annotations

import sys


def run_child(script: str, args: list[str]) -> None:
    """Become `script`, exactly as if pythonw had been pointed at it.

    Done first and with nothing else imported, so a tool starts in a process that
    looks like the one its .vbs used to give it: its own folder at sys.path[0], its
    own argv, and no stdout (see the docstring: the headless checks depend on it).
    stderr stays the per-tool log the runner opened."""
    import runpy
    from pathlib import Path

    script = str(Path(script).resolve())
    sys.argv = [script, *args]
    sys.path[0] = str(Path(script).parent)
    sys.stdout = None
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__" and len(sys.argv) >= 3 and sys.argv[1] == "--child":
    run_child(sys.argv[2], sys.argv[3:])
    sys.exit(0)


import argparse                                                     # noqa: E402
import ctypes                                                       # noqa: E402
import json                                                         # noqa: E402
import logging                                                      # noqa: E402
import logging.handlers                                             # noqa: E402
import os                                                           # noqa: E402
import subprocess                                                   # noqa: E402
import threading                                                    # noqa: E402
import time                                                         # noqa: E402
from ctypes import wintypes                                         # noqa: E402
from dataclasses import dataclass, field                            # noqa: E402
from pathlib import Path                                            # noqa: E402

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[2]                       # src\services\runner -> MMA
LOG_DIR = MMA_ROOT / "debuglogs"
TOOL_LOG_DIR = LOG_DIR / "runner"

PIPE_NAME = r"\\.\pipe\MMA.runner"
MUTEX_NAME = "Global\\MMA.runner.mutex"

STOP_GRACE_S = 5.0          # after setting a tool's stop event, before killing it
BACKOFF_FIRST_S = 1.0
BACKOFF_MAX_S = 60.0
STABLE_S = 60.0             # uptime that counts as "it was fine", resetting backoff
TICK_S = 0.5
TOOL_LOG_MAX = 1_000_000


# ─── the registry ─────────────────────────────────────────────────────────────
#  Names of services are MMA's SVC ids (core\processes.ahk), so the host can say
#  "start <id>" without a lookup table. services_test.ahk checks they match.

@dataclass(frozen=True)
class Tool:
    name: str
    script: str                     # relative to the MMA folder
    args: tuple = ()
    stop_event: str = ""            # the tool's own named event: set = please exit
    restart: str = "always"         # "always": a service, supervised, in the job
                                    # "never":  a GUI the user opened; left alone
    venv: str = ""                  # a venv whose pythonw wins when it exists
    show: int = 0                   # the window style its .vbs passed (0 hidden,
                                    # 1 normal). Windows applies it to the tool's
                                    # FIRST window, so it is carried over exactly:
                                    # Shift Viewer's pywebview window opened
                                    # invisible under 0, which is why it had 1.

    @property
    def service(self) -> bool:
        return self.restart == "always"


TOOLS = [
    # services: MMA starts and stops these from Settings ▸ Features
    Tool("automation", r"src\services\automation\automation.py", ("--listen",),
         "Global\\MMA.automation.listener.stop"),
    # which Infloww window is which + where everything is in each (layout-layer.html)
    Tool("screenMap", r"src\services\screenmap\screenmap.pyw", ("--listen",),
         "Global\\MMA.screenmap.stop"),
    Tool("pinger", r"src\services\pinger\pinger.pyw", ("--listen",),
         "Global\\MMA.pinger.stop"),
    Tool("typelog", r"src\services\typelog\typelog.pyw", ("--listen",),
         "Global\\MMA.typelog.stop"),
    # Its .venv holds the CUDA torch the LM predictor needs; no .venv = system Python
    # and the n-gram, exactly as autoword_start.vbs chose.
    Tool("autoword", r"src\services\autoword\autoword.pyw", (),
         "Global\\MMA.autoword.stop", venv=r"src\services\autoword\.venv"),
    Tool("chatReader", r"src\services\llm\chatreader.pyw", ("--listen",),
         "Global\\MMA.chatreader.stop"),

    # GUI tools: opened by a hotkey, the Tools window or a desktop shortcut
    Tool("testflow", r"tools\testflow\testflow.pyw", restart="never"),
    Tool("arena", r"tools\testflow\arena.pyw", restart="never"),
    Tool("livetrainer", r"tools\livetrainer\livetrainer.pyw", restart="never", show=1),
    Tool("shiftview", r"tools\shiftview\shiftview.pyw", restart="never", show=1),
    Tool("chatview", r"src\services\llm\chatview.pyw", restart="never", show=1),
    # pick a recording -> video2chat, saved or a one-time Fan Viewer
    Tool("videoimport", r"tools\videoimport\videoimport.pyw", restart="never", show=1),
    # lore_gatherer: read a fan's chat upwards in the background, keep it, brief you
    Tool("lore", r"src\services\llm\lore.pyw", restart="never"),
    # Ghost-OCR: what MMA read, drawn beside each message (toggle: run it again)
    Tool("ghost", r"src\services\ocr\ghost.pyw", restart="never"),
]
TOOLS_BY_NAME = {t.name.lower(): t for t in TOOLS}


# ─── Win32 ────────────────────────────────────────────────────────────────────

k32 = ctypes.WinDLL("kernel32", use_last_error=True)

k32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
k32.CreateMutexW.restype = wintypes.HANDLE
k32.OpenEventW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
k32.OpenEventW.restype = wintypes.HANDLE
k32.SetEvent.argtypes = [wintypes.HANDLE]
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
k32.CreateJobObjectW.restype = wintypes.HANDLE
k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                        ctypes.c_void_p, wintypes.DWORD]
k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
k32.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                 wintypes.DWORD, ctypes.c_void_p]
k32.CreateNamedPipeW.restype = wintypes.HANDLE
k32.ConnectNamedPipe.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                          ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
k32.FlushFileBuffers.argtypes = [wintypes.HANDLE]
k32.DisconnectNamedPipe.argtypes = [wintypes.HANDLE]
k32.CallNamedPipeW.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, wintypes.DWORD,
                               ctypes.c_void_p, wintypes.DWORD,
                               ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]

INVALID_HANDLE = wintypes.HANDLE(-1).value
ERROR_ALREADY_EXISTS = 183
ERROR_PIPE_CONNECTED = 535
EVENT_MODIFY_STATE = 0x0002
CREATE_NO_WINDOW = 0x08000000

PIPE_ACCESS_DUPLEX = 0x3
PIPE_TYPE_MESSAGE = 0x4
PIPE_READMODE_MESSAGE = 0x2
PIPE_REJECT_REMOTE_CLIENTS = 0x8
PIPE_UNLIMITED_INSTANCES = 255

JobObjectExtendedLimitInformation = 9
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in
                ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                 "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                ("PerJobUserTimeLimit", ctypes.c_int64),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD)]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
                ("IoInfo", IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t)]


def make_kill_job():
    """A job that kills every process in it when its last handle closes, which is
    when this process ends, however it ends."""
    job = k32.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not k32.SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                       ctypes.byref(info), ctypes.sizeof(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return job


def event_exists(name: str) -> bool:
    """Is a tool with this stop event running? The same probe MMA's SVC_Running uses."""
    if not name:
        return False
    h = k32.OpenEventW(EVENT_MODIFY_STATE, False, name)
    if not h:
        return False
    k32.CloseHandle(h)
    return True


def set_event(name: str) -> bool:
    h = k32.OpenEventW(EVENT_MODIFY_STATE, False, name) if name else None
    if not h:
        return False
    k32.SetEvent(h)
    k32.CloseHandle(h)
    return True


def call_pipe(command: str, timeout_ms: int = 3000) -> str | None:
    """Send one command to a running runner. None when there is no runner.
    "No such pipe" is retried briefly: see serve_pipe for the gap it covers."""
    data = command.encode("utf-8")
    out = ctypes.create_string_buffer(65536)
    n = wintypes.DWORD(0)
    for _ in range(10):
        if k32.CallNamedPipeW(PIPE_NAME, data, len(data), out, len(out),
                              ctypes.byref(n), timeout_ms):
            return out.raw[:n.value].decode("utf-8", "replace")
        if ctypes.get_last_error() != 2:             # ERROR_FILE_NOT_FOUND
            break
        time.sleep(0.03)
    return None


# ─── logging ──────────────────────────────────────────────────────────────────

log = logging.getLogger("runner")


class _LogWriter:
    """Stands in for stdout/stderr, which pythonw does not have."""

    def __init__(self, logger, level):
        self.logger, self.level, self._buf = logger, level, ""

    def write(self, s):
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            if line.strip():
                self.logger.log(self.level, line.rstrip())
        return len(s)

    def flush(self):
        pass


def setup_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    TOOL_LOG_DIR.mkdir(parents=True, exist_ok=True)
    h = logging.handlers.RotatingFileHandler(LOG_DIR / "runner.log", maxBytes=1_000_000,
                                             backupCount=3, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s [%(name)s] %(levelname)s %(message)s"))
    root = logging.getLogger()
    root.addHandler(h)
    root.setLevel(logging.INFO)
    sys.stdout = _LogWriter(log, logging.INFO)
    sys.stderr = _LogWriter(log, logging.ERROR)

    def thread_hook(a):
        log.error("uncaught in thread %s", a.thread.name if a.thread else "?",
                  exc_info=(a.exc_type, a.exc_value, a.exc_traceback))
    threading.excepthook = thread_hook
    sys.excepthook = lambda t, v, tb: log.error("uncaught", exc_info=(t, v, tb))


# ─── starting a tool ──────────────────────────────────────────────────────────

def interpreter_for(tool: Tool) -> str:
    """The tool's venv pythonw if it has a real one, else the one running us.

    sys.executable, not whatever is on PATH: on this machine PATH's pythonw is the
    install manager's shim, which starts the real interpreter as ITS child."""
    if tool.venv:
        cand = MMA_ROOT / tool.venv / "Scripts" / "pythonw.exe"
        if cand.is_file() and cand.stat().st_size > 0:
            return str(cand)
    exe = Path(sys.executable)
    w = exe.with_name("pythonw.exe")
    return str(w if w.is_file() else exe)


def open_tool_log(tool: Tool):
    path = TOOL_LOG_DIR / f"{tool.name}.log"
    try:
        if path.exists() and path.stat().st_size > TOOL_LOG_MAX:
            os.replace(path, path.with_suffix(".log.1"))
    except OSError:
        pass                                     # held open by a live copy: keep appending
    f = open(path, "ab")
    f.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} start\n".encode())
    f.flush()
    return f


def spawn(tool: Tool) -> subprocess.Popen:
    script = MMA_ROOT / tool.script
    if not script.is_file():
        raise FileNotFoundError(script)
    cmd = [interpreter_for(tool), str(Path(__file__).resolve()), "--child",
           str(script), *tool.args]
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = tool.show
    with open_tool_log(tool) as err:
        return subprocess.Popen(cmd, cwd=str(script.parent), stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=err,
                                creationflags=CREATE_NO_WINDOW, startupinfo=si)


def tool_log_tail(tool: Tool, lines: int = 15) -> list[str]:
    try:
        text = (TOOL_LOG_DIR / f"{tool.name}.log").read_text("utf-8", "replace")
    except OSError:
        return []
    last = text.rsplit("\n=== ", 1)[-1].splitlines()[1:]     # this run only
    return [ln for ln in last if ln.strip()][-lines:]


# ─── the supervisor ───────────────────────────────────────────────────────────

@dataclass
class Slot:
    tool: Tool
    proc: subprocess.Popen | None = None
    wanted: bool = False
    state: str = "stopped"
    started_at: float = 0.0
    next_start: float = 0.0
    backoff: float = BACKOFF_FIRST_S
    restarts: int = 0
    last_exit: int | None = None
    stopping: bool = False
    log: logging.Logger = field(default=None)

    def __post_init__(self):
        self.log = logging.getLogger(self.tool.name)

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None


class Runner:
    def __init__(self):
        self.lock = threading.RLock()
        self.job = make_kill_job()
        self.slots = {name: Slot(t) for name, t in TOOLS_BY_NAME.items()}
        self.quitting = False

    # ── lifecycle of one slot (call with the lock held) ──
    def _start_now(self, s: Slot) -> None:
        if s.tool.service and event_exists(s.tool.stop_event):
            # A copy we did not start (an old .vbs launch, or one run by hand) is up.
            # Ours would only hit its mutex and exit 1, so wait for it to go.
            if s.state != "external":
                s.log.info("already running outside the runner, waiting for it to exit")
            s.state = "external"
            s.next_start = time.monotonic() + 2
            return
        try:
            s.proc = spawn(s.tool)
        except Exception as e:
            s.log.error("could not start: %s", e)
            s.state = "failed"
            self._schedule_retry(s)
            return
        if s.tool.service:
            if not k32.AssignProcessToJobObject(self.job, int(s.proc._handle)):
                s.log.warning("not in the kill-on-close job (error %s), so it would "
                              "survive a runner crash", ctypes.get_last_error())
        s.started_at = time.monotonic()
        s.state = "running"
        s.log.info("started, pid %s", s.proc.pid)

    def _schedule_retry(self, s: Slot) -> None:
        s.next_start = time.monotonic() + s.backoff
        s.log.info("restarting in %.0fs", s.backoff)
        s.backoff = min(s.backoff * 2, BACKOFF_MAX_S)
        s.restarts += 1

    def _reap(self, s: Slot) -> None:
        code = s.proc.poll()
        uptime = time.monotonic() - s.started_at
        s.proc, s.last_exit = None, code
        if code:
            tail = tool_log_tail(s.tool)
            s.log.warning("exited with code %s after %.0fs%s", code, uptime,
                          "; its stderr:" if tail else "")
            for ln in tail:
                s.log.warning("  | %s", ln)
        else:
            s.log.info("exited cleanly after %.0fs", uptime)
        if s.wanted and s.tool.service and not self.quitting:
            if uptime >= STABLE_S:
                s.backoff = BACKOFF_FIRST_S
            s.state = "backoff"
            self._schedule_retry(s)
        else:
            s.state = "stopped"

    def tick(self) -> None:
        with self.lock:
            now = time.monotonic()
            for s in self.slots.values():
                if s.proc is not None and s.proc.poll() is not None:
                    self._reap(s)
                if (s.wanted and s.tool.service and not s.stopping and not self.quitting
                        and s.proc is None and now >= s.next_start):
                    self._start_now(s)

    def supervise(self) -> None:
        while True:
            try:
                self.tick()
            except Exception:
                log.exception("supervisor tick failed")
            time.sleep(TICK_S)

    # ── stopping ──
    def _stop_blocking(self, s: Slot) -> None:
        """Set its stop event, give it STOP_GRACE_S, then kill it."""
        with self.lock:
            s.stopping = True
            proc = s.proc
        try:
            asked = set_event(s.tool.stop_event)
            if proc is None:
                if asked:
                    s.log.info("set the stop event of a copy the runner did not start")
                return
            s.log.info("stopping pid %s%s", proc.pid, " (stop event set)" if asked else "")
            # A tool stopped right after it started may not have created its event
            # yet, so keep trying to set it for the whole grace rather than killing
            # a tool that never got the chance to exit cleanly.
            deadline = time.monotonic() + STOP_GRACE_S
            while proc.poll() is None and time.monotonic() < deadline:
                if not asked:
                    asked = set_event(s.tool.stop_event)
                try:
                    proc.wait(0.1)
                except subprocess.TimeoutExpired:
                    pass
            if proc.poll() is None:
                s.log.warning("did not exit within %.0fs%s, killing it", STOP_GRACE_S,
                              "" if asked else " (it never created its stop event)")
                proc.kill()
                try:
                    proc.wait(3)
                except subprocess.TimeoutExpired:
                    s.log.error("still alive after kill")
        finally:
            with self.lock:
                s.stopping = False
                if s.proc is not None and s.proc.poll() is not None:
                    self._reap(s)

    # ── commands ──
    def command(self, line: str) -> str:
        parts = line.strip().split()
        if not parts:
            return "err empty command"
        verb, arg = parts[0].lower(), (parts[1] if len(parts) > 1 else "")
        if verb == "status":
            return "ok " + json.dumps(self.status())
        if verb == "quit":
            threading.Thread(target=self.quit, name="quit").start()
            return "ok bye"
        if verb not in ("start", "stop", "restart"):
            return f"err unknown command {verb!r}"
        s = self.slots.get(arg.lower())
        if s is None:
            return f"err unknown tool {arg!r}"
        if verb == "start":
            return self.start(s)
        if verb == "stop":
            if not s.tool.service:
                return "err GUI tools are closed by their window"
            with self.lock:
                s.wanted = False
            threading.Thread(target=self._stop_blocking, args=(s,),
                             name=f"stop-{s.tool.name}").start()
            return "ok stopping"
        threading.Thread(target=self._restart, args=(s,),
                         name=f"restart-{s.tool.name}").start()
        return "ok restarting"

    def start(self, s: Slot) -> str:
        with self.lock:
            if self.quitting:
                return "err quitting"
            if s.alive():
                s.wanted = True
                return "ok running"
            if not s.tool.service:
                self._start_now(s)
                return "ok started" if s.alive() else "err could not start (see runner.log)"
            if s.wanted and s.state in ("backoff", "failed", "external"):
                return f"ok pending ({s.state})"      # the watchdog asking again
            s.wanted, s.backoff, s.restarts = True, BACKOFF_FIRST_S, 0
            self._start_now(s)
            return f"ok {s.state}"

    def _restart(self, s: Slot) -> None:
        with self.lock:
            s.wanted = False
        self._stop_blocking(s)
        with self.lock:
            s.wanted, s.backoff, s.next_start = True, BACKOFF_FIRST_S, 0.0
            self._start_now(s)

    def status(self) -> dict:
        with self.lock:
            now = time.monotonic()
            return {s.tool.name: {"state": s.state,
                                  "pid": s.proc.pid if s.alive() else None,
                                  "wanted": s.wanted,
                                  "uptime": round(now - s.started_at) if s.alive() else 0,
                                  "restarts": s.restarts,
                                  "last_exit": s.last_exit}
                    for s in self.slots.values()
                    if s.wanted or s.proc is not None or s.last_exit is not None}

    def quit(self) -> None:
        log.info("quit requested: stopping every service")
        with self.lock:
            self.quitting = True
            busy = [s for s in self.slots.values() if s.tool.service]
            for s in busy:
                s.wanted = False
        threads = [threading.Thread(target=self._stop_blocking, args=(s,)) for s in busy]
        for t in threads:
            t.start()
        for t in threads:
            t.join(STOP_GRACE_S + 5)
        log.info("bye")
        logging.shutdown()
        os._exit(0)          # closes the job handle, taking any straggler with it


# ─── the control pipe ─────────────────────────────────────────────────────────

PIPE_LISTENERS = 2


def serve_pipe(runner: Runner) -> None:
    """Create an instance, wait for a client, hand it to a thread, repeat.

    Between a client connecting and the next instance being created, no instance
    is listening, and a client arriving then is told the pipe does not exist
    rather than made to wait. PIPE_LISTENERS of these loops run side by side so
    that there is always another one listening, and the clients retry anyway."""
    mode = PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_REJECT_REMOTE_CLIENTS
    while True:
        h = k32.CreateNamedPipeW(PIPE_NAME, PIPE_ACCESS_DUPLEX, mode,
                                 PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, None)
        if h == INVALID_HANDLE or not h:
            log.error("CreateNamedPipe failed (error %s)", ctypes.get_last_error())
            time.sleep(1)
            continue
        if not k32.ConnectNamedPipe(h, None) and ctypes.get_last_error() != ERROR_PIPE_CONNECTED:
            k32.CloseHandle(h)
            continue
        threading.Thread(target=_serve_client, args=(runner, h), daemon=True,
                         name="pipe-client").start()


def _serve_client(runner: Runner, h) -> None:
    try:
        buf = ctypes.create_string_buffer(4096)
        n = wintypes.DWORD(0)
        if not k32.ReadFile(h, buf, len(buf), ctypes.byref(n), None):
            return
        line = buf.raw[:n.value].decode("utf-8", "replace")
        try:
            reply = runner.command(line)
        except Exception as e:
            log.exception("command %r failed", line)
            reply = f"err {e}"
        if not line.startswith("status"):
            log.info("pipe: %s -> %s", line.strip(), reply)
        data = reply.encode("utf-8")
        k32.WriteFile(h, data, len(data), ctypes.byref(n), None)
        k32.FlushFileBuffers(h)
    finally:
        k32.DisconnectNamedPipe(h)
        k32.CloseHandle(h)


# ─── entry ────────────────────────────────────────────────────────────────────

def run_supervisor() -> int:
    mutex = k32.CreateMutexW(None, False, MUTEX_NAME)
    if not mutex or ctypes.get_last_error() == ERROR_ALREADY_EXISTS:
        return 0                                  # one runner already; leave quietly
    setup_logging()
    log.info("runner up, pid %s, python %s", os.getpid(), sys.executable)
    runner = Runner()
    for i in range(PIPE_LISTENERS):
        threading.Thread(target=serve_pipe, args=(runner,), daemon=True,
                         name=f"pipe-{i}").start()
    runner.supervise()
    return 0


def start_directly(name: str) -> int:
    """No runner is up. A GUI tool can still open: started detached, which is all its
    .vbs ever did. A service cannot. Supervising it is the runner's job."""
    tool = TOOLS_BY_NAME.get(name.lower())
    if tool is None or tool.service:
        return 2
    TOOL_LOG_DIR.mkdir(parents=True, exist_ok=True)
    spawn(tool)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MMA runner")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--start", metavar="TOOL")
    g.add_argument("--stop", metavar="TOOL")
    g.add_argument("--restart", metavar="TOOL")
    g.add_argument("--status", action="store_true")
    g.add_argument("--quit", action="store_true")
    args = ap.parse_args(argv)

    if args.start:
        if call_pipe(f"start {args.start}") is not None:
            return 0
        return start_directly(args.start)
    for verb in ("stop", "restart"):
        if getattr(args, verb):
            reply = call_pipe(f"{verb} {getattr(args, verb)}")
            print(reply or "runner not running")
            return 0 if reply and reply.startswith("ok") else 1
    if args.status or args.quit:
        reply = call_pipe("status" if args.status else "quit")
        print(reply or "runner not running")
        return 0 if reply else 1
    return run_supervisor()


if __name__ == "__main__":
    sys.exit(main())
