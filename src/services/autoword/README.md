# autoword

Next-word suggestions while you type, accepted with Tab. Trains on the typelog
corpus — so it predicts *your* phrasing, and by construction it only ever
suggests things no hotstring already covers (see "Why the corpus is the right
training set" below).

Ctrl+Tab is the other direction: instead of the next word, it offers other words
for the one you have just typed — `touched` → `caressed`, `stroked`, `grazed` —
from a group file you own.

## Files

| file | what it owns |
|---|---|
| `config.py` | every knob, read from `userdata\autoword.ini` |
| `corpus.py` | reading the typelog logs and repairing the caret-desync damage |
| `model.py` | `Predictor` protocol + `NgramPredictor` (trigram→bigram→unigram) |
| `engine.py` | the segment buffer and the suggest/accept/cycle/reword state machine |
| `reword.py` | the Ctrl+Tab groups, and the spelling rules that inflect them |
| `renderers.py` | `Renderer` protocol + `off` / `strip` / `ghost` |
| `autoword.pyw` | service shell, key hook, and the only place concrete classes are named |

The two protocols are the point. Swapping the model or the presentation is one
new class and one line in `autoword.pyw`; nothing else in the service knows what
is behind either seam.

## Running it

```
python autoword.pyw              run the service
python autoword.pyw --train      rebuild the model from the corpus and exit
python autoword.pyw --evaluate   held-out accuracy, changes nothing
```

Or `autoword_start.vbs` for a hidden background start, like the pinger.

## Modes

Both are set in `userdata\autoword.ini`, which is written with commented
defaults on first run.

**`Render`** — `off` | `strip` | `ghost`

- **`off` is where to start.** It predicts normally but draws nothing, writing
  what it *would* have suggested to `debuglogs\autoword_shadow.log`. That
  measures accuracy against your real typing with no UI and no chance of a wrong
  suggestion costing a keystroke. Run it for a few days first.
- **`strip`** — a small always-on-top row near the message box. tkinter, never
  takes focus, anchored to the foreground window rather than the caret (which is
  exactly why it is the simple one — no accessibility API, nothing that breaks
  when the target app re-renders).
- **`ghost`** — grey text at the caret. **Not implemented**, deliberately. See
  below.

**`Predict`** — `nextword` | `completion` | `both`

`nextword` uses context and is the measured winner. `completion` ignores context
and just completes the word you are typing — kept because it is the obvious
baseline and it is useful to be able to A/B against it.

## Completing without being asked

`[Suggest] AutoCompleteChars` (0 = off, the shipped default) types the rest of a
word with no keypress when it is *obvious*: no other word in the corpus has ever
followed this context with this prefix, you have typed that many characters of
it, and it has been seen `AutoCompleteSeen` times.

Obvious is **uniqueness, not probability**. Held-out on the same 5 unseen days:

| gate | fires/day | right | net chars/day | wrong/day |
|---|---:|---:|---:|---:|
| any suggestion, 1 char — what Tab sees | 9,590 | 40.1% | −12,126 | 5,741 |
| p ≥ 0.9, 1 char | 2,141 | 62.9% | −482 | 795 |
| p ≥ 0.9, 3 chars | 2,136 | 90.4% | +2,409 | 204 |
| one continuation, seen ≥3, 3 chars | 841 | 95.4% | +1,079 | 39 |
| **one continuation, seen ≥5, 3 chars** | **609** | **97.2%** | **+808** | **17** |
| one continuation, seen ≥10, 3 chars | 391 | 98.1% | +507 | 7 |
| one continuation, seen ≥5, 2 chars | 454 | 94.0% | +669 | 27 |

Net chars/day charges a wrong completion the characters it wrote plus the
keystroke to undo it. A probability gate cannot buy its way to the top of that
table at any threshold, because p is computed over a context that may have been
seen twice. Uniqueness plus a sighting count is a different question: *is there
anything else this could be, and do I have grounds to say so.*

### It never extends a word you had finished

`do` → `does`, `you` → `your`, `leg` → `legs`, `nothing` → `nothingness`. Every
one of those is *right* by the accuracy measure above — and every one is wrong to
do, because you had finished the word and simply had not typed the space yet.
The precision column cannot see this class of mistake, which is why it needs a
rule of its own rather than a higher threshold.

`AutoCompleteOnlyFragments` (on by default) refuses them. A prefix counts as a
finished word when the Windows dictionary knows it **and** either:

- the completion only adds a suffix — `leg`+`s`, `do`+`es`, `nothing`+`ness`; or
- you demonstrably type it on its own: `you` appears 10,189 times against
  `your`'s 2,267.

Both halves are load-bearing, and each fails alone:

| | `you` → `your` | `jus` → `just` | `thi` → `this` |
|---|---|---|---|
| dictionary knows the prefix | yes | **yes** (a meat sauce) | no |
| prefix count vs completion | 10,189 : 2,267 | **22 : 1,150** | 14 : 763 |
| verdict | finished word | fragment | fragment |

The dictionary on its own calls `jus`, `wan`, `nee`, `moo` and `bod` words and
would kill your best completions. Your own counts on their own cannot help
either, because the typelog leaves truncation debris — `jus` really does appear
22 times — so the corpus is full of things that look like short words. Only the
conjunction separates them, and the separation is two orders of magnitude wide.

Costs 96 completions a day out of 615; the rest still fire at 97.3%.
`AutoCompleteNever` is the manual override for whatever the rule still gets
wrong — list the finished word, not what you type. `vocabulary.tsv` in
`userdata\autoword\`, sorted by how often you use each word, is the file to skim
when it needs adding to.

Four more things make it survivable rather than infuriating:

- **It waits for you to stop typing.** See below.
- **No trailing space, and the word stays your partial word.** Unlike Tab, this
  leaves you exactly where typing it yourself would — free to add a comma, or to
  keep typing letters and make it a longer word.
- **Finishing the word yourself is free.** The letters it typed are remembered,
  and while you type the same ones they are swallowed, because they are already
  on screen. Muscle memory does not produce `just t`.
- **Backspace immediately after takes the whole insertion back**, not one
  character of it.
- **Any backspace stops it completing until the next space.** While you are
  fixing a mistake is the worst moment to type for you, and a half-corrected
  word is exactly when a confident-looking prefix appears out of nowhere.

It never chains — one completion per word, at most.

### It waits for a gap in your typing

`AutoCompleteIdleMs` (250 by default) holds a completion until you have not
pressed a key for that long. Set it to 0 and it fires the instant it decides,
which is what turned `feeling` into `feelinging`:

pynput hands each keystroke to two callbacks on two threads. `win32_event_filter`
runs inside the low-level hook, synchronously, before the app sees the key — the
only place a key can be swallowed. `on_press`, which the engine runs on, is
*posted to a message loop* and handled afterwards, once the key is already on
screen. So the decision to complete `feel` was made while you were typing the
`i`, and the injected `ing` landed behind it: `feel` + `i` + `ing` + your `ng`.

The echo swallow cannot save that, because it is only armed once the completion
exists. Waiting for a gap can: if you have not touched a key for 250ms, nothing
of yours is in flight, and it is also the only moment you would notice a word
appear. Any key you press first supersedes the suggestion or cancels it, and
the window it was meant for is remembered, so a "pause" that is really an
Alt+Tab types nothing into whatever you switched to.

Mid-word gaps rarely exceed 200ms even at speed, so this costs few completions.
Raise it if you still get caught out; lower it if they feel late.

### Telling your keys from ours

Everything the service types carries Windows' `LLKHF_INJECTED` flag, and both
callbacks drop flagged events on sight. This replaced an "are we injecting?"
stopwatch, which ignored **every** key for 50ms after a completion — real ones
included. Those keystrokes reached the app but not the engine and not the echo,
so finishing the word yourself in that window doubled the ending. It needs
pynput 1.8 or newer for the `injected` argument to `on_press`; on anything older
the service logs a warning at startup and falls back to the stopwatch.

## Keys

Set in `[Keys]`. Both are swallowed only while a suggestion is on screen, so Tab
still tabs everywhere else.

| key | does |
|---|---|
| `Tab` | accept the highlighted candidate |
| `Shift+Tab` | move the highlight to the next candidate; wraps |
| `Ctrl+Tab` | reword the last word — see below |
| `Esc` | put the list away (never swallowed) |

The highlight starts on rank 1, so rank *k* costs *k* presses — which is what the
table above measures. Modifiers are matched exactly: with the defaults, Shift+Tab
never accepts.

All three are the same physical key, so the modifiers are the identity rather
than decoration — which is also why Ctrl is read at all. Before rewording
existed, `Ctrl+Tab` matched plain `Tab` and quietly accepted the suggestion
instead of switching tabs in the app.

`Accept` and `Cycle` must differ; one keydown cannot mean both "move the
highlight" and "take it". If they match, the service logs it at startup and turns
cycling off, leaving only rank 1 reachable — which is what `Cycle = tab` (the
default before this was wired) silently did.

## Rewording (Ctrl+Tab)

Press it on the word you have just typed and it offers other words for it. Tab
takes the highlighted one, Ctrl+Tab again moves the highlight, Esc puts the list
away, and typing anything at all forgets it. Nothing is written until you take
one.

It is the opposite end of the same feature, and the opposite trade. A completion
has to be nearly certain because it types itself; a reword is *asked for*, shows
its whole hand, and changes nothing until you choose — so it can afford to offer
the fifth-best word without having to defend it.

Swallowed only when there is something to offer. No word behind the caret, no
group for it, or a buffer we stopped trusting after a click, and Ctrl+Tab goes
on doing whatever it normally does in the app.

### The groups are a file you own

`userdatautowordeword.txt`, one group per line, comma separated, written
with a starter set on first run:

```
touch, caress, stroke, graze, brush, trace
want, crave, need, fancy, long for
tired, exhausted, drained, spent, worn out
```

Groups are **symmetric** — every word in a line offers the others, so `caressed`
gets you back to `touched` without a second entry — and they are offered in the
order you wrote them.

A general thesaurus would answer `touched` with `affected`, `moved` and
`impinged`: correct, and useless here. The words worth reaching for are the ones
that suit how you write, which is a judgement no dictionary can make and you can
make in ten seconds. So the file is the source, and cutting what does not sound
like you is the point of it.

### Why it inflects, and how it avoids `whisperred`

You do not type base forms. You type `touched`, `touching`, `touches` — so a
file of base forms alone would answer almost nothing you actually write, and
writing every group out three more times by hand is how a file like this stops
being maintained.

So every group is expanded with -s, -ed and -ing at load time. Two of those
rules are guesses: dropping a final `e` and doubling a final consonant both
depend on stress, which spelling does not record (`whisper` does not double,
`prefer` does). Rather than pick, both spellings are generated and the **Windows
dictionary** — the same one `AutoCompleteOnlyFragments` uses, sharing its cache
file — says which is a word. `whisperred`, `prefered`, `rubed` and `tuging`
never reach the list.

Irregular forms get their own line (`felt, sensed, noticed`), and a hand-written
line always beats a generated one. Phrases (`curl up`, `long for`, `over the
moon`) are offered as written and never inflected. Without a dictionary the
first guess is taken and the file is the fallback, which is logged at startup.

### It cannot replace the wrong text

A replacement is riskier than a suggestion: it deletes a measured number of
characters, so a buffer one keystroke behind your fingers would eat a letter of
the word before it. Two things make that impossible rather than unlikely —
any keystroke still in flight clears the suggestion the moment it lands, and
`swap` refuses unless the buffer still ends with exactly what it means to
replace. A stale list can be shown; it can never be taken.

The tail comes off and goes back on with the word, so `touched, ` rewords to
`caressed, ` and the caret lands where it started. Capitalisation is yours:
`Touched` comes back `Caressed`.

## What the numbers say

Held-out: trained on 18 days, scored on the 4 unseen days after them.

| strategy | keystrokes saved | precision |
|---|---:|---:|
| complete the current word after 3 chars | 9.9% | 58.6% |
| predict next word, no character typed | 8.9% | 15.4% |
| **next word, 1 character typed** | **14.8%** | **45.9%** |
| multi-word span, accept whole span | 3.4% | 11.7% |
| replay a whole repeated segment | 0.2% | — |

And with a cycleable list, accepting rank *k* costing *k* presses:

| list size | saved |
|---|---:|
| 1 | 14.8% |
| 2 | 17.0% |
| **3** | **17.6%** |
| 5 | 17.8% |

Hence `ListSize = 3`. Five buys 0.2 more.

`MinSaving` gates on characters saved rather than word length, and raising it
makes *both* numbers worse — the short words it cuts (`to`, `so`, `me`, `it`) are
the most predictable in the corpus:

| MinSaving | saved | precision |
|---|---:|---:|
| **1** | **20.5%** | **46.3%** |
| 2 | 18.5% | 37.7% |
| 3 | 12.7% | 25.0% |
| 4 | 6.0% | 14.5% |

**Why one character matters so much:** context alone is 15.4% top-1, the first
character alone is 29.2%, both together are 34.9% (44.2% at top-3). Neither
signal is usable on its own — the character collapses the context's candidate
set to one letter's worth, and that is where the whole feature lives.

Expect roughly 20% of keystrokes in the message box, and expect more than half
of what appears to be wrong. That is why `off` exists and why the accept key is
swallowed only while something is on screen.

## Why the corpus is the right training set

`snd()` output never reaches the typelog — the expansion does not pass through
the keyboard hook. Checked: zero of the 190 hotstring strings in `content\*.ahk`
appear anywhere in 22 days of logs. So the corpus is already the *complement* of
the hotstring library: a million characters of everything your expansions do not
cover. Training on it cannot produce a suggestion that a hotstring already
handles.

## Why `ghost` is not built

Infloww is an Electron app, so there is no browser-extension route, and you
cannot render into its DOM without injecting into the process — which needs it
launched with a debug flag, breaks on every update, and is a ToS question on your
main work tool. That leaves drawing grey text at the caret from outside, which
needs the caret's pixel position. Two real options:

- **UIA** `TextPattern` → `GetSelection` → `GetBoundingRectangles`. Chromium
  exposes an accessibility tree but enables it lazily, and attaching a UIA client
  makes the host app pay for it. Untested against `Infloww.exe` — that probe is
  the next step if you want this mode.
- **Compute it.** `engine.py` already knows the segment buffer, so caret x is
  `textbox_left + text_width(buffer)` once the box rect and font are measured —
  the same geometry work already done for the tab strip. No accessibility API,
  but it breaks on word wrap and zoom.

Both are plausible; neither is worth shipping on a guess. Implement `show`/`hide`
in `GhostRenderer` and set `Render=ghost` — nothing else changes.

## Known limits

- **The buffer is the segment as typed**, one string, with `words` and `partial`
  derived from it. Backspace is therefore just a shorter string, including
  across a space — the earlier word-list buffer had thrown the spaces away and
  had to go blind there, so deleting one character too many cost you every
  suggestion that followed.

- **The buffer goes quiet rather than guessing.** Arrows, Home/End, Delete,
  Page Up/Down, Ctrl+Backspace and any mouse click drop the buffer, because
  after them the service can no longer model what is in the box. A missed suggestion costs
  nothing; a suggestion computed from a stale buffer costs a wrong word in a
  message to a paying customer. This is the same reconstruction typelog gets
  *wrong*, done deliberately conservatively.

  It comes back at the **next typed space**, not the next Enter — waiting for
  Enter meant a single click cost you every suggestion in the message you were
  about to type, and clicking into the box is how you start one. After a space
  the caret sits somewhere the service watched, so the next word is known from
  its first character; the two words after that restore full context, since the
  model never looks further back than two. The first word in is effectively the
  `completion` row of the table above.

  What recovery cannot see is text to the *right* of the caret — click into the
  middle of a word and the completion lands inside it. Backspacing out of a
  recovered buffer therefore goes blind again rather than walking into it.
- **Two keyboard hooks.** typelog runs one and this runs another. It works, but
  merging autoword's prediction into `typelog.pyw` — which already maintains a
  buffer — is the obvious later consolidation.
- **The corpus repair guard is load-bearing.** `corpus.is_domain` stops the
  fusion rule shredding domain vocabulary (`alice` → `al`+`ice`, `papi` →
  `pa`+`pi`). It has been removed once and cost every proper noun in the corpus.
- **Retraining is manual.** `--train`, or `RetrainOnStart = true`. There is no
  nightly job yet.
