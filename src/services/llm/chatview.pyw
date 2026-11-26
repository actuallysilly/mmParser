"""
llm/chatview.pyw — what's on screen, as the model sees it.

A debugging window. It does no OCR of its own in live mode: it renders
userdata\\chat_now.json — the exact file suggest.py reads — so what you see is
what the model gets, not a second opinion from a second read.

    ┌ status ────────────────────────────────────────────────────────────────┐
    │ IN SYNC / STALE / reader not running · read 3s ago in 1840ms · title   │
    ├ real ─────┬ THE CHAT, AS READ ────────────────────────┬ sidebar ───────┤
    │ the pane, │ every turn as an Infloww-style bubble:    │ fan keywords   │
    │ a fresh   │ fan left #262626, her right #353535,      │ last           │
    │ capture,  │ numbered, flags as tags, photos cropped   │ suggestions,   │
    │ boxes     │ from the capture                          │ graded 1-5     │
    │ outlined  ├ as the model sees it ─────────────────────┤                │
    │           │ as_prompt_text(turns) + fan keywords      │                │
    └───────────┴───────────────────────────────────────────┴────────────────┘

The chat in the middle is the point of the window. Click the real pane, or any
bubble, to open it in a zoom window (wheel zooms at the pointer, drag pans,
double-click fits); the pane one follows the live capture. Photos in the chat
are cropped from the capture only while the read matches the screen — a stale
read's boxes would crop the wrong thing.

The sidebar shows the fan keywords for the chat on
screen (the words suggest.py tells her to mirror) and the last suggestion run
(userdata\\suggest_last.json): its settings, its keywords, and each draft with
1-5 buttons. A grade is appended to userdata\\suggest_ratings.jsonl WITH the chat
and settings it was made for, so the log stands on its own once the next run
replaces suggest_last.json. The suggestion window logs which draft you picked
to the same file. Grade freely; regrading a draft just adds a newer line.

The sync light is suggest.py's own staleness test (thumb of the file vs thumb of
a capture taken now), so "STALE" here means "a suggestion pressed now would
wait for the reader". The outlines are drawn from the file's boxes onto the
fresh capture: when they sit on the bubbles, the read is of THIS screen.

Capturing is PrintWindow (~40ms, never takes focus) once a second — the same
read-only call the chat reader polls with.

    pythonw chatview.pyw                live, follows chat_now.json
    pythonw chatview.pyw --image X.png  offline: OCR a saved capture and show it

"Read now" OCRs the screen in this process (does not write chat_now.json).
"Save frame" dumps the capture + what was read to debuglogs\\, so a misread can
be reproduced later with `transcript.py --image`.
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import tkinter as tk
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np                                # noqa: E402
from PIL import Image, ImageDraw, ImageTk         # noqa: E402

import chatreader as CR                           # noqa: E402
import transcript as T                            # noqa: E402

DEBUGLOGS = CR.MMA_ROOT / "debuglogs"
# Written by suggest.py; same paths as its LAST / RATINGS (not imported from it,
# so the viewer opens even when the LLM client cannot load).
SUGG_LAST = CR.MMA_ROOT / "userdata" / "suggest_last.json"
RATINGS = CR.MMA_ROOT / "userdata" / "suggest_ratings.jsonl"
SIDE_BG = "#151515"

POLL_MS = 1000

# Infloww's own colours (transcript.py / UI-ELEMENT-MAP.md).
PANE_BG = "#1b1b1b"
FAN_BG = "#262626"
MODEL_BG = "#353535"
INK = "#d9d9d9"
DIM = "#8a8a8a"
FAN_LINE = (90, 200, 120)     # outline colours on the capture
MODEL_LINE = (90, 160, 255)
OK, WARN, BAD = "#3fa65a", "#c9952b", "#c64a4a"


def fan_keywords(turns) -> list[str]:
    """What suggest.py tells the model to mirror. Optional: suggest imports the
    LLM client, and a viewer must still open when that is broken."""
    try:
        import suggest
        return suggest.fan_keywords(turns)
    except Exception:
        return []


class ZoomWindow:
    """A picture you can zoom: wheel zooms at the pointer, drag pans, double-click
    fits. Renders only the visible region, so a 4x zoom of a 3000px pane costs
    the same as fitting it. `get` is called again on refresh() — the live pane
    passes a getter, a single bubble passes a constant."""

    def __init__(self, root: tk.Tk, title: str, get):
        self.get, self.img = get, get()
        self.top = tk.Toplevel(root, bg="black")
        self.top.title(title)
        self.top.geometry("900x900")
        self.c = tk.Canvas(self.top, bg="black", highlightthickness=0, cursor="fleur")
        self.c.pack(fill="both", expand=True)
        self.info = tk.Label(self.top, fg=DIM, bg="black", font=("Segoe UI", 8))
        self.info.pack(fill="x")
        self.z, self.ox, self.oy, self.fitted = 1.0, 0.0, 0.0, False
        self.moved = False                  # zoomed or panned by hand
        self.drag = None
        self.photo = None
        self.c.bind("<Configure>", lambda _e: self.render())
        self.c.bind("<MouseWheel>", self.wheel)
        self.c.bind("<ButtonPress-1>", lambda e: setattr(self, "drag", (e.x, e.y)))
        self.c.bind("<B1-Motion>", self.pan)
        self.c.bind("<Double-Button-1>", lambda _e: self.fit())

    def alive(self) -> bool:
        try:
            return bool(self.top.winfo_exists())
        except tk.TclError:
            return False

    def fit(self) -> None:
        w, h = self.c.winfo_width(), self.c.winfo_height()
        self.z = min(w / self.img.width, h / self.img.height)
        self.ox = (self.img.width - w / self.z) / 2
        self.oy = (self.img.height - h / self.z) / 2
        self.fitted, self.moved = True, False
        self.render()

    def wheel(self, e) -> None:
        nz = max(0.05, min(16.0, self.z * (1.25 if e.delta > 0 else 0.8)))
        # Keep the image point under the pointer under the pointer.
        px, py = self.ox + e.x / self.z, self.oy + e.y / self.z
        self.z, self.moved = nz, True
        self.ox, self.oy = px - e.x / nz, py - e.y / nz
        self.render()

    def pan(self, e) -> None:
        if self.drag:
            self.ox -= (e.x - self.drag[0]) / self.z
            self.oy -= (e.y - self.drag[1]) / self.z
            self.drag, self.moved = (e.x, e.y), True
            self.render()

    def refresh(self) -> None:
        new = self.get()
        if new is None:
            return
        old, self.img = self.img, new
        if old is not None and new.size != old.size:
            # The pane changes height whenever the composer does — a new line
            # typed in it pushes the pane's bottom edge up. Infloww keeps the
            # chat pinned to the bottom, so the view follows the bottom too;
            # one that was never zoomed by hand just refits.
            if not self.moved:
                self.fit()
                return
            self.oy += new.height - old.height
        self.render()

    def render(self) -> None:
        w, h = self.c.winfo_width(), self.c.winfo_height()
        if w < 2 or h < 2 or self.img is None:
            return
        if not self.fitted:
            self.fit()
            return
        box = (round(self.ox), round(self.oy),
               round(self.ox + w / self.z), round(self.oy + h / self.z))
        view = self.img.crop(box).resize(
            (w, h), Image.NEAREST if self.z >= 2 else Image.BILINEAR)
        self.photo = ImageTk.PhotoImage(view)
        self.c.delete("all")
        self.c.create_image(0, 0, image=self.photo, anchor="nw")
        self.info.configure(text=f"{self.z * 100:.0f}%  ·  wheel: zoom  ·  drag: pan  "
                                 f"·  double-click: fit")


class ChatView:
    def __init__(self, root: tk.Tk, image: str | None):
        self.root, self.image = root, image
        self.state: dict | None = None      # what is being shown
        self.source = ""                    # "chat_now.json" | "read now" | file
        self.mtime = 0.0
        self.rgb = None                     # latest capture
        self.layout = None
        self.capture_note = ""
        self.photo = None                   # keep a ref or Tk drops the image
        self.busy = False
        self.turns = []
        self.sugg: dict | None = None       # suggest_last.json
        self.sugg_mtime = 0.0
        self.grades: dict[int, int] = {}    # draft number -> grade, this run
        self.picked: set[int] = set()
        self.boxes_ok = False               # do the read's boxes fit this capture?
        self.thumbs = []                    # PhotoImage refs for the chat canvas
        self.zooms: list[ZoomWindow] = []   # open zoom windows, refreshed per tick

        root.title("What's on screen")
        root.configure(bg=PANE_BG)
        root.geometry("1600x950")

        top = tk.Frame(root, bg=PANE_BG)
        top.pack(fill="x", padx=8, pady=6)
        self.light = tk.Label(top, text="…", width=22, fg="white", bg=DIM,
                              font=("Segoe UI", 10, "bold"))
        self.light.pack(side="left")
        self.status = tk.Label(top, text="", fg=INK, bg=PANE_BG, anchor="w",
                               font=("Segoe UI", 9))
        self.status.pack(side="left", fill="x", expand=True, padx=8)
        self.ontop = tk.BooleanVar(value=False)
        tk.Checkbutton(top, text="On top", variable=self.ontop, fg=INK, bg=PANE_BG,
                       selectcolor=PANE_BG, activebackground=PANE_BG,
                       command=lambda: root.attributes("-topmost", self.ontop.get())
                       ).pack(side="right")
        for label, cmd in (("Save frame", self.save_frame),
                           ("Read now", self.read_now),
                           ("Follow file", self.follow_file)):
            tk.Button(top, text=label, command=cmd, bg=MODEL_BG, fg=INK,
                      relief="flat", padx=8).pack(side="right", padx=3)

        body = tk.PanedWindow(root, orient="horizontal", bg=PANE_BG, sashwidth=6)
        body.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        # Left: the real pane, a narrow reference strip. Click to zoom.
        left = tk.Frame(body, bg=PANE_BG)
        body.add(left, minsize=160, width=300, stretch="never")
        tk.Label(left, text="REAL PANE — click to zoom", fg=DIM, bg=PANE_BG,
                 font=("Segoe UI", 8, "bold"), anchor="w").pack(fill="x")
        self.shot = tk.Label(left, bg="black", cursor="hand2")
        self.shot.pack(fill="both", expand=True)
        self.shot.bind("<Configure>", lambda _e: self.draw_shot())
        self.shot.bind("<Button-1>", lambda _e: self.zoom_pane())

        # Centre: the reconstructed chat — the main part — and under it, the
        # transcript exactly as the model receives it.
        centre = tk.Frame(body, bg=PANE_BG)
        body.add(centre, minsize=400, width=900, stretch="always")
        self.prompt = tk.Text(centre, height=7, bg="#111111", fg=INK, relief="flat",
                              font=("Consolas", 10), wrap="word", padx=6, pady=4)
        self.prompt.pack(side="bottom", fill="x")
        tk.Label(centre, text="As the model sees it", fg=DIM, bg=PANE_BG,
                 font=("Segoe UI", 9), anchor="w").pack(side="bottom", fill="x", pady=(6, 0))
        chat = tk.Frame(centre, bg=PANE_BG)
        chat.pack(fill="both", expand=True)
        self.canvas = tk.Canvas(chat, bg=PANE_BG, highlightthickness=0)
        sb = tk.Scrollbar(chat, command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.canvas.pack(side="left", fill="both", expand=True)
        self.canvas.bind("<Configure>", lambda _e: self.draw_mock())

        # Right: a slim sidebar — keywords, then the last suggestions.
        side = tk.Frame(body, bg=SIDE_BG)
        body.add(side, minsize=220, width=320, stretch="never")
        tk.Label(side, text="FAN KEYWORDS", fg=DIM, bg=SIDE_BG,
                 font=("Segoe UI", 8, "bold"), anchor="w").pack(fill="x", padx=8, pady=(6, 2))
        self.kw_box = tk.Frame(side, bg=SIDE_BG)
        self.kw_box.pack(fill="x", padx=8)
        tk.Label(side, text="LAST SUGGESTIONS", fg=DIM, bg=SIDE_BG,
                 font=("Segoe UI", 8, "bold"), anchor="w").pack(fill="x", padx=8, pady=(12, 2))
        # Drafts run long, so the list scrolls: a frame inside a canvas.
        holder = tk.Frame(side, bg=SIDE_BG)
        holder.pack(fill="both", expand=True, padx=(8, 0))
        self.sugg_canvas = tk.Canvas(holder, bg=SIDE_BG, highlightthickness=0)
        ssb = tk.Scrollbar(holder, command=self.sugg_canvas.yview)
        self.sugg_canvas.configure(yscrollcommand=ssb.set)
        ssb.pack(side="right", fill="y")
        self.sugg_canvas.pack(side="left", fill="both", expand=True)
        self.sugg_box = tk.Frame(self.sugg_canvas, bg=SIDE_BG)
        win = self.sugg_canvas.create_window(0, 0, window=self.sugg_box, anchor="nw")
        self.sugg_canvas.bind("<Configure>", lambda e: (
            self.sugg_canvas.itemconfigure(win, width=e.width - 4), self._rewrap()))
        self.sugg_box.bind("<Configure>", lambda _e: self.sugg_canvas.configure(
            scrollregion=self.sugg_canvas.bbox("all")))
        root.bind_all("<MouseWheel>", self._wheel)

        self.load_sugg()
        if image:
            self.load_image(image)
        else:
            self.tick()

    # ------------------------------------------------------------ sources --
    def load_image(self, path: str) -> None:
        rgb = np.asarray(Image.open(path).convert("RGB"))
        self.rgb, self.layout = rgb, T.find_layout(rgb)
        t0 = time.time()
        turns = T.read_turns(rgb, self.layout)
        self.show({"read_at": time.time(), "read_ms": int((time.time() - t0) * 1000),
                   "title": Path(path).name, "turns": [t.to_dict() for t in turns],
                   "note": "", "thumb": None}, f"offline: {Path(path).name}")

    def follow_file(self) -> None:
        self.source, self.mtime = "", 0.0       # next tick reloads chat_now.json

    def read_now(self) -> None:
        if self.busy:
            return
        self.busy = True
        self.light.configure(text="READING…", bg=DIM)

        def work():
            try:
                st, note = CR.read_once(), ""
            except Exception as e:
                st, note = None, f"{e.__class__.__name__}: {e}"
            self.root.after(0, lambda: self._read_done(st, note))

        threading.Thread(target=work, daemon=True).start()

    def _read_done(self, st, note) -> None:
        self.busy = False
        if st:
            self.show(st, "read now")
        else:
            self.status.configure(text=f"read failed — {note}")

    def save_frame(self) -> None:
        if self.rgb is None:
            return
        DEBUGLOGS.mkdir(parents=True, exist_ok=True)
        stem = DEBUGLOGS / time.strftime("chatview_%Y%m%d_%H%M%S")
        Image.fromarray(self.rgb).save(stem.with_suffix(".png"))
        if self.state:
            stem.with_suffix(".json").write_text(
                json.dumps(self.state, ensure_ascii=False, indent=1), encoding="utf-8")
        self.status.configure(text=f"saved {stem.name}.png/.json — reproduce with "
                                   f"transcript.py --image")

    # --------------------------------------------------------------- loop --
    def tick(self) -> None:
        try:
            self.capture()
            if self.source in ("", "chat_now.json"):
                try:
                    m = CR.OUT.stat().st_mtime
                except OSError:
                    m = 0.0
                if m != self.mtime:
                    self.mtime = m
                    st = CR.load_state()
                    if st:
                        self.show(st, "chat_now.json")
            self.update_light()
            self.draw_shot()
            self.load_sugg()
            self.zooms = [z for z in self.zooms if z.alive()]
            for z in self.zooms:
                z.refresh()
        finally:
            self.root.after(POLL_MS, self.tick)

    def capture(self) -> None:
        try:
            self.rgb, self.layout, _ = T.capture_conversation()
            self.capture_note = ""
        except T.A.WindowNotReady as e:
            self.rgb, self.layout, self.capture_note = None, None, str(e)
        except Exception as e:
            self.rgb, self.layout = None, None
            self.capture_note = f"{e.__class__.__name__}: {e}"

    def update_light(self) -> None:
        st = self.state or {}
        if self.image:
            text, colour = "OFFLINE IMAGE", DIM
        elif self.rgb is None:
            text, colour = "NO PANE", BAD
        elif self.source == "read now":
            text, colour = "MANUAL READ", DIM
        elif not CR.running():
            text, colour = "READER NOT RUNNING", BAD
        elif not st.get("thumb"):
            text, colour = "NOTHING READ", BAD
        else:
            same = T.thumb_diff(T.pane_thumb(self.rgb, self.layout),
                                CR.thumb_from_json(st["thumb"])) <= CR.CHANGED
            text, colour = ("IN SYNC", OK) if same else ("STALE", WARN)
        self.light.configure(text=text, bg=colour)
        ok = self.rgb is not None and (bool(self.image) or text == "IN SYNC" or (
            text == "MANUAL READ" and st.get("thumb") and T.thumb_diff(
                T.pane_thumb(self.rgb, self.layout),
                CR.thumb_from_json(st["thumb"])) <= CR.CHANGED))
        if ok != self.boxes_ok:
            self.boxes_ok = ok
            self.draw_mock()                # photos appear / go back to [media]

        bits = [self.source]
        if st.get("read_at"):
            bits.append(f"read {int(time.time() - st['read_at'])}s ago"
                        + (f" in {st['read_ms']}ms" if st.get("read_ms") else ""))
        if st.get("title"):
            bits.append(repr(st["title"]))
        if st.get("note"):
            bits.append("note: " + st["note"])
        if self.capture_note and not self.image:
            bits.append("capture: " + self.capture_note)
        self.status.configure(text="  ·  ".join(b for b in bits if b))

    # ------------------------------------------------------------ drawing --
    def show(self, st: dict, source: str) -> None:
        self.state, self.source = st, source
        self.turns = [T.Turn.from_dict(d) for d in st.get("turns", [])]
        self.draw_mock()
        self.draw_shot()
        self.update_light()
        text = T.as_prompt_text(self.turns)
        kw = fan_keywords(self.turns)
        self.draw_keywords(kw)
        if kw:
            text += "\n\nFAN KEYWORDS: " + ", ".join(kw)
        if not self.turns:
            text = f"(nothing — {st.get('note') or 'no bubbles read'})"
        self.prompt.delete("1.0", "end")
        self.prompt.insert("1.0", text)

    def pane_image(self) -> Image.Image | None:
        """The real pane at full size, the read's boxes outlined and numbered."""
        if self.rgb is None or self.layout is None:
            return None
        x, y, w, h = self.layout.region
        pane = Image.fromarray(self.rgb[y:y + h, x:x + w])
        d = ImageDraw.Draw(pane)
        lw = max(2, round(2 * self.layout.scale))
        for i, t in enumerate(self.turns, 1):
            x0, y0, x1, y1 = t.box
            colour = FAN_LINE if t.who == "fan" else MODEL_LINE
            d.rectangle((x0 - x, y0 - y, x1 - x, y1 - y), outline=colour, width=lw)
            try:                                # font_size needs Pillow 10.1+
                d.text((x0 - x + 4, y0 - y + 2), str(i), fill=colour,
                       font_size=round(22 * self.layout.scale))
            except TypeError:
                d.text((x0 - x + 4, y0 - y + 2), str(i), fill=colour)
        return pane

    def draw_shot(self) -> None:
        pane = self.pane_image()
        if pane is None:
            self.shot.configure(image="", text=self.capture_note or "no capture",
                                fg=INK, wraplength=260)
            return
        bw, bh = max(self.shot.winfo_width(), 50), max(self.shot.winfo_height(), 50)
        k = min(bw / pane.width, bh / pane.height)
        pane = pane.resize((max(1, int(pane.width * k)), max(1, int(pane.height * k))),
                           Image.LANCZOS)
        self.photo = ImageTk.PhotoImage(pane)
        self.shot.configure(image=self.photo, text="")

    def bubble_image(self, t) -> Image.Image | None:
        """The real bubble, cropped from the capture — only if the boxes fit it."""
        if not self.boxes_ok or self.rgb is None:
            return None
        x0, y0, x1, y1 = t.box
        if x1 <= x0 or y1 <= y0:
            return None
        return Image.fromarray(self.rgb[y0:y1 + 1, x0:x1 + 1])

    def zoom_pane(self) -> None:
        if self.pane_image() is not None:
            self.zooms.append(ZoomWindow(self.root, "Real pane (live)", self.pane_image))

    def zoom_bubble(self, i: int) -> None:
        t = self.turns[i - 1]
        img = self.bubble_image(t)
        if img is None:
            self.status.configure(text="can't zoom: the read no longer matches the "
                                       "screen (STALE) — press Read now")
            return
        label = t.text[:40] if t.text else "media"
        self.zooms.append(ZoomWindow(self.root, f"#{i} {t.who}: {label}", lambda: img))

    def draw_mock(self) -> None:
        c = self.canvas
        c.delete("all")
        self.thumbs = []
        W = max(c.winfo_width(), 300)
        maxw = int(W * 0.62)
        y = 14
        for i, t in enumerate(self.turns, 1):
            fan = t.who == "fan"
            tags = []
            if t.partial:
                tags.append("PARTIAL (cut at top)")
            if t.cut:
                tags.append("CUT (under composer)")
            if t.is_media:
                tags.append("MEDIA — model sees only [media]")
            if t.repaired:
                tags.append(f"repaired {t.repaired}")
            meta = f"#{i} {'fan' if fan else 'her'}" + (
                "  ·  " + "  ·  ".join(tags) if tags else "")
            tag = f"b{i}"                      # click anything in the bubble to zoom

            m = c.create_text(0, y, text=meta, fill=WARN if tags else DIM,
                              font=("Segoe UI", 9), anchor="nw", tags=tag)
            mb = c.bbox(m)
            c.move(m, 20 if fan else W - 20 - (mb[2] - mb[0]), 0)
            y = mb[3] + 3

            items = []
            ty = y + 10
            if t.reply_to:
                q = c.create_text(0, ty, text="↪ " + t.reply_to, fill=DIM, width=maxw - 28,
                                  font=("Segoe UI", 10, "italic"), anchor="nw", tags=tag)
                items.append(q)
                ty = c.bbox(q)[3] + 6
            img = self.bubble_image(t) if t.is_media else None
            if img is not None:
                k = min((maxw - 28) / img.width, 340 / img.height, 1.5)
                img = img.resize((max(1, int(img.width * k)), max(1, int(img.height * k))),
                                 Image.LANCZOS)
                ph = ImageTk.PhotoImage(img)
                self.thumbs.append(ph)
                items.append(c.create_image(0, ty, image=ph, anchor="nw", tags=tag))
            else:
                body = t.text or "[media]"
                items.append(c.create_text(0, ty, text=body, fill=INK if t.text else DIM,
                                           width=maxw - 28, font=("Segoe UI", 12),
                                           anchor="nw", tags=tag))
            boxes = [c.bbox(it) for it in items]
            tw = max(bx[2] - bx[0] for bx in boxes)
            bottom = max(bx[3] for bx in boxes) + 10
            left = 20 if fan else W - 20 - tw - 28
            for it in items:
                c.move(it, left + 14, 0)
            r = c.create_rectangle(left, y, left + tw + 28, bottom,
                                   fill=FAN_BG if fan else MODEL_BG, tags=tag,
                                   outline=WARN if (t.partial or t.cut) else "")
            c.tag_lower(r)
            c.tag_bind(tag, "<Button-1>", lambda _e, i=i: self.zoom_bubble(i))
            c.tag_bind(tag, "<Enter>", lambda _e: c.configure(cursor="hand2"))
            c.tag_bind(tag, "<Leave>", lambda _e: c.configure(cursor=""))
            y = bottom + 16
        c.configure(scrollregion=(0, 0, W, y))
        # After layout, or the newest bubble lands under the bottom edge.
        c.after_idle(lambda: c.yview_moveto(1.0))   # newest, like Infloww

    def _wheel(self, e) -> None:
        """Scroll whichever column the pointer is over, even above a child."""
        w = self.root.winfo_containing(e.x_root, e.y_root)
        while w is not None:
            if w in (self.canvas, self.sugg_canvas):
                w.yview_scroll(-1 if e.delta > 0 else 1, "units")
                return
            w = w.master

    # ------------------------------------------------ keywords & grading --
    def draw_keywords(self, kw: list[str]) -> None:
        for w in self.kw_box.winfo_children():
            w.destroy()
        if not kw:
            tk.Label(self.kw_box, text="(none — no fan text in view)", fg=DIM,
                     bg=SIDE_BG, font=("Segoe UI", 9)).pack(anchor="w")
            return
        for w in kw:
            tk.Label(self.kw_box, text=w, fg=INK, bg=FAN_BG, padx=6, pady=2,
                     font=("Segoe UI", 10)).pack(side="left", padx=(0, 4), pady=2)

    def load_sugg(self) -> None:
        try:
            m = SUGG_LAST.stat().st_mtime
        except OSError:
            m = 0.0
        if m == self.sugg_mtime and self.sugg_box.winfo_children():
            return
        self.sugg_mtime = m
        try:
            self.sugg = json.loads(SUGG_LAST.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.sugg = None
        self.grades, self.picked = {}, set()
        if self.sugg:
            self._load_grades(self.sugg.get("id", ""))
        self.draw_sugg()

    def _load_grades(self, run_id: str) -> None:
        """Latest grade per draft for this run, plus any picks."""
        try:
            lines = RATINGS.read_text(encoding="utf-8-sig").splitlines()
        except OSError:
            return
        for line in lines:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("id") != run_id:
                continue
            n = int(r.get("n", 0))
            if r.get("grade"):
                self.grades[n] = int(r["grade"])
            if r.get("picked"):
                self.picked.add(n)

    def grade(self, n: int, g: int) -> None:
        s = self.sugg or {}
        sugg, flags = s.get("suggestions", []), s.get("flags") or []
        ctxs = s.get("contexts") or []
        rec = {"id": s.get("id", ""), "n": n, "grade": g, "at": time.time(),
               "text": sugg[n - 1] if n <= len(sugg) else "",
               "flags": flags[n - 1] if n <= len(flags) else [],
               "model": s.get("model", ""), "mode": s.get("mode", ""),
               "tier": s.get("tier", 0), "content": s.get("content", ""),
               "direction": s.get("direction", ""), "keywords": s.get("keywords", []),
               "chat": s.get("chat", ""),
               # Exactly what the model was given for this draft (suggest.contexts).
               "context": ctxs[n - 1] if n <= len(ctxs) else None}
        RATINGS.parent.mkdir(parents=True, exist_ok=True)
        with RATINGS.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.grades[n] = g
        self.draw_sugg()

    def draw_sugg(self) -> None:
        box = self.sugg_box
        for w in box.winfo_children():
            w.destroy()
        s = self.sugg
        if not s or not s.get("suggestions"):
            tk.Label(box, text="(no suggestion run yet — press the suggest key)",
                     fg=DIM, bg=SIDE_BG, font=("Segoe UI", 9)).pack(anchor="w")
            return
        age = int(time.time() - s.get("at", time.time()))
        age_s = f"{age}s" if age < 120 else f"{age // 60}m"
        head = (f"{age_s} ago · {s.get('model', '?')} · {s.get('mode', '?')} · "
                f"tier {s.get('tier', 0)} ({s.get('tier_name', '')}) · "
                f"{s.get('gen_ms', 0) / 1000:.1f}s")
        tk.Label(box, text=head, fg=DIM, bg=SIDE_BG, font=("Segoe UI", 8),
                 anchor="w", justify="left").pack(fill="x")
        for label, val in (("direction", s.get("direction")), ("content", s.get("content")),
                           ("keywords then", ", ".join(s.get("keywords") or []))):
            if val:
                tk.Label(box, text=f"{label}: {val}", fg=DIM, bg=SIDE_BG,
                         font=("Segoe UI", 8), anchor="w", justify="left").pack(fill="x")
        kw = [k.lower() for k in s.get("keywords") or []]
        flags = s.get("flags") or []
        for n, text in enumerate(s["suggestions"], 1):
            card = tk.Frame(box, bg=MODEL_BG)
            card.pack(fill="x", pady=(8, 0))
            meta = f"#{n}" + ("  ·  PICKED" if n in self.picked else "")
            if kw:
                used = [k for k in kw if k in text.lower()]
                meta += f"  ·  mirrors {len(used)}/{len(kw)}"
            f = flags[n - 1] if n <= len(flags) else []
            if f:
                meta += "  ·  ⚠ " + ", ".join(f)
            tk.Label(card, text=meta, fg=WARN if f else DIM, bg=MODEL_BG,
                     font=("Segoe UI", 8), anchor="w").pack(fill="x", padx=8, pady=(4, 0))
            tk.Label(card, text=text, fg=INK, bg=MODEL_BG, font=("Segoe UI", 10),
                     anchor="w", justify="left", wraplength=300
                     ).pack(fill="x", padx=8, pady=2)
            row = tk.Frame(card, bg=MODEL_BG)
            row.pack(anchor="e", padx=8, pady=(0, 6))
            for g in range(1, 6):
                on = self.grades.get(n) == g
                tk.Button(row, text=str(g), width=2, relief="flat",
                          bg=OK if on else "#444444", fg="white",
                          command=lambda n=n, g=g: self.grade(n, g)
                          ).pack(side="left", padx=1)
        self._rewrap()

    def _rewrap(self, _e=None) -> None:
        """Wrap draft text to the column; Tk will not do it by itself."""
        # The canvas, not the frame: the frame's width lags until it is laid out.
        w = max(self.sugg_canvas.winfo_width() - 4, 150)
        for child in self.sugg_box.winfo_children():
            if isinstance(child, tk.Label):        # the run's header lines
                child.configure(wraplength=w - 8)
            for lab in child.winfo_children():     # a draft card: 2x 8px padding
                if isinstance(lab, tk.Label):
                    lab.configure(wraplength=w - 24)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="What's on screen, as the model sees it")
    ap.add_argument("--image", help="OCR a saved capture instead of following the reader")
    a = ap.parse_args(argv)
    T.A.set_dpi_aware()
    root = tk.Tk()
    ChatView(root, a.image)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
