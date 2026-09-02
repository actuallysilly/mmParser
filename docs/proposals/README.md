# Proposals

A brief per feature, written before the code. When one ships, annotate it in place — the way
[branching.md](branching.md) was — and move the reasoning into
[docs/decisions.md](../decisions.md). The brief is kept, including the parts it got wrong;
that is the useful bit later.

| | Feature | Status |
|---|---|---|
| | [branching.md](branching.md) | **BUILT** — `^!b` |
| 0 | [capture.md](capture.md) — OCR swaths arrive mis-split into messages | planned, v2.1.4 — **a defect** |
| 1 | [ramp.md](ramp.md) — ramps accrete from saved messages; address them without naming them | ⚠ **UNSOLVED** — do not build; ask for a chatting walkthrough first |
| 2 | [hotstring-search.md](hotstring-search.md) — search a trigger in place | planned, v2.1.4 |
| 3 | [snapping.md](snapping.md) — fractional coords, semantic targets | planned, v2.1.4 (prediction deferred) |
| 4 | [replytime.md](replytime.md) — where the time in Infloww goes | planned, v2.1.4 |
| 5 | [fantools.md](fantools.md) — fan profiles from their messages | **deferred**, needs a decision doc first |

---

## The domain rule these all answer to

**The ramping process is a pipeline** — `mm → fu → fu → fu → ppv → filler → ppv → filler` —
and that shape is real. **Chatting is not.** 90% of a shift is freestyle, typed by hand, and
MMA has no rules about it.

So: **there is structure, but MMA's code is not the structure.** It *represents* the ramp so
you can find your own material; it does not enforce an order, track where you are, or make
the shape into schema law. When those are confused the code starts telling you how to chat.

The law that does hold is already in [mass-format.md](../mass-format.md): **sparse is normal,
and nothing treats a gap as an error.** That sits fine beside a real pipeline — a half-built
ramp is a ramp. See [ramp.md](ramp.md) §1.

## The road to v2.1.4

Items 1–4 are the release. Dependencies run in one direction only:

```
snapping A  ─────────────────┐         (fractional coordinates)
 fixes next_fu, reply_box,   │
 stats_overlay, click_wall,  ▼
 tab_marks, automation    replytime · vault detection


hotstring search   ── the 90% tool ──▶  freestyle: find the wording
                                        you half-remember, by searching it
        │
        └── also how a ramp slot is pointed at an existing trigger

ramp               ── the 10% tool ──▶  planned pitches, addressed by
                                        number so nothing must be named
```

The two do not compete and neither replaces the other. Search covers the majority of the
shift; `__pre{n}` is the fast path for the handful you planned.

**Suggested order.** Each stage leaves the tree shippable.

| | Work | Why here |
|---|---|---|
| 1 | **capture** — group OCR into messages | a live defect: every swath grabbed today is mis-split into one message per visual line. Everything else stores material that comes through this pipe. |
| 2 | **snapping A** — fractional coordinates | a live bug on a 3441×1381 window; six subsystems point at 1920×1032 pixels. Nothing should be built on the old numbers — capture's grouping thresholds included. |
| 3 | **hotstring search** | small, self-contained, serves the 90% — the biggest daily win per line of code here |
| — | ~~ramp~~ | ⚠ **BLOCKED — unsolved.** Ask for the chatting walkthrough before any ramp work. Everything else in this list is independent of it. |
| 4 | **snapping B + C** — semantic targets, zone recording | independent of everything above |
| 5 | **replytime** | wants snapping A done for the vault region |

## Releasing

`version.txt` is the single source — the installer reads it at build time
([tools/packaging/MMA.iss](../../tools/packaging/MMA.iss) `#define MyAppVersion`). Bumping it
to `2.1.4` and writing the `CHANGELOG.md` entry is the last step, not the first; the
`## Unreleased` section already holds the chat simulator, which ships in the same release.
