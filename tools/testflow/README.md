# TestFlow

**An AI-training tool** (since 2026-10-16). A local clone of Infloww's Messages
window where you chat with the AI and annotate everything, so your judgement
becomes training data. Nothing leaves the PC, and nothing here reaches typelog or
the corpus.

Start it from the Tools window ▸ AI suite, or `pythonw src\services\runner\runner.pyw --start testflow`. Two windows open:

| Window | What it is |
|---|---|
| **Infloww Messages - TestFlow** | The clone. You chat here: Enter sends, Shift+Enter is a new line. Annotation cards and the review appear here. |
| **TestFlow Lab** | Who you play, starting chats, AI settings, the rating scale, your data and Export. |

Needs Python with `pywebview` (`pip install pywebview`) and Ollama.

## Who you play (Lab ▸ You are)

- **The fan** (the AI plays her): this trains HER. After each of her replies a card
  asks for a 1-10 score, quick tags, what was wrong, and **what you'd have sent**.
  With "Use my version in the chat" on, your rewrite replaces hers, so the
  conversation carries on from a good message (the original is kept).
- **Her** (the AI plays the fan): your messages are gold examples of real
  chatting, with all your MMA tools working as in Infloww. Click one of your
  messages to say **why** you sent it. His messages get a realism card, which
  trains the fan simulator.

Click **any** message to annotate it, not just the newest.

## How a chat starts (Lab ▸ Start a chat)

| Opener | What happens |
|---|---|
| Cold open | Nobody has written. Whoever you are goes first ("Make him reply now" lets the AI fan open). |
| New subscriber | Her automated welcome message ("hi (with bad intentions) 😈", editable) goes first. |
| Reply to a mass | He replies to a mass: paste one, or leave it blank for one of your real `!mma` openers from `userdata/mass_archive.txt`. |
| Random | One of the three, with a random persona and name. |

## Rating

The 1-10 scale is fixed and shown in the Lab and on hover (`TF.SCALE` in
`ui/common.js`). 8+ means "good enough to copy" and 7+ means "good enough to prefer"
in export. **End & review** (clone header or Lab) scores the whole conversation:
overall, fan realism, how it ended, best and worst message, what went well, what
went wrong, and the lesson. Then the chat closes.

## Your data

Everything is in `userdata/testflow/`: `ratings.jsonl` (every annotation and review,
append-only), `state.json` (the chats), `archive/` (deleted chats, kept whole).
**Export** (Lab, or `python export.py`) builds `export/`: good examples (SFT),
better/worse pairs (DPO), scored messages, your reasons, wrong-move verdicts and
reviews. What each file is for is at the top of `export.py`.

### Advanced: blind drafts and ratings

Folded away in the Lab. Write his message there, set the mode (filler or PPV
caption), tier, content and an optional direction, tick one or more models, and
press **Draft her replies**. The drafts come from the same pipeline as the suggestion
key (`src/services/llm/suggest.py`: the same prompt file, examples and rule checks),
shuffled and labelled A, B, C, with the models hidden until you send one. Rate each
1–5, edit one if you want, and **Send this**.

Two 12B models don't fit in 16 GB of VRAM together, so drafting from both means
Ollama loads them one after the other.

### Agent decides (the default)

**Ask her agent** first reads the chat (`src/services/llm/nextmove.py`, prompt in
`prompts/nextmove.md`) with the first ticked model, and shows:

* **Interest** 1–5, his mood, and the words of his it judged by
* **Next step**: tease, keep sexting, pitch a PPV, bump the PPV, talk normally,
  aftercare, or hand to the chatter, with a one-line note on how

Then it drafts that step: a PPV caption for a pitch (bundle content blank = the
next rung of the ladder), filler for the rest, nothing for a hand-off. Judge the
read with the buttons under it (interest really lower / right / higher, step
right / wrong and what it should have been, a note). Tick **Ask her agent once I
go quiet** and it runs by itself after you send, using the same pause as the AI
fan. Filler and PPV caption skip the read, as before.

