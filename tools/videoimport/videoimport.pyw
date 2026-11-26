"""
Video Import — pick an Infloww screen recording and turn it into chats.

A small window over src/services/llm/video2chat.py, which does the work:

    Video     the recording (OBS, a recorded Discord stream, anything showing Infloww)
    Account   the creator it belongs to (blank = the file's name)
    Save / One-time view
        Save           into the real shift log (userdata/shiftlog), exactly as
                       `video2chat.py VIDEO` does; open it in the Fan Viewer with
                       Source: shift log.
        One-time view  into a temp folder; a Fan Viewer opens on just that video
                       and the folder is deleted when that viewer closes.
                       Nothing reaches the shift log or the fan files.

The converter runs as its own process (console python, no window) and its output
streams into the log box. Cancel kills it; a cancelled one-time run is deleted.

THE TITLE MUST NEVER CONTAIN "Infloww Messages" (the chat reader records any
window with that in its title). Local only: the output is real chats.

    pythonw videoimport.pyw
    runner.pyw --start videoimport   how MMA's Tools window opens it
"""
from __future__ import annotations

import ctypes
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

HERE = Path(__file__).resolve().parent
MMA_ROOT = HERE.parents[1]
VIDEO2CHAT = MMA_ROOT / "src" / "services" / "llm" / "video2chat.py"
VIEWER = MMA_ROOT / "tools" / "shiftview" / "shiftview.pyw"

TITLE = "MMA Video Import"
MUTEX = "Global\\MMA.videoimport.mutex"
TEMP_BASE = Path(tempfile.gettempdir()) / "mma-onetime"
TEMP_MARK = ".mma-onetime"          # shiftview.pyw deletes only folders carrying this
STALE_S = 24 * 3600                 # a one-time folder older than this was orphaned
NO_WINDOW = 0x08000000              # CREATE_NO_WINDOW


def log(msg: str) -> None:
    try:
        f = MMA_ROOT / "debuglogs" / "error_log.txt"
        f.parent.mkdir(exist_ok=True)
        with f.open("a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [videoimport] {msg}\n")
    except OSError:
        pass


def console_python() -> str:
    """python.exe beside the interpreter running us: its stdout is what we read."""
    exe = Path(sys.executable)
    c = exe.with_name("python.exe")
    return str(c if c.exists() else exe)


def windowed_python() -> str:
    exe = Path(sys.executable)
    w = exe.with_name("pythonw.exe")
    return str(w if w.exists() else exe)


