# FanTools — DEFERRED

> **Status: not built, and not scheduled.** Marked *FOR LATER* in the original note, and it
> is kept that way here. This file exists to record the one thing that must be settled
> **before** any of it is designed.

---

## The idea

Read fan messages and gather data automatically, with a prompt warning about people who are
not worth the time. Someone who says they like ass is filed as an "ass man"; kinks likewise.
The point is to always know what to pitch without having to ask again.

---

## Why it does not just get built alongside the rest

**Every other feature in MMA is built on a promise that this one breaks.**

The activity tracker cannot record text, structurally — see the header of
[activity/record.ahk](../../src/activity/record.ahk). The typelog is off by default and has a
pause key. The proposal in [replytime.md](replytime.md) explicitly refuses to attach a fan
identity to a timing event. Those are not three separate cautious choices; they are one
design rule applied three times.

FanTools **requires the inverse**: a durable store of what named people said about
themselves. That is a legitimate thing to want and a normal thing for this kind of tool to
do. It is simply not a feature that can be slipped in beside the others under the existing
rules, because it needs its own:

- **storage**, outside `userdata\activity\` — that folder's whole guarantee is that nothing
  in it can identify anyone, and putting one file of fan profiles in it destroys that
  guarantee for every file already there
- **retention answer** — how long a profile lives, what deletes it, what happens on uninstall
- **decision-doc entry** in [docs/decisions.md](../decisions.md), written *before* the code,
  in the way §8 was written for the tracker

---

## What to do when it comes up again

Start with the decision doc, not the parser. The interesting problems are not "extract a kink
from a sentence" — that is the easy half, and
[services/llm/](../../src/services/llm/) already has a local model wired up for drafting that
could do it offline. The interesting problems are where the file lives, who can read it, and
what removes it.

Until that is written down, this stays deferred.
