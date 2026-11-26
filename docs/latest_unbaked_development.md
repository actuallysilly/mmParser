# Latest unbaked development

Written 2026-11-02. Covers the six features built between 2026-10-30 and 2026-11-02.
For each one: what it does, what has been proven, what hasn't, and what to try next.

The evidence comes from `debuglogs\error_log.txt`, the files each feature writes,
`D:\ShiftRecordings`, and the offline `--test` runs done today.

## At a glance

| Feature | Key | Used live? | Offline tests | Verdict |
|---|---|---|---|---|
| MM Gatherer | `^!k` in Discord | **Never** | 15/15 (parser only) | Unbaked: built today, never run |
| Sales tally (previous shift) | `^!s` | **Never** (no `sales_tally.txt`) | all ok | Unbaked: works on one screenshot only |
| Purchase sound | automatic | Yes, 262 popup rings since 10-30 | all ok | Works. Has a few rough edges |
| PPV library + picker | `^!p` | **Never** (no `ppv_picks.jsonl`) | none | Unbaked: library last built 10-30 |
| OBS shift auto-record | automatic | Partly | n/a | **Missed the whole 11-01 shift** |
| Unread ping | automatic | Yes, 70 pings | all ok | Works. Threshold untuned |

---

## 1. MM Gatherer (2026-11-02)

**What it does.** You press `Ctrl+Alt+K` in a Discord channel. It scrolls to the
channel's first message, OCRs every screen, and saves the mass-shaped messages to
`userdata\gathered\<channel>.txt`, oldest first. Pressing the key again stops it.

**Proven.** It parses and loads. The offline test passes 15/15: it feeds fake OCR
frames through the logic that finds headers, splits paragraphs, waits for a whole
message, applies the mass filter, writes the file and skips duplicates.

**Not proven: everything that touches the real Discord window.** Discord was minimized
while it was built, so none of these have run once:
- **The scroll.** It posts `WM_MOUSEWHEEL` to Discord in the background. If Discord ignores
  that, the run ends after about 4 frames with "the channel stopped scrolling".
- **The pane box.** The message area (left 460, top 80, minus 260 on the right and 90 at
  the bottom) is a guess.
- **The header pattern.** It expects "Name Today at 3:04 PM". A different date format, or
  a role tag OCR'd onto the name, means no message is ever recognised.
- **Paragraph detection** (a gap of more than about one line counts as a blank line) has
  only seen fake numbers.

**Known limits, by design.** Emojis are lost to OCR. Several messages from one person within
a few minutes come out as one entry. A mass taller than the window is saved marked
`TRUNCATED`. Text inside images isn't read.

