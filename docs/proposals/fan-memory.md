# Fan memory, and knowing which fan is open

> **Status: planned, not built.** This proposal replaces [fantools.md](fantools.md). It answers
> that brief's precondition first (§0): where the data lives, who reads it, and what deletes it.
> The other two parts follow from that. Part A is fan identity, which is most of the work.
> Part B is the memory itself.

---

## 0. The decision fantools.md asked for

fantools.md was right that a durable store of what named people said breaks the rule the
activity tracker was built on. **The shift recorder has already crossed that line.**
`userdata/shiftlog/chats/<account>/<fan>.json` is a per-fan transcript with spend and panel
history. So the question is no longer whether to keep fan data. The question is how to keep it
on purpose.

| Question | Answer |
|---|---|
| Where | `userdata/fans/<account>/<fan_id>/`, which is outside `activity/` and outside `shiftlog/`. The shift log stays the raw source, and fan memory is derived from it. |
| Who reads it | MMA processes on this machine only. Nothing in it is sent to a cloud model. The LLM that extracts facts is the local Ollama one ([local-ai](../../src/services/llm/)). |
| What deletes it | A fan who has not been seen for **N days** (setting, default 180) is purged by a sweep at startup. "Forget this fan" in the viewer deletes the folder and adds the fan's id to a tombstone list, so a later `--rebuild` does not bring them back. Deleting an account folder removes everything for that account. |
| Accounts | Each account is a hard wall. A fan who subscribes to two creators is two unrelated records. Data never crosses accounts. |
| Export | Training exports (TestFlow `export.py`) take facts only after scrubbing them with the corpus secrets scrub. Handles and names are replaced with placeholders. |

This goes into [docs/decisions.md](../decisions.md) as its own entry **before** any code, as
§8 did for the tracker.

---

## Part A: Identity — which fan is this?

### What goes wrong today

The recorder files each chat under the name **OCR'd from the chat header**. The 333 folder
has **633 fan files**, and only 30 of them are already flagged as having several name
variants. Most duplicates were never caught. Two separate problems are mixed together:

**1. OCR noise.** The same text is read differently from one frame to the next:
`Kit I Notes(Kit` / `Kit I Notes:Kiti` / `Kit I NotesiKit`, and `Dimitri(tba<57` / `Dimitri-ba-57i`.
Most of the errors are at **the `(`**, which is read as `:`, `i`, `.`, `B'` or `-`.

**2. Chatters rewrite the name.** The header is `<custom name>(<fan's own display name>`.
The custom part is written by the agency's chatters. It is a **note field**, not a name:

- `$171 Dan(Dan`: a spend tag
- `BROKE AF AF AF`, `BROKE ATM VIP in progress I Robby SAD BO`
- `CHECK NOTES Bryan(Bryan`, `Austin CHECK NOTES`
- `Dbcooper77` → `Dustin(Dbcooper77`: renamed once the fan's real name was learned

Each rewrite currently creates **a new fan**. No OCR fix can solve this, because the text
really did change.

### The way out: stop using the header as the key

**The chat list shows every fan's `@handle`** (see `tools/ui-research/Whole UI.png`):
`Alex Doe @u100000001`, `Mr. Example @mrexample88`. That gives us:

- an identifier that **chatters cannot edit**
- an easy OCR target: a small, known character set (`@[a-z0-9._]+`), and often `u` + digits
- for a `u<digits>` handle, OnlyFans's own numeric user id, which never changes

The handle has two limits:

- A fan *can* set a custom username, which replaces `u100000001`. This is rare, and the panel
  fingerprint and chat continuity (below) carry the identity across the change.
- The row may be scrolled out of the list or truncated (`@gol...`). The list is sorted
  newest-first, so the open chat is almost always visible, but not always.

So the handle is the **strongest piece of evidence**, not the only one.

### Resolving identity from several pieces of evidence

Each read gives several clues. A resolver weighs them against the known fans **of that
account**:

| Clue | Where it comes from | Strength | Notes |
|---|---|---|---|
| `@handle` | the list row for the open chat | **decisive** | match row ↔ header by display name, or by the highlighted row if Infloww draws one (unmeasured) |
| Chat continuity | `shiftlog.merge` lines the read up with a known history | **strong** | already built. Two text anchors in the same order are hard to get by chance |
| Panel fingerprint | Insights: *Highest spend + its date*, subscription *cost + duration + expiry*, total spend | **strong** | `$59.44 PPV \| Jul 15, 2026` is close to unique. Spend only rises, and duration only grows |
| Fan's own display name | the part inside `(...)` in the header | medium | the fan can change it, but rarely |
| Custom name | the part before `(` | **weak** | chatters rewrite it. Store it as a tag (below) and never match on it alone |
| Avatar | the 30px circle in the list row and the chat | medium | aHash, like `keep_media`. The default grey silhouette gives no information |

The rules mirror the shift log's `islands`:

