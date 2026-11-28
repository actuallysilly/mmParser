"""
ocr/synth.py — practice pictures for the Infloww reader, with the right answer known.

Silly types nothing (OCR answers, Q10). Instead the real browser engine (Edge,
headless) draws Infloww's text in Infloww's own font (Inter, from the clone at
tools/inflowwclone/fonts) with Infloww's own sizes and colours (clone.css), at the
display scales this desk runs. Every line is then cut out with its label.

    python synth.py --out DIR --pages N [--seed S]

Each page is 3 columns x ROWS rows of one text line each. Output: DIR/*.png crops
and DIR/labels.tsv ("file<TAB>label<TAB>style<TAB>scale").

Styles (CSS px, from clone.css, measured off the live window / 1.37):
    header   fan header: note 18px/600 #fff + "(display)" 15px/400 #e6e6e6 on #151515
    list     chat-list row: name 15px/600 #fff + " @handle" 15px/400 #8f8f8f
    tab      model tab: 13.5px/700 on #2b2c30 (lit) or #0d0d0d
    bubble   chat text 15.5px #e6e6e6 on #262626 (his) / #353535 (hers)
    meta     footer 11.5px #9a9a9a, price pill 600 #fff on #ff7c71 / #2bd4ac
    spend    list spend 11px/700 #f6a04d on #262626

Labels are NFKC-normalised, so a fancy 𝓙𝓪𝓶𝓲𝓮 is LABELLED "Jamie" and the reader
learns to see through the decoration. Every emoji is labelled as one EMOJI mark.
"""
from __future__ import annotations

import argparse
import glob
import html
import json
import os
import random
import re
import string
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

import numpy as np
from PIL import Image

MMA_ROOT = Path(__file__).resolve().parents[3]
FONTS = MMA_ROOT / "tools" / "inflowwclone" / "fonts"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
EMOJI_MARK = "\u25c6"          # ◆ — one class for every emoji
ELLIPSIS = "\u2026"
PENCIL = "@@pencil@@"           # a segment drawn as Infloww's edit icon, never part of a label

ROW_H = 34                     # CSS px per text line
COL_W = 760
COLS = 3
ROWS = 70
SCALES = [1.0, 1.25, 1.367, 1.5, 1.65]

STYLES = {
    "header": {"bg": ["#151515"]},
    "list": {"bg": ["#151515", "#353535", "#2a2a2a", "#1b1b1b"]},
    "tab": {"bg": ["#2b2c30", "#303030", "#0d0d0d"]},
    "bubble": {"bg": ["#262626", "#353535"]},
    "meta": {"bg": ["#151515", "#262626", "#353535"]},
    "spend": {"bg": ["#262626"]},
}
MIX = [("header", 30), ("list", 25), ("tab", 8), ("bubble", 25), ("meta", 7), ("spend", 5)]

EMOJI = ["🔥", "😈", "💦", "🍆", "👑", "❤️", "😍", "🥵", "💋", "✨", "🙏", "😂", "🤤", "👅", "🍑",
         "💯", "⚡", "🖤", "💜", "😘", "🥺", "😏", "🌹", "⭐", "🎮", "🐍", "☠️", "💀", "🤡", "🍒"]
NOTES = ["$171", "$40", "$2.1k", "BROKE AF", "CHECK NOTES", "DNI", "DNI IF COVER", "DONT PUSH",
         "TW", "VIP", "WHALE", "OLD SPENDER", "NEW ACCOUNT", "PINNED", "no ppv", "likes feet",
         "dont pitch him", "cuck", "sub only", "EXC", "Exc till December", "silly reach out",
         "Insert name Here", "bday 12/3", "married", "PPV ONLY", "tipper", "refund risk"]
SEPS = [" | ", " - ", " ", " / ", " • ", " -- ", ": "]
MODELS = ["CIN", "HAIL", "AW", "BUT", "TAL", "PINK_VIP", "LUNA", "SOPHIE", "ALICE", "MIA", "RAE", "KAI"]


# ------------------------------------------------------------------ labels --
def is_emoji(ch: str) -> bool:
    o = ord(ch)
    return (0x1F000 <= o <= 0x1FAFF or 0x2600 <= o <= 0x27BF or 0x1F900 <= o <= 0x1F9FF
            or o in (0x2B50, 0x2764, 0x2B55))


def norm_label(s: str) -> str:
    """What a crop SHOULD read as: NFKC (fancy letters -> plain), every emoji one mark,
    variation selectors / joiners dropped."""
    s = unicodedata.normalize("NFKC", s)
    out = []
    for ch in s:
        if ch in "\ufe0f\ufe0e\u200d":
            continue
        if is_emoji(ch):
            if not out or out[-1] != EMOJI_MARK:     # a run of emoji = one mark
                out.append(EMOJI_MARK)
            continue
        out.append(ch)
    return re.sub(r" {2,}", " ", "".join(out)).strip()


