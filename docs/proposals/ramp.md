# Ramps — ⚠ UNSOLVED

> **RAMP MODE IS NOT SOLVED. Do not build from this file.**
>
> Four design attempts (2026-08-31 → 09-01), each corrected on a **premise**, not a detail:
>
> | # | what it assumed | what was actually true |
> |---|---|---|
> | 1 | the `fu1→fu2→fu3→ppv` data model was the spec | it was context for understanding the domain |
> | 2 | this is a storage problem | it is a **naming and recall** problem |
> | 3 | it's freestyle, so there is no pipeline | the **ramping pipeline is real** — *chatting* is what MMA must have no rules about |
> | 4 | ramps are authored | ramps **accrete** from good messages found mid-chat |
>
> Four premise replacements in a row means the gap is **domain understanding**, and no
> further design closes it. Everything below is a draft written from a *described* flow
> rather than from *observed* work.
>
> **NEXT STEP — ask, do not design:**
>
> > **"Silly, teach me how you actually chat."**
>
> A real walkthrough: what is on screen, what the hands do, at what moment a saved message
> gets reached for instead of typed, and what the decision at that moment actually is.
> Then rewrite this file from what was observed.
>
> Tracked in the global issues file under `## MMA`.
>
> **Not blocked by this:** [capture.md](capture.md) — the OCR line/message defect is a
> confirmed bug in shipped code and stands on its own.

---

## 1. The domain: a real pipeline, inside a conversation MMA has no rules about

**The ramping process is a pipeline. That part is true:**

```
Me    Wanna see my tits?                                     ┐
Fan   Fuck yess                                              │ pre 1
Me    But you know theyre suckable af right?                 │ the run-up
Fan   Yessssss                                               │
Me    And would you looooove to suck the soul out of them?   ┘
Fan   omg yes send it already bby

Me    [PPV 1 caption]                                          ppv 1
Me    [bump]  [bump]                                           bump 1
      ── fan opens ──

Me    But imagine if instead of just sucking on my tits and   ┐ pre 2
      teasing, I let you slide ur hands down and tease my     │ 4-10 messages
      kitty too?                                              ┘ sets up ppv 2
Fan   FUCK YES BABY

Me    [PPV 2 caption]                                          ppv 2
      ── fan opens ──
```

Upsell, continue the story, upsell again. **What MMA has no business having rules about is
chatting.** You are chatting to people; 90% of a shift is freestyle. MMA does not model that,
gate it, or have an opinion about it.

### There is structure, but MMA's code is not the structure

| | |
|---|---|
| **represent** the ramp shape | so you can find your own material |
| **do not enforce** it | no state machine, no "you are at step 4", no refusing things out of order |
| **do not encode** it as schema law | adding a slot must not be a migration |

**MMA already gets this right in one place.** From [mass-format.md](../mass-format.md):

> **Sparse masses are normal** — `f1` only, or `f1` + `f3` with a gap, are both completely
> valid and nothing treats them as an error.

The pipeline is real *and* gaps are normal. Not in tension: a half-built ramp is a ramp.

---

## 2. Ramps are discovered, not written — and that is the whole problem

> I don't pre-write ramps. I write, see what works, and save good messages as I discover
> them. This ends up being lots of triggers like `BDAY_MPPV_2`, `BDAY_MPPV_2_BUMP`, etc —
> very hard to keep track of.

**A ramp is a by-product of saving good messages, not a document you author.** Everything
below follows from that, and it is the thing to get right.

### The diagnosis: a record flattened into a string

`BDAY_MPPV_2_BUMP` is four structured fields:

| fragment | field |
|---|---|
| `BDAY` | which ramp |
| `MPPV` | a PPV, not a tease |
| `2` | which slot |
| `BUMP` | which role in that slot |

You are hand-serialising a record into an identifier **because MMA gives that record nowhere
to live** — and doing it mid-chat, under time pressure, with no view of what you have already
named. The sprawl is not a discipline failure. It is the only available way to store
structure in a system whose one storage key is a trigger string.

**Give the structure a home and the name stops mattering.** MMA generates it; you address by
ramp × slot × role, which are three numbers and a word you can read off the screen.

### What this means for the design

- **Capture is the primary interface**, not an import path. It is how ramps come into
  existence, one message at a time, out of order.
- **A slot may be created by saving into it.** There is no "make a ramp, then fill it" step;
  a ramp with only a `pre 3` in it is a real ramp that you will fill in later or never.
- **You need to see what you accumulated**, because you never designed it. §6.

---

## 3. The record

### 3.1 A slot has three roles

Straight off the example, using your words:

