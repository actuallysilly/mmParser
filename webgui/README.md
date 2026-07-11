# MMA webgui

Standalone browser tools that sit alongside the AHK GUI. No server, no build
step — each is a single `.html` file you double-click open. They autosave to
`localStorage`, so refreshing never loses your work.

| File | What it's for |
|------|---------------|
| `draft_editor.html`    | Compose masses in a form, **save named drafts** for reuse, one-click into MMA. |
| `archive_viewer.html`  | Load `mass_archive.txt`, browse/search every past mass, one-click any of them back into MMA. |
| `branching_editor.html`| Visually build branching (fork/merge) flows — see [Branching Flow Editor](#branching-flow-editor) below. |

## One-click import into MMA

The draft and archive tools each have two buttons:

- **Copy for MMA** — plain copy. Paste into MMA's *Paste block* box yourself and hit **Parse**.
- **Send to MMA ▸** — copies the text with a hidden `#MMA-IMPORT#` tag on the first line.
  While `mass_gui.ahk` is running it watches the clipboard (`OnClipboardChange`),
  spots the tag, strips it, and runs the same auto-parse path as the Discord
  import — so the mass lands in the panel with a single click. If nothing
  happens, make sure the MMA panel is actually running (and reloaded since this
  feature was added).

Whether *Send* also auto-saves to a model or pops the save-target prompt follows
your **Fast parse+autosave** setting in MMA, exactly like the Discord import.

### Draft editor

The right pane is an **editable textarea** holding the exact **positional text**
MMA will parse — it's the source of truth for Copy/Send/Save. Two ways to work:

- **Write it at once** — just type (or paste) the whole mass straight into the
  box. That's the fast path if you compose masses in one go.
- **Use the fields** — fill the mass, up to three follow-ups (each with optional
  `.5`/`.7` extra lines), a PPV message (multi-line is fine), and up to three PPV
  follow-ups; the box rebuilds from them live.

The moment you hand-edit the box it "takes over" and field edits stop overwriting
it (so you never lose what you typed). **↻ from fields** discards those raw edits
and rebuilds from the fields again. Warnings appear above the box (in field mode)
if you leave a gap the positional format can't represent — e.g. `fu1.7` filled
but `fu1.5` empty, which would shift up a slot.

- **Save draft** (Ctrl+S) keeps the current form under its name in the sidebar;
  click any saved draft to reload it. **+ New draft** starts a blank one.
- **Export .json** / **Import .json** move your whole draft library between
  machines or share it.
- **Ctrl+Enter** = Send to MMA.

### Archive viewer

Click **Load archive…** (or drop the file on the page) and pick
`mass_archive.txt` from your MMA folder — browsers can't read it on their own,
so you choose it once per session. Every entry is listed newest-first with its
timestamp and model; filter with the search box, arrow-key through them, and
**Send to MMA ▸** any one back into the panel. (It parses the archive with the
same fixed logic MMA now uses, so it shows *all* entries, not just the last.)

---

# Branching Flow Editor

A standalone browser tool for visually building branching mass-message flows —
follow-ups that fork based on the client's expected reply, and can merge back
into a shared continuation. This is separate from the AHK GUI; it only
produces a text block. Turning that block into hotkeys is a separate step
(not built yet).

## Running it

No server, no build step — just open the file:

```
webgui/branching_editor.html
```

double-click it, or open it in a browser directly. It autosaves to
`localStorage` as you work, so refreshing the page won't lose your graph. Use
**Save .json** / **Load .json** to keep a portable copy or share a flow with
someone else.

## Model

There's always exactly **one root node** — the `!mma` opener. It can't be
deleted or reassigned; everything else in the graph descends from it.

Every other node sits at one of seven fixed **stages**, picked from the
dropdown in its header:

```
fu1      stage 1
fu2      stage 2
fu3      stage 3
ppv      stage 4
ppvfu1   stage 5   (sent after the ppv unlocks)
ppvfu2   stage 6
ppvfu3   stage 7
```

`ppvfu1`/`ppvfu2`/`ppvfu3` match `ppv_f1`/`ppv_f2`/`ppv_f3` in `1_mass.ahk` —
the follow-ups sent after the client opens the ppv, distinct from `fu1-3`
which come before it. **Every stage past root is optional**: a flow can go
straight from root to `ppv` with no fu's at all, and can end at `ppv` with no
`ppvfu`'s. The number of fu's (or ppvfu's) present is just whatever you draw —
nothing pads it out to a fixed count.

An edge should always point from an earlier stage to a later one (root → fu1
→ fu2 → fu3 → ppv → ppvfu1 → ppvfu2 → ppvfu3) — it's fine to skip a stage
(e.g. fu2 straight to ppv), but never go sideways or backward. Edges that do
are drawn in red as a warning.

- **Fork** = more than one edge out of a node. Each outgoing edge is labeled
  with the client reply that sends things down that path (e.g. `blue`,
  `yellow`, `asks price`); leave it blank if it's the only/default path.
- **Merge** = more than one edge into a node — several branches converging
  back onto the same shared continuation. Nothing special has to be done to
  merge; just point more than one edge at the same node.
- A **branch tag** (the text box next to a node's stage dropdown) names an
  alternate version of that stage — e.g. two `fu1` nodes, one tagged `blue`
  and one tagged `yellow`, both fed by edges out of root. Leave it blank for
  the "main" path at that stage.
- A branch can be as short as a single node — an alternate `fu3` for one
  particular reply that immediately merges back into the shared `ppv` — or it
  can run its own `fu1 → fu2 → fu3 → ppv` all the way to a separate ending.

This is the generalization of the old two-way "Or-Or" flow (`!mma blue or
yellow` → one branch per option) into an arbitrary tree: any number of forks,
re-merging wherever you want, closer to a git branch/merge graph than a fixed
A/B split.

### Forking at an edge

Hover any edge and a small **+** button appears next to it (opposite the **×**
delete button). Click it to fork right there — it asks for a branch label and
adds a new alternate node at the same next stage, wired from the same source
node. This is the "in the more complicated cases we fork at an edge and ask
which branch to follow" case: e.g. hovering the `fu2 → fu3` edge and forking
with label `asks price` adds a second `fu3` (tagged `asks price`) fed from the
same `fu2`.

The canvas lays out in columns by stage (root, fu1, fu2, fu3, ppv, ppvfu1,
ppvfu2, ppvfu3), with each branch kept in its own horizontal lane —
**Auto layout** re-runs this whenever things get messy.

## Text panel

The right-hand panel is a live, editable mirror of the graph — not a one-shot
export dialog. Whenever the graph changes (and the panel isn't focused, so it
never clobbers something you're mid-paste on), it regenerates the text below.
Edit it directly or paste a whole new flow over it, then hit **Apply ▸ graph**
(or `Ctrl+Enter`) to rebuild the graph from it. **Copy** grabs the current text
for pasting elsewhere. **Save .json** / **Load .json** in the toolbar are a
separate, full-fidelity save (keeps node positions) for backups/sharing.

Applying accepts **two** input shapes:

1. **The graph format** described below (`[id]` blocks, `->` edges) — detected
   whenever the pasted text contains a `[...]` line or a `->` line.
2. **A plain flat paste** — the everyday "copy straight out of Discord" format:
   an optional `!mma`/`mm` prefix on the first line, then just blank-line-
   separated paragraphs, no markup at all. Whichever paragraph first starts
   with `ppv` becomes the `ppv` node (that prefix gets stripped); if none do,
   the last paragraph is treated as `ppv`. Up to 3 paragraphs *before* it
   become `fu1`/`fu2`/`fu3` — however many are actually there (0-3; e.g.
   `text` / `text` / `ppv` is 2 fu's and a ppv, not padded to 3). Up to 3
   paragraphs *after* it become `ppvfu1`/`ppvfu2`/`ppvfu3`, same optionality.
   Overflow beyond 3 on either side folds into the last fu/ppvfu instead of
   being dropped.

   Two markers apply here (and, for the comment marker, in the graph format
   too):
   - A line starting with `--` (but not `---`) is a **comment** noting the
     client's expected reply — stripped entirely, never sent. Handy for
     leaving yourself a note in a flat paste without switching to the
     `[id]`/`->` format just to label a branch.
   - A lone `---` line **folds that paragraph into the previous one** instead
     of starting a new stage. It has to sit in its own blank-line-separated
     paragraph to do this (that's what makes it "a new paragraph" to fold in
     the first place) — use it to keep a multi-paragraph `ppv` (or any
     message) as a single send instead of it spinning off extra `ppvfu`
     stages — e.g.:
     ```
     ppv Here's the deal...

     ---
     One more paragraph, still the same ppv message.
     ```

   This is the classic linear `opener -> fu1 -> fu2 -> fu3 -> ppv -> ppvfu1
   -> ppvfu2 -> ppvfu3` flow — pasting it in gives you a straight chain to
   start branching off of.

## Export format

Here's what **Apply** produces from the graph — it walks from the root node
and prints one block per node:

```
!mma Hey, into blue or yellow?
-> fu1 : blue
-> fu1_yellow : yellow

[fu1]
Nice, blue's a great pick 😏
-> fu2

[fu1_yellow]
Yellow's fire too 😈
-> fu2

[fu2]
You still around? 👀
-> fu3
-> fu3_price : asks price

[fu3]
Ready for the good stuff?
-> ppv

[fu3_price]
It's just $20 for full access
-> ppv

[ppv]
Here's something special just for you...
-> ppvfu1

[ppvfu1]
No rush, but let me know what you think 😘
```

Rules, if you're hand-editing or writing a parser against this later:

- The `!mma ...` line is always the root node; everything after `!mma ` on
  that line is the first line of its message text.
- `[id]` opens a block for any other node. The id is one of
  `fu1`/`fu2`/`fu3`/`ppv`/`ppvfu1`/`ppvfu2`/`ppvfu3` (the node's stage),
  optionally suffixed with `_<branchtag>` when the node has a branch tag set,
  deduplicated if two nodes collide. `start` is reserved as the alias for the
  root node when referenced by an edge.
- A block's message text is every line after its header up to the next
  `[id]`/`!mma` header, or a line starting with `->`. Blank lines *inside*
  that range are part of the message (multi-paragraph messages keep their
  spacing); blank lines are only a block *separator* when they sit between
  a block's last `->` edge and the next header — they're cosmetic there,
  not load-bearing.
- `-> id` is an unconditional/default edge to `id`. `-> id : label` is
  conditional on the client's reply matching `label`.
- Nodes unreachable from root are still exported (at the end), so you don't
  lose drafts, but the tool warns about them before you copy the text out.
- Avoid starting a message line with `[` or `->` — the parser will mistake it
  for a header/edge line.

Applying either format runs a fresh auto-layout, since positions aren't part
of the text — useful for round-tripping something you exported earlier, or
hand-writing/pasting a skeleton and loading it in to keep building visually.

## What this doesn't do (yet)

This tool only produces the text block above. Parsing that block into actual
AHK hotkeys/hotstrings — deciding which key sends which branch — is a
separate piece of work, not implemented here.