- **Decisive or strong + agreeing** → filed under that fan.
- **Conflicting** (handle says A, chat continuity says B) → do not guess. File under
  `_unresolved/` with every clue, and surface it for a human.
- **New** (no clue matches anyone) → new fan id. The id is the handle if it was read, otherwise
  a provisional `p-<hash>` that becomes the handle once one is seen.

`canonical_names()` in [shiftlog.py](../../src/services/llm/shiftlog.py) is an early form of
this with two clues (name similarity + total spend). The resolver replaces it and runs in **both**
the live recorder and `--rebuild`. Today only the rebuild folds names, which is why the live
files are wrong until a rebuild.

### Chatter tags are data, not names

The custom name is the agency's real note-taking system, so keep it. Split it into tokens and
record each change as an event:

```
fans/333/u23350102/tags.jsonl
{"at": ..., "custom": "$171 Dan", "tags": ["$171"], "name": "Dan"}
{"at": ..., "custom": "BROKE AF Dan", "tags": ["BROKE AF"], "name": "Dan"}
```

Price tags (`$171`), status tags (`BROKE`, `VIP`, `SAD BO`) and `CHECK NOTES` come from a
small vocabulary to be collected from the existing files. Silly confirms what each one means
(open question 2). A tag change is also an **outcome label**: the moment a chatter types
`BROKE` is when they decided the fan was not worth the time. That is the exact thing
fantools.md wanted a model to learn.

### Making the OCR itself better

Even with the handle as the key, the names must be read cleanly. In order of payoff:

1. **Split at the `(` by pixels, not by text.** The bracket is a known glyph at a known height.
   Find it in the binarised band, then OCR the two halves separately. This removes the largest
   group of errors outright.
2. **Vote across frames.** The chat reader sees the same header dozens of times per visit.
   Keep every read for the visit and take a per-character consensus: align the strings, then
   a majority vote at each position. Noise that differs between frames goes away. A name that
   *changes* mid-visit, after settling, is a real rename and becomes an event.
3. **Upscale the band 2–3×** before recognition. Names are ~14px tall at the clone's scale, and
   PP-OCRv3 recognises better at ~32px.
4. **Recognition only, no detection, on known bands.** The header and list rows are at known
   positions. Running only the recognizer on the band avoids the detector's edge-dropping,
   which `CHUNK_PAD` currently works around.
5. **Constrain the handle.** Lowercase, `[a-z0-9._]`, starting with `@`. Fix confusions toward
   that set (`l→1` inside `u\d+`, `O→0`).
6. **Train a reader on Infloww's own font (the big step).** [inflowwclone](../../tools/inflowwclone/)
   already renders Infloww faithfully. Render **millions of synthetic headers and list rows**:
   random names, emoji, `$tags`, brackets, every DPI scale. Every image comes with its correct
   text for free. Fine-tune the PP-OCR recogniser (or a small CRNN) on that. Do the work again
   on real crops from the OBS shift recordings, labelled by frame voting. This is how to get
   from "usually right" to "right".

### How to know it worked

- **Labelled set:** 200 header crops + 200 list-row crops from real recordings, labelled by hand
  once in a small tool that shows the crop and a text box. These are the metrics forever after.
- **Name read accuracy**, exact match, before and after each of steps 1–6.
- **Fan count after `--rebuild`:** 633 files in 333 should fall toward the real number of fans.
  Silly can give a rough count from the Infloww list.
- **Zero cross-merges** on a hand-checked sample of 50 fans. Merging two fans is far worse than
  splitting one. A split can be merged later, but a merge corrupts both memories.

---

## Part B: Per-fan memory

### Three layers, like the shift log

Raw and append-only stays the source of truth. Everything else can be rebuilt from it.

```
userdata/fans/<account>/<fan_id>/
  ids.json        handle, every display name, every custom name, avatar hash, merges
  ledger.jsonl    FACTS FROM THE SCREEN  (deterministic, no model)
  notes.jsonl     FACTS FROM THE WORDS   (model-extracted, each with its source turn)
  tags.jsonl      chatter tag history (Part A)
  card.json       the digest: derived, regenerated, never hand-edited
```

**Layer 1: ledger (screen facts, exact).** This is everything the recorder already reads,
re-keyed by fan id:

- spend: total, last, highest, PPV vs tip, with each change timed (`panel_log` already has this)
- **every PPV:** price, paid/unpaid, when sent, when bought, who sent it (mass vs chatter), and
  the **media aHash** (`keep_media` already crops and hashes it)
- subscription: cost, duration, expiry, auto-renew on→off (a churn warning)
- reply timing: when he writes, how fast he answers, which gives an **inferred timezone**
  (the panel says "Local time: Unknown" for most fans)

**Layer 2: notes (word facts, extracted).** After each shift, the local model reads each fan's
new turns and outputs facts in a fixed schema:

```json
{"kind": "kink", "value": "feet", "turn": "t_0412", "said": "fan", "conf": 0.8, "at": ...}
{"kind": "promise", "value": "she said she'd send the shower set Friday", "turn": "t_0598", "said": "her", ...}
{"kind": "life", "value": "works nights, truck driver", "turn": "t_0233", ...}
{"kind": "mood", "value": "upset about price of last PPV", "turn": "t_0601", ...}
```

The rules that keep it honest. They are the same as the corpus repair pass's traceability guard:

- **Every fact cites a turn id.** If the quoted turn does not contain support for it, the fact
  is dropped. No citation, no fact.
- **Facts are superseded, never overwritten.** A new value for the same `kind` marks the old
  one `until: <time>`. "Was married, now divorced" stays readable.
- **`said: her` facts matter as much as his.** Promises she made and lies she told
  ("I'm in Miami") are what a co-chatter or the model must not contradict.
- Kinds are a closed list, starting with: `name`, `kink`, `keyword` (his own words to mirror,
  per [chatting-process](../chatting-process.md)), `life`, `promise`, `boundary`,
  `price_reaction`, `mood`. Anything else is not stored.

**Layer 3: card (the digest).** This is what people and models actually read. It has five
lines at most, rebuilt when the ledger or notes change:

```
Dustin (@dbcooper77) · $337.95 lifetime · top 5% · last bought 2d ago ($33, feet set)
Seen: sets 3, 7, 14 (paid), 15 (unpaid ×2, won't buy)  ·  ceiling ~$35
Into: feet, being told what to do  ·  says "fr", "lowkey"  ·  evenings EST
⚠ She promised the shower video Friday  ·  ⚠ upset about $49 PPV last week
Tags: CHECK NOTES (since Oct 20)
```

### Who reads the card

1. **The chatter.** An overlay that follows the open chat, read in the background like the stats
   overlay. Behind a `^!` key ([no bare F-keys](../../userdata/hotkeys.default.ini)), with a
   `FEAT()` gate, and listed in the Tools window, not General.
2. **The co-chatter / Live Trainer prompt.** The card goes above the transcript. This is the
   cheapest large gain available. The model stops pitching sets he already owns and stops
   inventing PPVs (the Live Trainer "bikini" failure).
3. **The media ledger feeds the PPV planner later.** "Unseen by this fan" is the filter the
   content ladder needs. That needs a content library mapping aHashes to sets, which is a
   separate piece of work.

### How to know it helps

- **Fact precision:** each week, Silly marks 30 random notes right or wrong in the viewer. Target
  ≥90% before the card goes into prompts.
- **A/B in Live Trainer:** the same chats drafted with and without the card, rated blind on
  Silly's 1–10. If the card doesn't move the rating, it doesn't ship into the prompt.
- **Resend check:** count PPVs sent to a fan whose media ledger already had that hash. That
  number should go to zero.

---

## Order of work

Each step is useful on its own, and no step depends on a later one.

| # | Step | Done when |
|---|---|---|
| 0 | decisions.md entry (§0) | Silly has read and agreed to it |
| 1 | Labelled crop set + scoring script | there is a baseline name accuracy number |
| 2 | Bracket split + frame voting + upscale (OCR 1–3) | accuracy rises on the labelled set |
| 3 | Read the chat list rows → handle for the open chat | handle read on ≥90% of real reads |
| 4 | Resolver (handle / continuity / fingerprint), live + rebuild, `_unresolved/` | 333 fan count falls; zero cross-merges in the sample |
| 5 | Merge/split buttons in Shift Viewer; every human fix is saved and replayed by rebuild | Silly can fix any wrong identity in two clicks |
| 6 | `fans/` ledger + tags + card (screen facts only, no model) | the card shows for the open chat |
| 7 | Card into the co-chatter prompt; A/B in Live Trainer | rated better, or reverted |
| 8 | Notes extraction (local model, cited) + weekly spot-check | ≥90% precision |
| 9 | Synthetic-font OCR training (OCR 6) | only if 2–4 leave errors that matter |

Steps 1–6 use no model and no new hardware.

---

## Open questions for Silly

1. **Does Infloww highlight the open chat's row in the list?** If it does, the handle
   comes straight from that row. If it doesn't, the row is found by matching the display name.
   (Fansly draws a marker only on the selected row. Infloww has not been measured.)
2. **The custom-name tags:** `$171`, `BROKE AF`, `VIP in progress`, `SAD BO`, `CHECK NOTES`.
   Are these an agency convention with fixed meanings? Is there a list?
3. **The Notes tab** in the right panel is unmeasured. If chatters keep real notes there,
   they are the best source for Layer 2, because they're already written by humans, and the
   recorder should read that tab when it is open.
4. **Retention:** is 180 days without seeing a fan the right purge point?
5. **Should other chatters' sessions feed the same memory?** The recorder only sees this PC's
   screen, so memory only covers fans opened here.