# The math alphabets NFKC maps back to plain letters.
_FANCY = {
    "bold": (0x1D400, 0x1D41A), "italic": (0x1D434, 0x1D44E), "bolditalic": (0x1D468, 0x1D482),
    "script_bold": (0x1D4D0, 0x1D4EA), "fraktur_bold": (0x1D56C, 0x1D586),
    "double": (0x1D538, 0x1D552), "sans_bold": (0x1D5D4, 0x1D5EE), "mono": (0x1D670, 0x1D68A),
}
_HOLES = {0x1D455, 0x1D53A, 0x1D53F, 0x1D545, 0x1D547, 0x1D548, 0x1D549, 0x1D54A, 0x1D54B,
          0x1D54C, 0x1D54D, 0x1D54E, 0x1D54F, 0x1D550, 0x1D551}


def fancy(s: str, rnd: random.Random) -> str:
    up, lo = _FANCY[rnd.choice(list(_FANCY))]
    out = []
    for ch in s:
        if "A" <= ch <= "Z":
            cp = up + ord(ch) - 65
        elif "a" <= ch <= "z":
            cp = lo + ord(ch) - 97
        else:
            out.append(ch)
            continue
        out.append(ch if cp in _HOLES else chr(cp))
    return "".join(out)


def fullwidth(s: str) -> str:
    return "".join(chr(ord(c) + 0xFEE0) if "!" <= c <= "~" else c for c in s)


