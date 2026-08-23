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

### A mass that spans lines — `!mma` on its own line

Put the marker **alone** on the top line and everything under it is the mass, blank lines and
all, as one message:

```
!mma:

If you were my artist, how would you picture me? 🎨

Would my curves take over the entire canvas...
Or would you only sketch the parts you couldn't stop thinking about? :3

Would your artwork be bold enough to leave people speechless? ♡
```

That is **one** message. The blank lines are paragraph breaks in it, not group separators, so
nothing here becomes `f1` or `f2`.

The block ends at the first of:

| | |
|---|---|
| a `---` fence | eaten along with the block — **write one if follow-ups come after**, since positional follow-ups carry no label to stop it themselves |
| a labelled line | a field name, an `f`/`fu` prefix, `ppv`, or a `::branch` — that line names its own field |
| the end of the paste | |

```
!mma

paragraph one

paragraph two
---

late night opener              <- f1
still up?                      <- f1.5
```

`Export !mma` writes this form (with the fence) whenever the mass spans lines, so a multi-line
mass round-trips.

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

`---` (three or more) is a **fence**, not a comment — see below. `--Name` used to be a branch
marker and is not one any more (`::name` is), so a line like `--sale ends tonight` is left
alone as message text rather than being eaten.

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

## Alternatives and branches — `::name`

**One marker for both.** An alternative *is* a branch: another wording of a follow-up, which
also decides what the next follow-up says. `alt:` / `alt0:` lines and `--Name` blocks were two
spellings of that one idea and are **gone**: if you find either of them written down somewhere,
that page is describing a format MMA no longer reads.

```
::tits Would you mind if I smothered you with them?
```

`tits` is the branch name. **`alt` is not special** — it is simply the name you use when the
wording has no better one.

### Both of these are the same thing

The wording can go on the marker line, or on its own line(s) under it. Write it the way it
reads:

```
::tits Would you mind if I smothered you with them?
```
```
::tits
Would you mind if I smothered you with them?
```

Several lines under one marker are several **parts** of that branch's answer — f3, then f3.5,
then f3.7 — exactly as repeating the marker would be:

```
::tits
smother you with them
and make you beg for mercy
```

> A marker **with** text on its line does not own the line after it; that one is the trunk's next
> sub-slot. A marker with **nothing** under it says nothing at all — it does not send a blank
> line.

### Which follow-up a branch answers

The one it sits in. A marker inside a follow-up's group is an alternative to that group; a
marker under `f2.5` answers the whole of follow-up 2, because the sub-slots are parts of one
answer rather than follow-ups of their own.

A group that **opens** with a marker is the *next* follow-up — one the trunk has no wording for
— and consecutive branch-led groups are choices at that **same** step, not successive follow-ups:

```
!mma Are you needy for nakedness?

late night opener                       <- f1

which curve entices you the most?       <- f2
and be honest about it                  <- f2.5

::tits                                  <- f3, if she says tits
smother you with them

::ass                                   <- f3, if she says ass
my personal throne
```

Here the trunk has **no f3 at all**, which is correct: what goes out depends on her answer. A
sparse trunk is normal and nothing treats it as an error.

A branch keeps its identity **by name** across the whole mass, so the `::tits` under follow-up 2
is the same branch as the one under follow-up 1 — that is what makes picking it at f1 commit you
to it at f2 and f3. Names are matched case-insensitively (`::Tits` and `::tits` are one branch,
because two would be a typo that costs a slot).

Up to 6 branches per mass and 3 parts per group; past either, the extra is dropped **and
logged** rather than silently overwriting something.

### How they behave when sending

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
