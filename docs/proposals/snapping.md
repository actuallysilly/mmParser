# Pointer snapping — PLANNED, and narrowed

> **Status: not built.** Target **v2.1.4** for parts A and B. **Part C is data collection
> only** — the prediction it would feed is explicitly deferred, and the reason is below.

---

## The ask

> Is it possible to do UI snapping, basically predicting what I want to touch instead of me
> having to scroll — using "hot zones" and perhaps a history of movement sequences? Any other
> ideas? Perhaps semantic ideas, because the sequences make sense based on events/UI.

Short answer: yes, and **the semantic version is the one to build**. The predictive version
is the one to hold. Reasoning at the bottom.

---

## Part A — coordinates that survive the real window (prerequisite)

**This is a live bug, not groundwork.**

[core/coords.ahk](../../src/core/coords.ahk) is a flat list of absolute pixel pairs:

```ahk
home         := [95, 65]
ppvOpenNotif := [1760, 110]
topChat      := [181, 308]
openInNewTabButton := [1508, 107]
```

Every one was measured against a maximised **1920×1032** client. So was
`[NextFu] RegionX/Y/W/H` (401, 135, 1237, 727 — a rectangle that only fits inside 1920), and
so were the automation regions in
[services/automation/UI-ELEMENT-MAP.md](../../src/services/automation/UI-ELEMENT-MAP.md).

The Infloww window in actual use is **3441×1381**. Every one of those numbers points at the
wrong pixel.

[core/dpi.ahk](../../src/core/dpi.ahk) already solved the *scaling* half of this properly —
per-monitor awareness, thread-scoped or process-wide. It does not solve the *window size*
half, and nothing does.

**The fix:** coordinates stop being screen pixels and become **fractions of the Infloww
client rect**, resolved at use. `home` is not `[95, 65]`, it is "5% across, 6% down". One
resolver, `COORD_At(name)`, does client-rect lookup plus the existing DPI entry, and every
call site keeps its name.

Two rules, both learned the hard way:

- **Measure inside AHK.** Never calibrate off a PowerShell or `PrintWindow` capture; on a
  mixed-DPI desk those disagree with what AHK sees, consistently enough to look right.
- **Fractions of the client rect, not the screen.** The chat list moves when the window is
  resized, not when the monitor changes.

This unblocks `next_fu`, `reply_box`, `stats_overlay`, `click_wall`, `tab_marks` and the
Python automation regions at the same time. It is worth doing on its own merits even if
nothing below is ever built.

---

## Part B — semantic targets, on keys

Not prediction. **Naming the things you actually go to**, and going there on a keypress:

```
next unread          the composer          the vault button
top of the list      the send button       the PPV notification
```

Most of these already have a name in `coords.ahk` and a binding in
[chat/nav.ahk](../../src/chat/nav.ahk). What Part B adds is: **move the pointer there**
rather than click there, so the pointer is where your hand expects it for whatever you do
next. Optionally warp back afterwards.

This is deterministic, testable, and wrong zero percent of the time. It is also the direct
answer to *"the sequences make sense based on events/UI"* — the UI has a small set of places
worth being, and they can simply be enumerated.

The genuinely semantic part is **event-driven**: after a send completes, the next place you
want to be is the conversation list. After opening a chat, it is the composer. Those are two
rules, not a model, and MMA already knows when both events happen.

---

## Part C — record hot zones. Do not predict from them yet.

Record where the pointer goes: click positions and dwell, bucketed into a grid of the client
rect, under the **exact discipline the activity tracker already runs** — see the header of
[activity/record.ahk](../../src/activity/record.ahk). Counts per zone per minute. No window
titles, no fan names, nothing a message could be reconstructed from. The CSV format already
supports a second writer, by design.

Then **show it** — a heatmap in the activity window, which already draws one.

### Why prediction is deferred, plainly

Moving someone's pointer is invasive in a way that a wrong colour or a wrong tooltip is not.
A predictor that is right 70% of the time does not save 70% of the scrolling; it costs you a
correction on the other 30%, at a moment when your hand is already moving, and it will fight
you hardest exactly when you are doing something unusual — which is when you are most likely
to be sending the wrong thing to the wrong person.

That trade is the same one [next_fu.ahk](../../src/mass/next_fu.ahk) already made and wrote
down: *"a key that does nothing costs a keypress, a key that guesses costs a real message to
a real person."* Snapping guesses with your hand.

So: collect the data, look at the heatmap, and decide with numbers whether the zones are even
concentrated enough for prediction to beat Part B's fixed targets. If three zones cover 90%
of clicks, three keys beat any model.

---

## Scope for 2.1.4

| Part | In? | Notes |
|---|---|---|
| A — fractional coordinates | **yes** | fixes a live bug across six subsystems |
| B — semantic targets on keys | **yes** | new keys in `[nav]`, one `FEAT_Def` under Tools |
| C — zone recording + heatmap | **yes** | off by default, like the activity tracker |
| prediction / movement sequences | **no** | revisit once C has a month of data |
