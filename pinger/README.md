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

## Geometry is measured, not hard-coded

`../infloww ui elements/UI-ELEMENT-MAP.md` records fan tabs at a fixed 170px
pitch with slot index `(x-3)//170`. That was measured on a 4-tab capture. **The
strip is a flex layout** — 13 open tabs measure 130.4px pitch. Any fixed-pitch
arithmetic breaks at a real tab count, so the pinger finds the strip rows and the
inter-tab gaps per frame instead. The map is worth correcting on this point.

## Running it

MMA drives it: the **Pinger** button on the main window toggles it, and
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
`REPEAT_EVERY` (re-alert cadence while something stays unread), `CORAL_TOL`, the
shape profiles, and `SOUND_FILE` if you want a .wav instead of the system beep.
