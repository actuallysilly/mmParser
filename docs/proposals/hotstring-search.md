# Search a hotstring in place — PLANNED

> **Status: not built.** Target **v2.1.4**. Roughly half the machinery already exists.

---

## The problem

The library is ~137 triggers. Two of them are most of a shift and you know those by heart;
the rest you half-remember. Both ways in today are slow:

- **type the abbreviation** — requires recalling it exactly
- **open the manager** and search — a window, a context switch, a copy back

What is wanted is a third: **type something, see what matches, send it, without leaving the
chat box.** Search for what you need *in place* instead of memorising triggers.

---

## What already exists

| Piece | Where | Gives us |
|---|---|---|
| the parsed library | `HSI_Build()`, [hotstrings/index.ahk](../../src/hotstrings/index.ahk) | trigger, `preview` (all text on one line, built for search), file, line |
| recency + pins | [hotstrings/usage.ahk](../../src/hotstrings/usage.ahk) | `HSU_Recent()`, `HSU_Pinned()`, cross-process via `userdata\hotstring_usage.ini` |
| one send path | `Hotstring_Fire()`, [core/utils.ahk](../../src/core/utils.ahk) | overloads keep working; your words have one copy |
| a popup that uses all three | [hotstrings/quick_menu.ahk](../../src/hotstrings/quick_menu.ahk) (`^!h`) | pinned + recent, at the cursor, 1-9 accelerators |

**The gap is search.** `quick_menu` is a Windows `Menu()`, and a `Menu()` cannot filter as
you type. That is the whole of the missing feature.

---

## The design

### The trigger

`....` opens the picker. The four dots are deliberate: `...` is real punctuation people type,
and firing on it would open a window mid-sentence.

The `{variable}` in the original note is **what you keep typing after it** — it does not go
in the trigger. The picker opens focused with an empty search box and you carry straight on
typing into it. Nothing is typed into Infloww, so there is nothing to clean up on cancel.

### It is a Gui, not a Menu

An `Edit` on top, a `ListView` under it, filtered on every keystroke.

- **Enter** sends the highlighted row through `Hotstring_Fire`
- **Up/Down** move; **Tab** also moves, for the hand already on it
- **Esc** closes and sends nothing
- **Ctrl+Enter** opens that row in the manager instead of sending it

### Ranking, because the first row is the one you will press

Matches are scored, not just listed:

1. trigger **starts with** the query
2. trigger **contains** the query
3. **message text** contains the query — this is the case that makes the feature, because
   "cum" or "beach" is what you remember, not `_gns5`

Ties break by pins first, then recency, both from `usage.ahk`. Everything the quick menu
already knows about what you actually reach for.

### Two things it must get right

**Focus.** The window takes the foreground, so the send would type into the picker. Save the
foreground window on open and re-activate it before a single character goes out — the exact
discipline in [model_picker.ahk](../../src/mass/model_picker.ahk), which had this bug and
fixed it.

**Key capture.** Do **not** reach for an `InputHook` to collect the typing. It is
system-wide and swallows the key before the focused control sees it. The Gui's own `Edit`
already has the keystrokes; let it keep them.

### Ownership

Same rule as `HSQ_OwnerFile()` — the first file `HSI_Files()` lists owns the trigger, so
exactly one of the message processes opens exactly one window. Do not copy the *mechanism*
by hand; call the existing function.

---

## Scope

New file `src/hotstrings/search_popup.ahk`, one `FEAT_Def` under **Library**, one entry in
`[gui]` of `hotkeys.default.ini` for people who want a key as well as the `....` trigger.

`quick_menu.ahk` stays as it is. Pinned-and-recent on one key and search-as-you-type on
another are different questions — the first is "the ten I always send", the second is "the
one I cannot name". Its last row should gain **Search…** so the two are discoverable from
each other.

## Why this lands before the ramp work

Ramp stages are addressed by trigger name (see [ramp.md](ramp.md) §2.1), so authoring a ramp
means finding a trigger. Shipping search first makes that job possible; shipping it after
means building the ramp editor against a library you cannot search.