| role | what it is | how it goes out |
|---|---|---|
| `pre` | the run-up that sets up this PPV — 4-10 messages | sent, one after another |
| `ppv` | the caption | **pasted**, like the mass — you attach media to it |
| `bump` | the nudges to open it | sent |

`pre{n}` is the run-up *to* PPV n. It is the same thing as "what comes after PPV n−1" — so it
is stored once, under one name, never as both `post1` and `pre2`.

```ahk
global RAMP_SLOT_MAX := 12      ; addressing space, NOT a sequence length

MASS_SlotFields(n) {
    return ["st" n "_pre", "st" n "_ppv", "st" n "_bump"]
}
```

Three fields, not five. `pre` and `bump` each hold **one trigger or several lines**; the
3-part `fu1/fu2/fu3` cap does not come along — that was an artifact (`.5`/`.7` are
*"historical"* by [mass-format.md](../mass-format.md)'s own admission) and a pre is 4-10
messages, so it never fitted anyway.

**Each field holds a bare trigger or literal text.** Whole trimmed value matches a trigger in
`HSI_Build()` → that hotstring fires; otherwise it is sent as text. One rule, three fields,
testable alone.

Plus a flat `name` on the ramp — `BDAY` — set once, and the only string you ever type.

### 3.2 Scale: ten live at once, none deleted, one reopens after three weeks

> Sometimes we have 10 concurrent PPV events (we don't delete old ones), so when someone
> opens a PPV from 3 weeks ago I need to have the ramp saved.

This is the sizing constraint and it kills several designs:

- **Nothing expires.** No cleanup, no archive-after-N-days. A ramp is live until you say
  otherwise, because "3 weeks ago" is a normal reopen.
- **10 ramps × ~4 slots × 3 roles ≈ 120 addressable things** — the same order as the 137
  hotstrings you already cannot track. So addressing must genuinely collapse it, not
  re-present it. That is what the lock is for (§5).
- **Standalone ramps are the common case, not the exception.** Most of those ten did not
  start from today's mass. So `userdata\ramps.json` is a first-class store, and an
  attached ramp (one hanging off a mass slot) is the *variant*.

Same record shape either way — a standalone ramp is one whose opening leg is empty. One
reader, one picker, and `masses.json` never learns `ramps.json` exists.

### 3.3 Migration

Today's `ppv_base` / `ppv_f1..3` are slot 1's `ppv` and `bump`. `MASS_SCHEMA` 1 → 2, old keys
left on disk (the `fu<grp>_alt<n>` precedent). **11 files, ~52 references** — measured; the
largest mechanical chunk, and the most isolated. Its own commit, first.

---

## 4. Capture: how a ramp actually comes into existence

> I write something good and then OCR it, and append it as a hotstring.

> **The harder half is a defect, not a design gap.** OCR returns one entry per *visual line*
> and `DoAppend` writes one `snd()` per line, so a wrapped message becomes several and a
> 10-message `pre` arrives shredded. That is [capture.md](capture.md) and it ships **first** —
> organising material that arrived mis-split is fixing the wrong end.

### The one question that gets deleted

```
Add Hotkey dialog
  ├─ invent a trigger        ← DELETED
  └─ "Save to ramp…"         ← ONE NEW BUTTON
       ├─ ramp   the locked one, already selected
       ├─ slot   first free, already selected
       └─ role   pre / ppv / bump
  ↓
saves, immediately
```

Three answers, all pre-filled, all a choice from a short list rather than a string. The
trigger is generated — `__BDAY_2_bump` — and **you never type or recall it.**

### This pattern already ships, in that exact dialog

Add Hotkey already has a button meaning *"this text is not a hotstring, it belongs in a
slot"*: **"Replace follow-up…"**, handing OCR'd text to
[alt_fu_window.ahk](../../src/ui/alt_fu_window.ahk). Its header is the design note for this,
written a release early:

- asks **which model · which mass · which follow-up · what does it say**
- opens on **the follow-up you last sent**
- **commits to disk** rather than waiting for a Save, because *"the editor is not where you
  are during a capture: the main window is behind Infloww and 'now go and press Save' is a
  trip that would not be made until the end of a shift, if at all"*

"Save to ramp…" is that window asking for slot + role. A sibling of a button that exists.

Pres stay ordinary hotstrings in `content\*.ahk`, appended by `HSI_AppendBlock` as today — so
the manager still edits them and search still finds them. MMA just writes the name.

---

## 5. Recall

### The lock does the collapsing

```
__pre2   →  ramp locked      →  send it. No window, no decision.
         →  nothing locked   →  picker  →  send, and offer to lock
```

120 addressable things become 12 the moment a ramp is locked, and 12 is a number you can hold
in your head off the top of it. **The lock is the feature**, not a convenience on top of it.

The picker is **`__mm`'s picker asking a different question** — "question 2" in
[model_picker.ahk](../../src/mass/model_picker.ahk). Copy its discipline: foreground window
saved on open and re-activated before a character is sent; number keys bound to that window
only (`_PickHotIf`); every button previews what it sends, including the honest `(empty)`.

### Switching ramps must be cheap, because a 3-week-old PPV just opened

With ten live ramps, the lock changes several times a shift. One key, a list of ten by name,
number to pick. Not a trip to a settings window.

### Worth trying: read the chat to suggest the ramp

When a fan opens an old PPV, the conversation on screen **contains your own earlier ramp
messages**. [next_fu.ahk](../../src/mass/next_fu.ahk) already does exactly this trick — OCR
the pane, match against text MMA wrote, work out where you are — and its header argues the
case better than this one could: *per chat for free, per model for free, correct after a
restart, and correct in a chat MMA never sent in.*

Matching visible text against saved ramp material would name the ramp without you choosing.

**Under next_fu's own discipline, and only that:** it *suggests*, it never switches silently,
and when unsure it does nothing. *"A key that does nothing costs a keypress, a key that
guesses costs a real message to a real person."* Build it after the manual lock works, never
instead of it.

### No per-fragment hotkeys

Add Hotkey's "Record key" is right for *"a hotstring you send forty times a day"*. A ramp
fragment is the opposite — a handful of sends, ~120 of them. **"Save to ramp…" offers no
key**, because `__pre2` already is one and a second address is a second thing to forget.

---

## 6. Seeing what you accumulated

You never designed these ramps, so you cannot remember them — that is *"very hard to keep
track of"*, stated exactly.

The lock badge ([lock_badge.ahk](../../src/ui/lock_badge.ahk)) shows the locked ramp's
contents, not a position:

```
  BDAY    1 pre·ppv·bump    2 pre·ppv    3 ppv    4 —
```

Filled roles named, empty ones dashed. Nothing marked "current", because there is no current.

**And one read-only ramp view**, listing all ten with what each holds. Not an authoring grid
— the [hotstrings manager](../../src/ui/hotstrings_window.ahk) already edits the text and
capture already creates it. This answers *"what do I have for BDAY, and what did I never
finish?"*, which is a question you can only ask about something you accreted.

---

## 7. The hazard this introduces

**A pre is a 6-to-15-second send** — ten `snd()` calls at `waitTime` apiece, far longer than
anything MMA does today, with the chat box owned throughout.

1. **The click wall must cover it.** [click_wall.ahk](../../src/screen/click_wall.ahk) exists
   for exactly this: click the next conversation mid-send and the rest lands in a stranger's
   inbox. Written for a 3-part follow-up; a 10-part pre is that bug with four times the
   window.
2. **An abort key.** Fifteen seconds of your machine typing with no way to stop it is a new
   category of risk here — every existing send is over before you could react. Esc stops at
   the current message. In a fluent chat this is not a nicety.
3. **Visible progress.** A tooltip counting `3 / 8`.

---

## 8. Build order

| # | Step | Notes |
|---|---|---|
| — | **[capture.md](capture.md)** | ships first; everything here stores material from that pipe |
| 1 | Slot rename + schema 2 | 11 files, mechanical, its own commit |
| 2 | `name`, `RAMP_SLOT_MAX`, `MASS_SlotFields` + `ramps.json` | the record and the standalone store |
| 3 | Trigger-or-text resolution rule | pure function, unit-testable in `tools/test/` |
| 4 | **"Save to ramp…"** + name generation | **how ramps get made.** Sibling of "Replace follow-up…" |
| 5 | The lock, the switcher, the contents badge | copy `model_picker.ahk`'s focus discipline |
| 6 | `__pre{n}` / `__ppv{n}` / `__bump{n}` + send | with the click wall, the abort, the tooltip |
| 7 | The read-only ramp view | answers "what do I have" |
| 8 | Ramp suggestion by reading the chat | only after 5 works; next_fu's discipline |

**4-6 fix the stated problem.** 1-3 make them possible. 7 is what makes ten ramps survivable.
8 is speculative and cut first.

`__pre{n}` is registered by the **mass engine** — it reads the store and the lock, both of
which the engine owns, and it is the always-on process (see
[chat/nav.ahk](../../src/chat/nav.ahk)). Dynamic registration via AHK v2's `Hotstring()`, the
way `HotstringKeys_Register` in [utils.ahk](../../src/core/utils.ahk) binds a key per
hotstring. Registering in `utils.ahk` would give eight identical `__pre1`s — the problem
[quick_menu.ahk](../../src/hotstrings/quick_menu.ahk) solved with an ownership rule.
