# ReplyTime tools — PLANNED

> **Status: not built.** Target **v2.1.4**. Builds on the activity tracker; needs one new
> record type.

---

## The ask

Measure the time spent in Infloww:

1. **AFK** — how much, and how often
2. **Chat-to-chat** — opening a chat to opening the next one
3. **Inside a chat**, what the time actually goes on — reading, typing, hunting in the
   vault, or fully AFK

---

## What exists, and the one thing it cannot do

[activity/tracker.ahk](../../src/activity/tracker.ahk) already counts, per minute:

```
keys   chars   bksp   mouse   active   max.gap
```

written through [activity/record.ahk](../../src/activity/record.ahk) as
`minute,counter,value` into `userdata\activity\<date>.<source>.csv`, and drawn by
[ui/activity_window.ahk](../../src/ui/activity_window.ahk).

`active` and `max.gap` between them already answer **question 1** — seconds present per
minute, and the longest pause ending in each minute. A little aggregation on the existing
data is the whole of it.

**Questions 2 and 3 do not fit that format at all.** A minute bucket cannot express "23
seconds in this chat, then the next one". Those are *events with durations*, and the counter
CSV has nowhere to put one.

---

## The new record: an event log beside the counter log

`record.ahk` already anticipated a second writer — one file per process per day, readers glob
`<date>.*.csv` and merge, so appends stay single-writer. Use exactly that:

```
userdata\activity\2026-09-04.replytime.csv

   at,event,detail
   34122,chat.open,
   34155,state,typing
   34161,state,reading
   34189,chat.open,
```

`at` is seconds since local midnight — the counter log's minute is too coarse here, and the
filename still carries the date.

### The privacy law does not bend for this

[record.ahk](../../src/activity/record.ahk)'s header is emphatic and correct: nothing there
can hold text, structurally, because the tracker sees every keystroke of a shift. **A
`chat.open` event carries no fan name, no handle, no chat id, no window title.** `detail` is
drawn from a closed vocabulary — `typing`, `reading`, `vault`, `afk` — and nothing else may
be written to it.

Everything asked for here is answerable from durations alone. "How long between chats" needs
a boundary, not an identity.

---

## Where the boundaries come from

**Chat opened** — MMA already knows, without OCR and without guessing:

| signal | source |
|---|---|
| `nav.nextChat` · `nav.unread` · `nav.clickUnread` · `nav.unreadLeft` · `nav.focusTop` | `[nav]` keys, bound in [chat/nav.ahk](../../src/chat/nav.ahk) |
| a click landing in the conversation-list region | the region [click_wall.ahk](../../src/screen/click_wall.ahk) already guards |

Those are exact for keyboard navigation and good for mouse. Nothing needs to be recognised.

**In Infloww at all** — the window-active gate, and *Messages only*. The Home window is a
different page with different numbers on it (that is what
[stats_overlay.ahk](../../src/screen/stats_overlay.ahk) reads) and time spent there is not
chat time.

---

## Classifying the time inside a chat

Three of the four states fall out of the hook the tracker already runs:

| state | rule |
|---|---|
| `typing` | physical keys in the last second — `MinSendLevel := 1` already excludes MMA's own sends, so a pasted mass never counts as you typing |
| `afk` | idle longer than `[Activity] IdleMs` (2s default) |
| `reading` | Infloww active, no keys, not yet AFK |
| `vault` | **needs screen detection** — see below |

`vault` is the only one that is not free. The vault is a UI element, so it means a region
check of the kind [pill_scan.ahk](../../src/screen/pill_scan.ahk) does — cheap per second,
but it is a pixel read and pixel reads are the fragile part of MMA.

**So ship `vault` behind its own switch,** and let the other three be always-on once the
feature is enabled. Three honest states are worth more than four states where one of them
quietly reads the wrong pixels after a UI update and files vault time as reading.

This also depends on [snapping.md](snapping.md) Part A — a vault region hard-coded at
1920×1032 is looking at empty space in a 3441×1381 window.

---

## Reporting

The activity window already draws a heatmap, an area chart and four cards from a JSON payload
handed over a WebView bridge. Add a **ReplyTime** range to that page rather than building a
second window:

- median and p90 chat-to-chat time
- a stacked band per hour — typing / reading / vault / afk
- AFK count and total, which is question 1 stated directly

---

## Scope for 2.1.4

| Item | In? |
|---|---|
| AFK amount + frequency (from existing counters) | **yes** |
| chat-to-chat timing (new event log) | **yes** |
| typing / reading / afk split | **yes** |
| vault detection | **yes, behind its own switch**, after snapping Part A |
| per-fan attribution | **no** — see the privacy law above |

One `FEAT_Def` under **Background**, off by default, exactly like the activity tracker it
sits beside.
