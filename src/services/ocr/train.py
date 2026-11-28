"""
ocr/train.py — train the Infloww reader on synth.py's practice pictures.

Runs in the autoword venv (it holds the CUDA build of torch):
    src/services/autoword/.venv/Scripts/python.exe src/services/ocr/train.py \
        --data userdata/ocr/synth/train --val userdata/ocr/synth/val --out src/services/ocr/model

Writes model/infloww_rec.onnx + model/charset.json. reader.py runs that ONNX file
with onnxruntime on the CPU, so MMA itself never needs torch.

The network is a CRNN: a small stack of convolutions reads the picture into a row
of columns, a two-layer bidirectional LSTM reads that row left to right and back,
and CTC turns it into letters. Input is one text line, grey, 32px tall.

Half the training pictures are spoiled on purpose the way a screen RECORDING spoils
them (shrunk and blown up again, blurred, JPEG-compressed, noisy), so the same
reader works on video2chat's frames and not only on clean live captures.
"""
from __future__ import annotations

import argparse
import io
import json
import math
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageFilter
from torch.utils.data import DataLoader, Dataset

H = 32
BLANK = 0
CKPT_EVERY = 500        # steps between checkpoints (training can be stopped and resumed)


def load_labels(d: Path) -> list[tuple[Path, str, str]]:
    out = []
    for tsv in sorted(d.glob("labels_*.tsv")):
        for line in tsv.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[1]:
                out.append((d / parts[0], parts[1], parts[2]))
    return out


def to_gray(im: Image.Image) -> Image.Image:
    return im.convert("L")


def resize_h(im: Image.Image) -> Image.Image:
    w = max(8, round(im.width * H / im.height))
    return im.resize((w, H), Image.BILINEAR)


def degrade(im: Image.Image, r: random.Random) -> Image.Image:
    """Make a clean capture look like a frame of a screen recording / stream."""
    if r.random() < 0.8:
        k = r.uniform(0.45, 0.95)
        small = im.resize((max(4, round(im.width * k)), max(4, round(im.height * k))), Image.BILINEAR)
        im = small.resize(im.size, r.choice([Image.BILINEAR, Image.BICUBIC]))
    if r.random() < 0.3:
        im = im.filter(ImageFilter.GaussianBlur(r.uniform(0.3, 0.9)))
    if r.random() < 0.7:
        buf = io.BytesIO()
        im.convert("RGB").save(buf, "JPEG", quality=r.randint(25, 85))
        im = Image.open(io.BytesIO(buf.getvalue()))
    return im