## The Arena (both sides AI)

Tools window ▸ AI suite ▸ **Arena** (or `runner.pyw --start arena`) opens **TestFlow Arena**:
the AI fan against her AI, for watching what actually works. Its own process,
server and state (`userdata/testflow/arena.json`), so it runs beside TestFlow.
Its title never contains "Infloww Messages", so MMA's readers ignore it.

* **Play** and they take turns until you pause, "Stop after N turns" is reached,
  or her side hands a message to you (✋). **Next turn / Fan now / Her now** step once.
* **Type as either side**: Enter sends as her, Shift+Enter as the fan, Ctrl+Enter
  is a new line. With **They answer** ticked, the other side replies once while
  paused. **PPV…** sends a locked PPV as her (content, price, what it shows); the
  fan buys or passes in character, and ✓/✗ on the PPV overrides him.
* **Hover a message**: ✎ Edit (Save, or **Save & replay from here**, which cuts
  what came after), ⟲ Re-roll (that side writes the turn again), ✂ Cut after
  (rewind), ⑂ Fork (new match from here), 👍/👎 with a note, 🗑.
* **Cut branches** (right): every cut, re-roll and replay is kept; **Restore**
  swaps a branch back in and cuts the current one, so nothing is ever lost.
* **Her engine**: *Co-chatter* (`prompts/cochatter.md`, in the voice of the card
  you pick; PPVs are yours to send, "Next PPV" makes her set one up) or *Agent*
  (nextmove + `sexting.md`, which pitches PPVs itself). **Direction** steers her
  next reply only.
* **Score** (right): texts, words per text, PPVs bought/sent, earned, handoffs,
  your edits and thumbs.

Every edit, cut and thumb goes to `userdata/testflow/arena.jsonl` with the chat
before it: an edit is a better/worse pair, like TestFlow's rewrites.

## Where things go

Everything stays in `userdata/testflow/` and **nothing reaches typelog or the
corpus**: TestFlow runs as `pythonw.exe` and typelog only records `infloww.exe`.
An AI-written fan line must never train autoword.

| File | Contents |
|---|---|
| `state.json` | Chats and settings |
| `ratings.jsonl` | One line per rating or send: the draft, its model, the settings, the chat it was written for, your rating, whether you sent it and what you sent. Newest line per draft wins. Lines with `"kind": "read"` are your verdicts on the agent's read; newest per run wins. |

## How MMA sees it

* The window title contains **"Infloww Messages"**, which is what MMA's screen
  readers look for. If the real Infloww is also open, the readers take whichever
  matching window is in front.
* **Autoword** is let in by title: `[Scope] Titles = TestFlow` in
  `userdata/autoword.ini` (the default).
* The window is drawn by the shared Infloww clone, `tools/inflowwclone/` (served
  at `/ic/`), which the Shift Viewer uses too. The pixel contract (which colours
  mean what, where the dividers must be) is at the top of its `clone.css`.
  Verified 2026-10-22 on a 1920x1032 capture: `transcript.find_layout` gives the
  reference pane (401,135 1237x727) at scale 1.0, every bubble reads on the right
  side, one kebab per message of hers, the active account pill on rows 9..46.

## Files

| File | |
|---|---|
| `testflow.pyw` | Entry point: the two windows |
| `arena.pyw`, `arena.py` | The Arena: its window, its server and state |
| `ui/arena.*` | The Arena page |
| `server.py` | Local server on 127.0.0.1, state, the JSON API, the fan's timing |
| `ai.py` | Her drafts (via suggest.py) and the AI fan |
| `prompts/fan.md` | The AI fan's prompt; edit freely, read on every reply |
| `personas.json` | The fan personas |
| `ui/` | `clone.html`/`clone.js` (TestFlow's state -> the shared clone, plus the rate card and review), `tf.css` (those overlays), `lab.*` (the controls), `common.js` |

Run `python testflow.pyw --browser` to open the two pages in a browser instead,
which is handy for debugging the UI.