# ------------------------------------------------------------------ corpus --
class Corpus:
    """Real names, handles and chat lines from this PC (never leave it), plus
    random ones so the reader can't just memorise the real ones."""

    def __init__(self, rnd: random.Random):
        self.rnd = rnd
        self.names, self.handles, self.lines = [], [], []
        for f in glob.glob("D:/FanData/*/*/fan.json"):
            try:
                d = json.load(open(f, encoding="utf-8"))
            except Exception:
                continue
            h = d.get("handle") or ""
            if re.fullmatch(r"[a-z0-9_.]{3,40}", h):
                self.handles.append(h)
            for n in d.get("names") or []:
                n = n if isinstance(n, str) else str(n.get("name", ""))
                if 1 < len(n) < 45:
                    self.names.append(n)
        for f in glob.glob(str(MMA_ROOT / "userdata" / "shiftlog" / "chats" / "**" / "*.json"),
                           recursive=True)[:1500]:
            try:
                d = json.load(open(f, encoding="utf-8"))
            except Exception:
                continue
            for t in d.get("turns", []) if isinstance(d, dict) else []:
                txt = (t.get("text") or "").replace("\n", " ").strip()
                if 2 < len(txt):
                    self.lines.append(txt)

    def word(self) -> str:
        r = self.rnd
        k = r.random()
        if k < 0.35:
            return r.choice(["mike", "chris", "dan", "jamie", "josh", "keefe", "tx", "nick", "remy",
                             "fred", "sudo", "koji", "luisa", "arthur", "julio", "timo", "shaggy",
                             "andrew", "matthew", "edgar", "tom", "pieter", "jan", "daryen"])
        if k < 0.6:
            n = r.randint(2, 11)
            return "".join(r.choice(string.ascii_lowercase) for _ in range(n))
        if k < 0.8:
            return "".join(r.choice(string.ascii_letters + string.digits) for _ in range(r.randint(3, 12)))
        return r.choice(["xX", "Big", "Daddy", "Lil", "King", "Mr", "THE", "real"]) + \
            "".join(r.choice(string.ascii_letters + string.digits + "_") for _ in range(r.randint(2, 9)))

    def display(self) -> str:
        r = self.rnd
        if self.names and r.random() < 0.45:
            s = r.choice(self.names)
        else:
            s = self.word()
            if r.random() < 0.5:
                s = s.capitalize()
            if r.random() < 0.35:
                s += " " + self.word().capitalize()
            if r.random() < 0.15:
                s = s.upper()
        if r.random() < 0.22:
            s = fancy(s, r)
        elif r.random() < 0.03:
            s = fullwidth(s)
        if r.random() < 0.3:
            em = "".join(r.choice(EMOJI) for _ in range(r.randint(1, 3)))
            s = (em + s) if r.random() < 0.4 else (s + em) if r.random() < 0.7 else (em + s + em)
        return s

    def handle(self) -> str:
        r = self.rnd
        k = r.random()
        if self.handles and k < 0.4:
            return r.choice(self.handles)
        if k < 0.75:
            return "u" + str(r.randint(10 ** 6, 10 ** 9))
        s = self.word().lower()
        if r.random() < 0.5:
            s += str(r.randint(0, 9999))
        if r.random() < 0.2:
            s = s[:len(s) // 2] + r.choice("_.") + s[len(s) // 2:]
        return re.sub(r"[^a-z0-9_.]", "", s) or "u12345"

    def note(self) -> str:
        r = self.rnd
        parts = [self.display() if r.random() < 0.6 else self.word().capitalize()]
        for _ in range(r.choice([0, 1, 1, 2, 3])):
            parts.append(r.choice(SEPS).strip(" ") and r.choice(NOTES))
        sep = r.choice(SEPS)
        s = sep.join(p for p in parts if p)
        if r.random() < 0.15:
            s = r.choice(["$", ""]) + str(r.randint(5, 999)) + " " + s
        return s

    def chat(self) -> str:
        r = self.rnd
        if self.lines and r.random() < 0.7:
            s = r.choice(self.lines)
        else:
            s = " ".join(self.word() for _ in range(r.randint(1, 9)))
        if len(s) > 58:
            cut = s.rfind(" ", 20, 58)
            s = s[:cut if cut > 0 else 58]
        if r.random() < 0.2:
            s += " " + "".join(r.choice(EMOJI) for _ in range(r.randint(1, 3)))
        return s

    # -- one line of one style: [(text, css)], label ---------------------------
    def sample(self, style: str):
        r = self.rnd
        if style == "header":
            note = self.note() if r.random() < 0.75 else ""
            disp = self.display()
            if r.random() < 0.1:
                segs = [(disp, "font-size:18px;font-weight:600;color:#fff")]
            else:
                segs = [(note, "font-size:18px;font-weight:600;color:#fff"),
                        ("(" + disp + ")", "font-size:15px;font-weight:400;color:#e6e6e6")]
            if r.random() < 0.06:                      # chatter left it cut
                segs[0] = (segs[0][0][:max(3, len(segs[0][0]) // 2)] + ELLIPSIS, segs[0][1])
            if r.random() < 0.7:
                # Infloww's edit pencil, ~7px after the name. Drawn, never labelled:
                # the reader must learn to ignore it (on video it read as an emoji).
                segs.append((PENCIL, ""))
        elif style == "list":
            name = self.note() if r.random() < 0.5 else self.display()
            if r.random() < 0.25:
                name = name[:r.randint(4, 22)] + ELLIPSIS
            h = "@" + self.handle()
            if r.random() < 0.2:
                h = h[:r.randint(3, max(3, len(h) - 1))] + ELLIPSIS
            segs = [(name, "font-size:15px;font-weight:600;color:#fff"),
                    (" " + h, "font-size:15px;font-weight:400;color:#8f8f8f")]
        elif style == "tab":
            t = r.choice(MODELS) if r.random() < 0.5 else self.word().upper()[:9]
            col = r.choice(["#eff4ff", "#d6d9df"])
            segs = [(t, f"font-size:13.5px;font-weight:700;color:{col}")]
        elif style == "bubble":
            segs = [(self.chat(), "font-size:15.5px;font-weight:400;color:#e6e6e6")]
        elif style == "meta":
            k = r.random()
            hm = f"{r.randint(1, 12)}:{r.randint(0, 59):02d} {r.choice(['am', 'pm'])}"
            if k < 0.5:
                price = f"${r.randint(3, 199)}.{r.randint(0, 99):02d}"
                paid = r.choice(["not paid", "paid"])
                segs = [(price + " " + paid,
                         "font-size:11.5px;font-weight:600;color:#fff;background:"
                         + ("#ff7c71" if paid == "not paid" else "#2bd4ac;color:#052a21")
                         + ";padding:0 5px;border-radius:2px"),
                        (" " + hm, "font-size:11.5px;color:#9a9a9a")]
            else:
                segs = [(hm, "font-size:11.5px;color:#9a9a9a"),
                        (" " + r.choice(["Silly", "Nina PPV Technician", "Peach N", "Irelia",
                                         "RequiemN", "KZI", "Fjall"]),
                         "font-size:11.5px;color:#3b82f6")]
        else:                                          # spend
            v = r.random()
            t = (f"${r.randint(0, 999)}.{r.randint(0, 99):02d}" if v < 0.5
                 else f"${r.randint(1, 99)}.{r.randint(0, 99):02d}K" if v < 0.85 else f"${r.randint(0, 999)}")
            segs = [(t, "font-size:11px;font-weight:700;color:#f6a04d")]
        segs = [(t, c) for t, c in segs if t]
        return segs, norm_label("".join(t for t, _ in segs if t != PENCIL))


# -------------------------------------------------------------------- pages --
PENCIL_SVG = ("<svg width='14' height='14' viewBox='0 0 24 24' style='margin-left:7px;flex:none' "
              "fill='none' stroke='#9a9a9a' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'>"
              "<path d='M4 20h4L19 9l-4-4L4 16v4z'/><path d='M14 6l4 4'/></svg>")


def page_html(rows) -> str:
    css = (FONTS / "inter.css").read_text(encoding="utf-8").replace(
        "url(", "url(" + FONTS.as_uri() + "/").replace(FONTS.as_uri() + "/\"", "\"" + FONTS.as_uri() + "/")
    out = [f"<!doctype html><html><head><meta charset='utf-8'><style>{css}"
           "html,body{margin:0;background:#101010}"
           f".r{{position:absolute;height:{ROW_H}px;width:{COL_W}px;display:flex;align-items:center;"
           "white-space:nowrap;overflow:hidden;"
           "font-family:Inter,'Segoe UI',system-ui,sans-serif;-webkit-font-smoothing:antialiased;"
           "padding-left:10px;box-sizing:border-box}"
           ".r span{white-space:pre}</style></head><body>"]
    for i, (style, bg, segs, _label) in enumerate(rows):
        c, k = divmod(i, ROWS)
        spans = "".join(PENCIL_SVG if t == PENCIL else f"<span style=\"{css_}\">{html.escape(t)}</span>"
                        for t, css_ in segs)
        out.append(f"<div class='r' style='left:{c * COL_W}px;top:{k * ROW_H}px;background:{bg}'>{spans}</div>")
    out.append("</body></html>")
    return "".join(out)


def shoot(html_path: Path, png: Path, scale: float, profile: str) -> bool:
    w, h = COLS * COL_W, ROWS * ROW_H
    # --disable-lcd-text: Infloww (Electron) draws grey-edged text; headless Edge
    # otherwise uses ClearType colour fringes, and a reader trained on those
    # misread real captures (2026-11-28: 43% vs 98% on practice pictures).
    cmd = [EDGE, "--headless=new", "--disable-gpu", "--disable-lcd-text", "--hide-scrollbars", "--no-first-run",
           f"--user-data-dir={profile}", f"--window-size={w},{h}",
           f"--force-device-scale-factor={scale}", "--virtual-time-budget=4000",
           f"--screenshot={png}", html_path.as_uri()]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    return png.exists()


def crop_rows(png: Path, rows, scale: float, out: Path, stem: str, labels) -> int:
    a = np.asarray(Image.open(png).convert("RGB")).astype(np.int16)
    n = 0
    for i, (style, bg, segs, label) in enumerate(rows):
        if not label:
            continue
        c, k = divmod(i, ROWS)
        y0, y1 = round(k * ROW_H * scale), round((k + 1) * ROW_H * scale)
        x0, x1 = round(c * COL_W * scale), round((c + 1) * COL_W * scale)
        band = a[y0:y1, x0:x1]
        bgc = band[1, 1]
        ink = (np.abs(band - bgc).max(2) > 40).any(0)
        cols = np.flatnonzero(ink)
        if not len(cols):
            continue
        r = random.Random(hash((stem, i)))
        left = max(0, cols[0] - r.randint(2, 10))
        right = min(band.shape[1], cols[-1] + r.randint(3, 12))
        if right >= band.shape[1] - 2:                 # ran off the column: not a whole line
            continue
        crop = band[:, left:right].astype(np.uint8)
        name = f"{stem}_{i:03d}.png"
        Image.fromarray(crop).save(out / name)
        labels.append(f"{name}\t{label}\t{style}\t{scale}")
        n += 1
    return n


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pages", type=int, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--first", type=int, default=0, help="page number to start at (parallel runs)")
    a = ap.parse_args(argv)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(a.seed)
    corpus = Corpus(rnd)
    styles = [s for s, w in MIX for _ in range(w)]
    tmp = Path(tempfile.mkdtemp(prefix="mma_synth_"))
    profile = str(tmp / "profile")
    labels: list[str] = []
    total = 0
    for p in range(a.first, a.first + a.pages):
        rows = []
        for _ in range(COLS * ROWS):
            st = rnd.choice(styles)
            segs, label = corpus.sample(st)
            rows.append((st, rnd.choice(STYLES[st]["bg"]), segs, label))
        scale = SCALES[p % len(SCALES)]
        hp = tmp / f"p{p}.html"
        hp.write_text(page_html(rows), encoding="utf-8")
        png = tmp / f"p{p}.png"
        if not shoot(hp, png, scale, profile):
            print(f"page {p}: no screenshot", flush=True)
            continue
        total += crop_rows(png, rows, scale, out, f"p{p:05d}", labels)
        png.unlink(missing_ok=True)
        hp.unlink(missing_ok=True)
        if p % 10 == 0:
            print(f"page {p} scale {scale}: {total} crops", flush=True)
    with open(out / f"labels_{a.first:05d}.tsv", "w", encoding="utf-8") as f:
        f.write("\n".join(labels) + "\n")
    print(f"done: {total} crops in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