def sweep_stale() -> None:
    """Delete one-time folders whose viewer never cleaned up (a crash, a kill)."""
    if not TEMP_BASE.exists():
        return
    for d in TEMP_BASE.iterdir():
        try:
            m = d / TEMP_MARK
            if m.exists() and time.time() - m.stat().st_mtime > STALE_S:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.proc: subprocess.Popen | None = None
        self.lines: queue.Queue = queue.Queue()
        self.temp: Path | None = None
        self.started = 0.0

        root.title(TITLE)
        root.geometry("720x480")
        root.minsize(560, 360)
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        f = ttk.Frame(root, padding=12)
        f.pack(fill="both", expand=True)
        f.columnconfigure(1, weight=1)

        ttk.Label(f, text="Video").grid(row=0, column=0, sticky="w")
        self.video = tk.StringVar()
        ttk.Entry(f, textvariable=self.video).grid(row=0, column=1, sticky="ew", padx=6)
        self.browse = ttk.Button(f, text="Browse…", command=self.pick)
        self.browse.grid(row=0, column=2)

        ttk.Label(f, text="Account").grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.account = tk.StringVar()
        ttk.Entry(f, textvariable=self.account).grid(row=1, column=1, sticky="ew", padx=6, pady=(8, 0))
        ttk.Label(f, text="blank = the file's name", foreground="#777").grid(
            row=1, column=2, sticky="w", pady=(8, 0))

        self.mode = tk.StringVar(value="once")
        m = ttk.Frame(f)
        m.grid(row=2, column=0, columnspan=3, sticky="w", pady=(10, 0))
        ttk.Radiobutton(m, text="One-time view (deleted when the viewer closes)",
                        variable=self.mode, value="once").pack(side="left")
        ttk.Radiobutton(m, text="Save to the shift log", variable=self.mode,
                        value="save").pack(side="left", padx=(16, 0))

        b = ttk.Frame(f)
        b.grid(row=3, column=0, columnspan=3, sticky="w", pady=(10, 6))
        self.go = ttk.Button(b, text="Convert", command=self.start)
        self.go.pack(side="left")
        self.stop = ttk.Button(b, text="Cancel", command=self.cancel, state="disabled")
        self.stop.pack(side="left", padx=8)
        self.status = tk.StringVar(value="Pick a recording.")
        ttk.Label(b, textvariable=self.status).pack(side="left", padx=8)

        self.out = tk.Text(f, height=14, wrap="none", font=("Consolas", 9),
                           background="#151515", foreground="#ddd", insertbackground="#ddd")
        self.out.grid(row=4, column=0, columnspan=3, sticky="nsew")
        f.rowconfigure(4, weight=1)
        self.out.configure(state="disabled")

        root.after(200, self.pump)

    # ── input ────────────────────────────────────────────────────────────
    def pick(self):
        p = filedialog.askopenfilename(
            title="Pick an Infloww recording",
            initialdir=r"D:\ShiftRecordings" if Path(r"D:\ShiftRecordings").exists() else None,
            filetypes=[("Videos", "*.mp4 *.mkv *.mov *.webm *.avi *.flv *.ts"), ("All files", "*.*")])
        if p:
            self.video.set(p)

    def write(self, s: str):
        self.out.configure(state="normal")
        self.out.insert("end", s)
        self.out.see("end")
        self.out.configure(state="disabled")

    # ── run ──────────────────────────────────────────────────────────────
    def start(self):
        video = Path(self.video.get().strip().strip('"'))
        if not video.is_file():
            messagebox.showerror(TITLE, "That video file does not exist.", parent=self.root)
            return
        save = self.mode.get() == "save"
        if save and not messagebox.askokcancel(
                TITLE, "Save into the real shift log?\n\nIt rebuilds the shift log's chats at the end, "
                       "so do not run it while the chat reader is recording a shift.\n"
                       "Converting the same video again replaces its earlier reads.",
                parent=self.root):
            return
        env = dict(os.environ)
        if save:
            self.temp = None
        else:
            stem = re.sub(r"[^\w.-]+", "_", video.stem)[:40]
            self.temp = TEMP_BASE / f"{stem}-{time.strftime('%H%M%S')}"
            self.temp.mkdir(parents=True, exist_ok=True)
            (self.temp / TEMP_MARK).write_text(str(video), encoding="utf-8")
            env["MMA_SHIFTLOG_ROOT"] = str(self.temp)
        env["PYTHONIOENCODING"] = "utf-8"
        cmd = [console_python(), "-u", str(VIDEO2CHAT), str(video)]
        if self.account.get().strip():
            cmd += ["--account", self.account.get().strip()]
        self.out.configure(state="normal")
        self.out.delete("1.0", "end")
        self.out.configure(state="disabled")
        self.write(f"{'Saving' if save else 'One-time view of'} {video.name}\n")
        try:
            self.proc = subprocess.Popen(cmd, cwd=str(VIDEO2CHAT.parent), env=env,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
        except OSError as e:
            self.write(f"could not start the converter: {e}\n")
            self.drop_temp()
            return
        log(f"converting {video} ({'save' if save else 'one-time'})")
        self.started = time.time()
        self.set_busy(True)
        threading.Thread(target=self.reader, args=(self.proc,), daemon=True).start()

    def reader(self, proc: subprocess.Popen):
        for raw in proc.stdout:
            self.lines.put(raw.decode("utf-8", "replace"))
        proc.wait()
        self.lines.put(None)                      # finished

    def pump(self):
        try:
            while True:
                s = self.lines.get_nowait()
                if s is None:
                    self.finished()
                else:
                    self.write(s)
        except queue.Empty:
            pass
        if self.proc is not None:
            self.status.set(f"Converting… {(time.time() - self.started) / 60:.1f} min")
        self.root.after(200, self.pump)

    def finished(self):
        proc, self.proc = self.proc, None
        self.set_busy(False)
        if proc is None:                          # cancelled: already handled
            return
        if proc.returncode != 0:
            self.status.set(f"Failed (exit {proc.returncode}) — see the log above.")
            log(f"video2chat exited {proc.returncode}")
            self.drop_temp()
            return
        if self.temp is not None:
            self.status.set("Done — opening the one-time view.")
            self.open_viewer(["--temp", str(self.temp)])
            self.temp = None                      # the viewer owns it now
        else:
            self.status.set("Saved. Fan Viewer ▸ Source: shift log shows it.")
            self.open_viewer(["--shift"])

    def open_viewer(self, args: list[str]):
        # Normal window style: pywebview's first window opens invisible under a
        # hidden STARTUPINFO (see shiftview's runner entry, show=1).
        try:
            subprocess.Popen([windowed_python(), str(VIEWER), *args], cwd=str(VIEWER.parent))
        except OSError as e:
            self.write(f"could not open the viewer: {e}\n")
            self.drop_temp()

    def cancel(self):
        proc, self.proc = self.proc, None
        if proc is not None and proc.poll() is None:
            proc.kill()
        self.set_busy(False)
        self.drop_temp()
        self.status.set("Cancelled." + ("" if self.mode.get() == "once" else
                                        " The reads so far stay in the shift log."))

    def drop_temp(self):
        if self.temp is not None:
            shutil.rmtree(self.temp, ignore_errors=True)
            self.temp = None

    def set_busy(self, busy: bool):
        self.go.configure(state="disabled" if busy else "normal")
        self.browse.configure(state="disabled" if busy else "normal")
        self.stop.configure(state="normal" if busy else "disabled")

    def on_close(self):
        if self.proc is not None:
            if not messagebox.askyesno(TITLE, "A conversion is running. Stop it and close?",
                                       parent=self.root):
                return
            self.cancel()
        self.root.destroy()


def main() -> int:
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW(None, False, MUTEX)
    if k32.GetLastError() == 183:                # already open
        return 0
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass
    sweep_stale()
    root = tk.Tk()
    App(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