**Test it.** Open a mass channel with Discord not minimized, press `^!k`, and let it run.
Then open `debuglogs\mm_gatherer_frames.txt`, which holds every screen it read, and
`userdata\gathered\`.

## 2. Sales tally: total the previous shift (2026-11-02)

**What it does.** You open Infloww Messages ▸ Notifications ▸ Purchases and press `^!s`.
It scrolls the list, credits your sales until someone else answers 3 cards in a row,
sets MPPV prices apart, and shows a total with a Copy button.

**Proven.** `sales_tally.py --test` passes today. That covers the stop rule and one
real screenshot (`testdata\purchases_panel.png`, 11 cards, $787.69 + 4×$20 MPPV)
scrolled through a fake viewport.

**Not proven.**
- **It has never been run on the live panel.** `userdata\sales_tally.txt` doesn't
  exist, and every run appends to it.
- **Real scrolling.** Card-merging by overlap has only seen the fake viewport, never
  Infloww's own scroll, its lazy loading, or a list longer than one shift.
- **Geometry at other zooms or window sizes.** It measures the dividers each frame, but
  only at your current zoom. Infloww is 3441x1381 live, while most automation assumes
  1920x1032.
- **MPPV prices.** The `[SalesTally] Mppv<slot>` lists start empty until you fill them, so
  every MPPV sale gets counted as a normal sale.

**Test it.** After a shift, open Purchases and press `^!s`. Compare the total against the
Infloww earnings for the same hours.

## 3. Purchase sound (2026-10-30)

**What it does.** It rings when Infloww's top-right "has purchased your message"
popup appears, for any fan.

**Proven, live.** It has rung 262 times off the popup (28 on 10-30, 121 on 10-31, 85 on
11-01 and 38 so far today), on real sales like "Rene $198.00" and "Tremelo $39.00". The
offline test passes.

**Rough edges seen in the log.**
- **49 of the 262 rings have an unreadable fan name** (`?`, `9`). The ring itself is right,
  but anything that later uses the name (logging sales per fan) can't.
- **6 rings repeat the same fan and amount within 2 minutes**, e.g. Nobody10382 $20.00.
  These could be real repeat buys or one popup read twice. Nobody has checked which.
- It's untested whether a popup hidden behind another window, or one that arrives
  during a chatreader pause, gets missed. A missed sale leaves no log line, so the
  log can't show it.
- No custom sound is set: `userdata\sounds\` doesn't exist, so it uses Windows tada.wav.

**Test it.** Pick an hour of a recording that has sales and count the popups in the video
against the rings logged for that hour.

## 4. PPV library + picker (2026-10-30)

**What it does.** `ppvlib.py` ranks reusable PPV captions by how well they sold, using
the shift log. `^!p` opens a picker for the fan in front of you, and Enter copies the
caption.

**Proven.** The library built once, on 10-30: 62 scripts out of 347 captions.

**Not proven.**
- **The picker has never been opened.** `userdata\ppv_picks.jsonl` doesn't exist, and
  every pick appends to it.
- **The library hasn't rebuilt since 10-30** (`ppvlib.json` is dated 2026-10-30 05:18).
  It only rebuilds when the picker runs, so three days of shifts aren't in it.
- **No offline tests exist** for the grouping, the scoring or the 0.2s answer path.
- **The ranking hasn't been sanity-checked.** Nobody has looked at the top 10 and agreed
  they're good scripts.
- Known bias: it only sees chats someone opened, so every sold-rate is inflated. The
  order should still hold.

**Test it.** Open a fan, press `^!p`, and check whether the top suggestions are ones you
would actually send.

## 5. OBS shift auto-record (2026-10-30)

**What it does.** When an "Infloww Messages" window appears, MMA starts OBS with the
Shifts profile, recording to `D:\ShiftRecordings` in hourly files.

**Proven.** Recordings exist for 10-30, 10-31 and today (02:00–11:00).

**Problems the files show.**
- **The 11-01 shift wasn't recorded at all.** Sales rang from 01:37 to 10:01 that day,
  but there are no recordings dated 11-01. Either auto-start didn't fire or OBS failed
  silently. Nothing in the logs says which, because the auto-start writes no log line.
- **10-31 recorded for 17 hours straight (01:00–17:00).** That's longer than a shift.
  OBS is never stopped when Infloww closes, by design, so it records until someone
  closes it.
- It's still unknown which of the two "Infloww Messages" windows the capture picks
  (one is the 3441x1381 window).

**Fix first.** Add a log line when auto-start fires, skips or fails. Then find out why 11-01
was missed. Decide whether OBS should stop when Infloww closes.

## 6. Unread ping (2026-10-30)

**What it does.** It reads the Unread pill's count every 5s. Once the count is at or
above `At` (10), it pings, and repeats every `EveryMin` (3) minutes while it stays there.

**Proven, live.** It has pinged 70 times, e.g. "10 unread (at 10)" on 11-01. The offline
test passes, including a real screenshot of the pill.

**Not proven.**
- Whether 10 and 3 min are the right values. 70 pings in 3 days could be useful or
  annoying, and only you can say.
- Reading "99+" live. It's covered offline only.
- No custom sound is set, so it uses Windows Notify Messaging.

---

## Suggested order to bake them

1. **OBS auto-record**: a whole shift was lost, and every training tool depends on
   these recordings. Add logging and find the 11-01 cause.
2. **Sales tally**: one live run after the next shift, checked against Infloww's numbers.
3. **MM Gatherer**: one run on a mass channel, then tune it from the frames dump.
4. **PPV picker**: open it a few times during a shift and judge the suggestions.
5. **Purchase sound / Unread ping**: tidy-ups only. Fix unreadable names, check the
   double rings, tune the thresholds.