class Lines(Dataset):
    def __init__(self, items, charset, train: bool):
        self.items, self.cs, self.train = items, charset, train

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        path, label, _style = self.items[i]
        r = random.Random() if self.train else random.Random(i)
        im = Image.open(path).convert("RGB")
        if self.train:
            # vertical jitter: the real line finder is never pixel-exact
            w, h = im.size
            t = r.randint(0, max(0, h // 8))
            b = h - r.randint(0, max(0, h // 8))
            l = r.randint(0, min(4, w // 10))
            im = im.crop((l, t, w, b))
            if r.random() < 0.5:
                im = degrade(im, r)
        g = np.asarray(resize_h(to_gray(im)), np.float32) / 255.0
        if self.train and r.random() < 0.3:
            g = np.clip(g * r.uniform(0.8, 1.2) + r.uniform(-0.08, 0.08), 0, 1)
        if self.train and r.random() < 0.3:
            g = np.clip(g + np.random.default_rng(r.randint(0, 1 << 30)).normal(0, 0.03, g.shape), 0, 1)
        y = [self.cs[c] for c in label if c in self.cs]
        return torch.from_numpy(g)[None], torch.tensor(y, dtype=torch.long)


def collate(batch):
    xs, ys = zip(*batch)
    # Widths rounded up to a multiple of 64: a handful of shapes instead of one per
    # batch. Every new shape made cuDNN tune and cache again until the card's
    # memory filled and training slowed to a quarter (2026-11-28).
    wmax = max(x.shape[-1] for x in xs)
    wmax = (wmax + 63) // 64 * 64
    X = torch.zeros(len(xs), 1, H, wmax)
    for i, x in enumerate(xs):
        X[i, :, :, :x.shape[-1]] = x
    widths = torch.tensor([x.shape[-1] for x in xs])
    return X, torch.cat(ys), torch.tensor([len(y) for y in ys]), widths


def block(cin, cout):
    return nn.Sequential(nn.Conv2d(cin, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(True))


class CRNN(nn.Module):
    def __init__(self, n_classes):
        super().__init__()
        self.cnn = nn.Sequential(
            # Width is halved ONCE, so every 2px of the line gets its own step.
            # Halving it twice (4px steps) left no room between thin letters:
            # "ll", "il" and spaces were dropped — 2/3 of all errors (2026-11-28).
            block(1, 64), nn.MaxPool2d(2, 2),                 # 16 x W/2
            block(64, 128), nn.MaxPool2d((2, 1), (2, 1)),     # 8 x W/2
            block(128, 256), block(256, 256), nn.MaxPool2d((2, 1), (2, 1)),   # 4
            block(256, 384), block(384, 384), nn.MaxPool2d((2, 1), (2, 1)),   # 2
            block(384, 384),
        )
        self.rnn = nn.LSTM(384, 256, num_layers=2, bidirectional=True, batch_first=True, dropout=0.1)
        self.fc = nn.Linear(512, n_classes)

    def forward(self, x):                      # x: B,1,32,W
        f = self.cnn(x).mean(2)                # B,C,W/2
        f = f.permute(0, 2, 1)                 # B,T,C
        f, _ = self.rnn(f)
        return self.fc(f)                      # B,T,K (logits)


def decode(logits, inv):
    best = logits.argmax(-1).cpu().numpy()
    out = []
    for row in best:
        s, prev = [], BLANK
        for k in row:
            if k != prev and k != BLANK:
                s.append(inv[k])
            prev = k
        out.append("".join(s))
    return out


def evaluate(model, loader, inv, dev, items):
    model.eval()
    ok, n, by = 0, 0, {}
    i = 0
    with torch.no_grad():
        for X, _y, ylen, _w in loader:
            pred = decode(model(X.to(dev)), inv)
            for p in pred:
                _path, label, style = items[i]
                i += 1
                good = p == label
                ok += good
                n += 1
                a, b = by.get(style, (0, 0))
                by[style] = (a + good, b + 1)
    model.train()
    return ok / max(1, n), {k: round(a / b, 4) for k, (a, b) in sorted(by.items())}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--val", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=10)
    ap.add_argument("--bs", type=int, default=96)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--resume", action="store_true",
                    help="continue from model/checkpoint.pt (saved every CKPT_EVERY steps)")
    ap.add_argument("--init", help="start from these weights (a saved infloww_rec.pt)")
    ap.add_argument("--start-epoch", type=int, default=0, help="with --init: which epoch it had finished")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    torch.backends.cudnn.benchmark = False      # see collate(): shapes vary
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    train_items = load_labels(Path(a.data))
    val_items = load_labels(Path(a.val))
    out_cs = Path(a.out) / "charset.json"
    if (a.init or a.resume) and out_cs.exists():
        # Continuing from saved weights: the output layer is tied to THIS list.
        chars = json.loads(out_cs.read_text(encoding="utf-8"))
        unknown = {c for _, lab, _ in train_items + val_items for c in lab} - set(chars)
        if unknown:
            print(f"{len(unknown)} characters not in the saved charset are skipped: "
                  f"{''.join(sorted(unknown))[:60]}", flush=True)
    else:
        chars = sorted({c for _, lab, _ in train_items + val_items for c in lab})
    charset = {c: i + 1 for i, c in enumerate(chars)}          # 0 = CTC blank
    inv = {i: c for c, i in charset.items()}
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "charset.json").write_text(json.dumps(chars, ensure_ascii=False), encoding="utf-8")
    print(f"{len(train_items)} train, {len(val_items)} val, {len(chars)} characters, on {dev}", flush=True)

    tl = DataLoader(Lines(train_items, charset, True), batch_size=a.bs, shuffle=True,
                    num_workers=6, collate_fn=collate, persistent_workers=True, drop_last=True)
    vl = DataLoader(Lines(val_items, charset, False), batch_size=48, shuffle=False,
                    num_workers=2, collate_fn=collate)
    model = CRNN(len(chars) + 1).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
    first_ep = a.start_epoch
    if a.init:
        model.load_state_dict(torch.load(a.init, map_location=dev))
        print(f"started from {a.init}, epochs {first_ep}..{a.epochs - 1} left", flush=True)
    steps = (a.epochs - first_ep) * len(tl)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.1)
    ctc = nn.CTCLoss(blank=BLANK, zero_infinity=True)
    best = -1.0
    t0 = time.time()
    step = 0
    ck = out / "checkpoint.pt"
    if a.resume and ck.exists():
        c = torch.load(ck, map_location=dev)
        model.load_state_dict(c["model"])
        opt.load_state_dict(c["opt"])
        sched.load_state_dict(c["sched"])
        first_ep, step, best = c["epoch"], c["step"], c["best"]
        print(f"resumed at epoch {first_ep}, step {step}/{steps}, best so far {best:.4f}", flush=True)

    def save_ckpt(ep_next):
        torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "sched": sched.state_dict(),
                    "epoch": ep_next, "step": step, "best": best}, ck)

    for ep in range(first_ep, a.epochs):
        for X, y, ylen, _w in tl:
            if step >= steps:
                break
            X = X.to(dev, non_blocking=True)
            # bf16 for the network (about 2x faster on this card); the CTC loss
            # itself stays in float32, where it is numerically safe.
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=dev == "cuda"):
                logits = model(X)
            lp = F.log_softmax(logits.float(), -1).permute(1, 0, 2)  # T,B,K
            T_ = torch.full((X.shape[0],), lp.shape[0], dtype=torch.long)
            loss = ctc(lp, y, T_, ylen)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            sched.step()
            step += 1
            if step % 200 == 0:
                print(f"ep {ep} step {step}/{steps} loss {loss.item():.4f} "
                      f"{(time.time() - t0) / 60:.1f} min", flush=True)
            if step % CKPT_EVERY == 0:
                save_ckpt(ep)           # a stop mid-epoch replays only this epoch
                if dev == "cuda":
                    # Hand cached blocks back: with varied shapes the cache only
                    # grows, and a full card stalled training outright (2026-11-28).
                    torch.cuda.empty_cache()
        acc, by = evaluate(model, vl, inv, dev, val_items)
        if dev == "cuda":
            torch.cuda.empty_cache()
        print(f"== epoch {ep}: exact {acc:.4f} {by}", flush=True)
        if acc > best:
            best = acc
            torch.save(model.state_dict(), out / "infloww_rec.pt")
        save_ckpt(ep + 1)
    model.load_state_dict(torch.load(out / "infloww_rec.pt"))
    model.eval().cpu()
    dummy = torch.zeros(1, 1, H, 200)
    torch.onnx.export(model, dummy, out / "infloww_rec.onnx", input_names=["x"], output_names=["logits"],
                      dynamic_axes={"x": {0: "b", 3: "w"}, "logits": {0: "b", 1: "t"}}, opset_version=17,
                      dynamo=False)
    print(f"best exact {best:.4f}; saved {out / 'infloww_rec.onnx'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
