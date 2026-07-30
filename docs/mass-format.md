# The mass paste format

The full user guide is **[docs/guide.html](guide.html)** — open it from the main window's
**How to Use** button. This file is the format alone, for reading in an editor.

Everything here is what `src/mass/parser.ahk` actually does.

---

## The fields

One mass is 14 fields. The labels in the GUI are the names below.

| Field | Meaning |
|---|---|
| `!mm` | the mass itself — the opening message |
| `f1` `f1.5` `f1.7` | follow-up 1, in up to three parts |
| `f2` `f2.5` `f2.7` | follow-up 2 |
| `f3` `f3.5` `f3.7` | follow-up 3 |
| `ppv` | the PPV caption (may span lines) |
| `ppvfu1` `ppvfu2` `ppvfu3` | follow-ups sent after the PPV |

> **The decimals are `.5` and `.7`. Nothing else.**
> `f1.1`, `f1.2`, `f1.9` match no field and are **silently dropped**. They are only labels
> for "second part" and "third part"; the odd numbers are historical.

Every follow-up is optional. **Sparse masses are normal** — `f1` only, or `f1` + `f3` with a
gap, are both completely valid and nothing treats them as an error.

---

## Three ways to write it

MMA picks the mode automatically by looking at the text. You never choose.

| Mode | Chosen when |
|---|---|
| **keyword** | a line starts with an exact field name (`f2.5 …`, `ppvfu1 …`) |
| **prefixed** | any line starts with `f` or `fu` plus a number |
| **positional** | neither — blank lines separate the groups |

### Positional (the default)

Blank lines separate groups; groups are taken in order. A group whose **first line starts with
`ppv`** is the PPV, and the group immediately after it becomes the PPV follow-ups.

```
!mma hey babe, are you awake?

did you see what I sent?          <- f1
i'm still up if you are           <- f1.5

hellooo?                          <- f2

last chance babe                  <- f3

ppv unlock this and I'll show you <- ppv

did you like it?                  <- ppvfu1
want more?                        <- ppvfu2
```

Within a group: line 1 → `fN`, line 2 → `fN.5`, line 3 → `fN.7`. A fourth line is ignored.

`!mm` / `!mma` / `mm` / `mma` are interchangeable, with or without a colon. **The line is
optional** — with none, the first non-blank line becomes the mass.

### Prefixed

Label the lines and blank lines stop mattering; each line goes exactly where its number says.

```
!mma hey babe, are you awake?
f1 did you see what I sent?
f1.5 i'm still up if you are
f2 hellooo?
f3 last chance babe
ppv unlock this and I'll show you
```

`f` and `fu`, with or without a space or colon: `f1`, `fu1`, `f1:`, `fu 1` are all the same.

### Keyword

A line starting with an exact field name routes purely by name. Accepted:

```
!mm  !mma  mm  mma
f1  f1.5  f1.7
f2  f2.5  f2.7
f3  f3.5  f3.7
ppv
ppvfu1  ppvfu2  ppvfu3
```

---

## Comments

A line that is `--` alone, or starts with `--` **followed by whitespace**, is dropped before
parsing.

```
-- written by Sam, do not reuse before Friday
--
!mma hey babe
```

`--Name` (no space) is a **branch**, not a comment. `---` is a **fence**. Both below.

---

## Multi-line PPV captions — the `---` fence

A PPV caption containing blank lines would normally be split into separate groups. A line of
**three or more dashes** collapses everything back to the most recent `ppv` marker into one
field, keeping the blank lines as paragraph breaks.

```
ppv this one is special babe

I filmed it last night just for you

unlock it and tell me what you think
---
```

All of that becomes the single `ppv` field. Nothing spills into `ppvfu1`.

---

## Alternatives — `alt:`

An **alt** is another wording of the same follow-up. Put them inside the follow-up's group.

```
hey did you see it?
alt: did you get my message babe?
alt: still thinking about you
```

Unnumbered `alt:` — each line is its **own** alternative. This is the common case.

Numbered `altN:` — lines sharing a number join into **one multi-part** alternative. That
distinction is the whole reason numbering exists; without it two `alt:` lines are ambiguous
between two single-part alts and one two-part alt.

```
alt0: first part of alt one
alt0: second part of alt one
alt1: a different, single-part alt
```

`alt0:` is the **first** slot (they are zero-based here). The two forms mix freely; an
unnumbered `alt:` takes the next free slot. Up to 3 alts per follow-up group.

---

## Branches — `--Name`

A **branch** is a whole alternate follow-up sequence: a different wording that also implies the
*next* follow-ups. Pick a branch at f1 and f2/f3 open on that same branch.

Everything before the first `--Name` is the shared trunk. Each marker opens a branch, laid out
positionally exactly like the trunk.

```
!mma hey babe, are you awake?

did you see what I sent?

hellooo?

--BigSpender
you deserve something special
I made this just for you
ppv unlock for the full thing

--Cheapskate
last chance babe
```

Up to 3 branches per mass. A branch with nothing in a given group is skipped rather than
sending silence.

### How alts and branches behave when sending

They are **one list on the follow-up key**. Press the key:

- **no alternatives** → it sends, exactly as always; nothing appears
- **alternatives** → all of them are pasted into the chat box with `▸` marking one.
  `Tab` moves the marker, `Enter` sends the marked one, `Esc` cancels and clears the box.

Multi-part variants show their parts joined by `  |  ` (`AltStagePartSep` in
`mass_gui.cfg [Settings]`).

> **Never use `/` as that separator.** The preview is pasted into the Infloww composer and `/`
> is Infloww's command trigger — the slash-command menu opens over the box and eats the `Tab`
> and `Enter` the picker depends on. It defaulted to `/` originally; MMA migrates that old value
> to `|` once, automatically, and leaves a separator you chose yourself alone.

Picking a **branch** variant is remembered for that conversation, so f2 and f3 open on it.
Picking `main` at f2 returns you to the trunk.

---

## Prefix stripping

A leading `word:` is removed from a line's message text, so pasted transcripts do not carry
their labels into the message.

URL schemes are exempt and pass through intact: `http:` `https:` `ftp:` `ftps:` `mailto:`
`tel:` `file:`.

---

## Where it goes

Parsing fills **the tab you are currently looking at** — Mass 1, Mass 2 or Mass 3 — and clears
that tab's fields first. Nothing is written to disk until you press **save &lt;model&gt;**,
which writes all three tabs for that one model.

`Export !mma` is the reverse: it rebuilds paste-format text from the current tab's fields.
