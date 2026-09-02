# OCR capture: swaths, not lines — PLANNED

> **Status: not built.** Target **v2.1.4**. Independent of [ramp.md](ramp.md) and shippable
> before it. This is the acute pain: *"PPVs are parts of ramps and managing large swaths of
> OCR text is hard."*

---

## 1. The defect at the centre of it

`OcrRegionToText` in [ocr_grab.ahk](../../src/screen/ocr_grab.ahk) returns **one entry per
visual line**. `DoAppend` in [main_core.ahk](../../src/ui/main_core.ahk) then writes one
`snd()` per non-empty line:

```ahk
for _, ln in StrSplit(raw, "`n") {
    t := Trim(ln)
    if t = ""
        continue
    block .= "    " fn '("' t '")`n'        ; one line -> one message
}
```

**A line is not a message.** A chat bubble that wraps across three lines on screen becomes
three separate messages sent to a real person. Grab a five-message filler sequence and you
get fifteen `snd()` calls.

The manual repair is to rejoin them in the `Lines` box — a 120px multiline `Edit`, while you
are mid-shift with a chat open behind it. That is the whole of "managing large swaths is
hard", and it scales with exactly the thing you most want to capture: long filler sequences.

### The fix is already in hand and thrown away

`OcrRegionToText` reads geometry for every line and discards it after sorting:

```ahk
lines.Push({t: t, x: line.x, y: line.y})    ; x and y collected
SortByPosition(lines)                        ; used for ORDER
out .= (out = "" ? "" : "`n") l.t            ; then dropped
```

Chat bubbles are geometrically obvious, and the file already reasons about this:

| signal | already known to the code |
|---|---|
| vertical gap between bubbles > line spacing within one | `y` is collected |
| wrapped lines share a left edge; a new bubble does not | `x` is collected |
| your side vs his side | `IsAfter` already sorts on `x` within a row |
| a timestamp row sits between bubbles | `CleanOcrLine` **detects and deletes** these |

That last one is the sharpest: a timestamp is a *boundary marker*, and it is currently
recognised and thrown away rather than used as the separator it is.

---

## 2. What to build

### 2.1 Group lines into messages

`OcrRegionToText` gains a sibling returning **messages, not lines** — the same read, grouped:

- a `y` gap materially larger than the median line pitch → new message
- a change in left `x` beyond a tolerance → new message
- a line `CleanOcrLine` would drop as a timestamp → boundary, then dropped

Keep `OcrRegionToText` as it is. Other callers exist and grouping is a different question
from reading; the new one is a layer over it.

**Thresholds must be measured on the real window, not chosen.** This is the same discipline
`OcrRegionToText` already applied to `scale: 3` + `grayscale` — those numbers are in the file
with the evidence for them. Anything picked to taste here will be wrong at the actual
3441×1381 (see [snapping.md](snapping.md) §A).

### 2.2 One side of the conversation

A swath grabbed from a live chat contains both halves. You want yours. The left-edge cluster
already separates them — two dominant `x` values, one per side — so the dialog offers
**mine / his / both**, defaulting to the side with the most text in the grab.

This is a heuristic and it will occasionally be wrong, which is fine **because §2.3 makes it
visible before anything is written**.

### 2.3 Review as messages, not as a blob

The `Lines` box is where a 15-line blob becomes unmanageable. Replace it, for a grouped
capture, with a list of the messages as they will be sent:

```
  1  ┃ i keep thinking about last night          [split] [×]
  2  ┃ you know what i mean right                [split] [×]
  3  ┃ i couldnt even sleep after so i filmed
     ┃ something just for you                    [split] [×]
     ─────────────────────────────────────────────  [merge 3+4]
  4  ┃ 8:47 pm  (dropped — timestamp)            [keep]
```

Merge, split, delete, edit in place. **Four messages is four rows, and you can see that it is
four before you append.** Today you count `snd(` calls afterwards, in the file.

The plain multiline box stays for typed and pasted text — this is what an *OCR grab*
produces, not what the dialog always shows.

### 2.4 Sendt timing per message

The dialog has one `ms` box for the whole block. A filler sequence is where per-message
timing actually matters — a one-line tease and a four-line paragraph should not sit for the
same 500ms. Optional per-row override, blank meaning "use the block's".

Low priority; note it, build it if §2.3 makes it free.

---

## 3. Why this ships before the ramp work

Every pre and every PPV caption enters MMA through this pipe. Fixing the organisation of
material that arrives mis-split is fixing the wrong end — and today's library already
contains hotstrings that were split wrong on the way in, which no amount of ramp addressing
repairs.

It is also useful standalone: it fixes every OCR capture, including the ones that have
nothing to do with ramps.

### A migration question worth answering, not assuming

Existing blocks in `content\*.ahk` that were split at line boundaries **are already wrong**
and are sending multi-message where one was meant. Finding them is possible — the manager
already parses every block into `steps` — but *fixing* them means guessing which adjacent
`snd()` calls were one message, and a wrong guess rewrites a working hotstring.

So: **report, never auto-repair.** A one-off pass in the hotstrings manager flagging blocks
whose steps look like wrapped fragments (no terminal punctuation, a step starting lowercase
mid-block), for you to merge by hand. The manager already has the editor for it.

---

## 4. Scope

| | In |
|---|---|
| geometry grouping into messages | **yes** — the defect |
| side selection (mine / his / both) | **yes** — free once grouping exists |
| message-list review with merge/split | **yes** — this is what makes swaths manageable |
| per-message `Sendt` timing | if free |
| flagging already-mis-split blocks | **yes**, report only |
| auto-repairing them | **no** — a wrong guess rewrites working text |

No new feature flag. This is a fix to a path that already exists and is already reached by
`gui.ocrGrab` (`^+o`) and `gui.addHotkeyGrab` (`!0`).
