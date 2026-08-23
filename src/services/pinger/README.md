# pinger

Plays a sound when an Infloww fan tab gets a new message. Was the standalone
`MessageWatcher` project; moved in here 2026-07-20 and rebuilt around the CV work
in `../infloww ui elements/`.

## What it looks for

Infloww draws every unread cue in one colour, `#ff7c71`. The pinger looks for two
shapes of it inside the fan tab strip:

| marker | size | where |
|---|---|---|
| tab unread dot | 6x6, ~24px | left of a tab's ✕ |
| overflow chip badge | 12x12, ~80px | top-right of the `7 ˅` chip |

The chip badge matters because a tab scrolled behind the chip shows no dot of its
own — the badge is the only signal those messages produce.

## Why it is not just "scan for orange"

The original version scanned the top 90px of the *screen* for a broad orange
range. Two things were wrong with that:

- The band included the **model** tab strip, which carries permanent `#ff7c71`
  count badges of its own. 169 of 201 matching pixels came from there, so the
  "already alerted" flag latched on the first poll and it never beeped again.
- Anything orange in any other window counted.

So instead: capture the Infloww window itself (not the screen), crop to the fan
strip (not the model strip), match the exact colour (not a range), and require
the blob to be the right size and shape. On the reference captures this finds
every real marker with zero false positives.

## Why size and shape are not enough

The tab's **✕ close button** is drawn in a pink-red about `(251,88,129)`. That is
56 away from `#ff7c71` by sum-of-channels, so the original `CORAL_TOL = 60` let
it through — and a 10x10 ✕ is indistinguishable from a 6x6 dot to a filter that
only knows size and aspect ratio: same square box, 28 pixels versus 24. The
pinger alerted over an empty strip.

Two things fixed it, and the measurements matter because both were free:

- **`CORAL_TOL` 60 → 45.** The slack was documented as covering antialiased edge
  pixels. There are none: the dot is a solid block of exactly `#ff7c71` and comes
  out 6x6 / 24px *identically* at every tolerance from 30 to 70. The ✕ stops
  matching below 55.
- **`MIN_EXTENT` (new).** The fraction of the bounding box actually filled. Real
  markers are solid — dot 0.67, badge 0.51 — while stroke-drawn icons are not
  (the ✕ is 0.28). This catches line art regardless of colour, so the next
  pink icon Infloww adds does not reproduce the bug.

## Geometry is measured, not hard-coded

`../infloww ui elements/UI-ELEMENT-MAP.md` records fan tabs at a fixed 170px
pitch with slot index `(x-3)//170`. That was measured on a 4-tab capture. **The
strip is a flex layout** — 13 open tabs measure 130.4px pitch. Any fixed-pitch
arithmetic breaks at a real tab count, so the pinger finds the strip rows and the
inter-tab gaps per frame instead. The map is worth correcting on this point.

## Running it

MMA drives it: the **Tools** button on the main window opens a window that toggles
it (with a live running state), and
**Settings → Run the pinger** has the checkbox plus a live running indicator.
Both read the same named event the process holds, so they stay honest if it dies.

By hand:

    pinger_start.vbs           start silently (pythonw, no console)
    python pinger.pyw --stop   ask it to exit
    python pinger.pyw --status is one running?
    python pinger.pyw --once --debug   one scan, printed
    python test_detect.py      regression test over the reference captures

Headless it logs to MMA's `error_log.txt`, tagged `[pinger]`.

## When Infloww isn't open

The pinger waits, it does not exit. This matters because MMA's watchdog restarts
anything that dies every 5 seconds: an early version treated "no Infloww window"
as a fatal startup error, so it span up, printed one line, died, and got respawned
— 74 times in 26 minutes, each spawning a visible `wscript`/`pythonw` pair. It now
logs `waiting for a window matching 'Infloww'` once and attaches when one appears.

## Known limitation

PrintWindow reads the Infloww window while it is **covered** by other windows,
but a **minimised** window has no surface to read — all four PrintWindow flags
return black. The pinger logs `BLIND: window minimised` and stays quiet rather
than pretending to watch. Keep Infloww restored; it can sit behind everything.

There is deliberately no screen-capture fallback for this. Grabbing the screen at
the window's rect would capture whatever window is on top when Infloww is
covered, silently reintroducing exactly the cross-application false positives
this rebuild exists to remove.

## Tuning

Everything adjustable is a constant at the top of `pinger.pyw`: `POLL_INTERVAL`,
`REPEAT_EVERY` (re-alert cadence while something stays unread), `CORAL_TOL`,
`MIN_EXTENT`, the shape profiles, and `SOUND_FILE` if you want a .wav of your own.

**If it alerts over an empty strip**, run `python pinger.pyw --once --debug
--save strip.png`. The debug line prints each blob's size and pixel count; a real
dot is `6x6 24px` and a real badge `12x12 ~73px`. Anything with a much larger box
than its pixel count is line art being mistaken for a marker.

### The alert sound

It used to be the `SystemExclamation` alias, which was quiet in a way no setting
in this file could fix: **Windows plays system sounds at the System Sounds mixer
level**, a slider separate from master volume that is easy to leave low. So the
pinger now synthesises its own two-tone beep (880Hz + 1320Hz square, 0.37s) and
plays it on its own mixer channel, where `ALERT_VOLUME` genuinely controls it.

    python pinger.pyw --test-sound     play it once, for tuning

`ALERT_VOLUME` ships at 1.0 (full scale) — to go louder still, raise the pythonw
channel in the Windows volume mixer, or point `SOUND_FILE` at your own .wav.
`ALERT_TONES`, `ALERT_BEEP_MS` and `ALERT_GAP_MS` change the pattern; the tone is
a square wave rather than a sine deliberately, for ~3dB more energy at the same
peak and a harsher timbre that carries over other audio.

The tone goes to a temp .wav rather than playing from memory because `winsound`
rejects `SND_MEMORY | SND_ASYNC`, and a synchronous play would stall the poll loop
for the length of the sound.
