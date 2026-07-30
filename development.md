This is what need to be done for MMA to enter 2.0.0

1. ALTFU=Branches, why the fuck are there 2 buttons
Do they differ by anything other than GUI?

2. The recorder is useless

3. How to use needs to be HTML docs

4. DoubleMM is depreciated and should be deleted 

5. I don't see a way to edit the default fu3
5.1 I dont see a way next to it to toggle that feature

[ Hotkeys settings tab]
6 Follow up 1 (Pick alt) Follow up 1 (alt key) What does it mean?
6.1 And then branches are there too
7 Mass Active model - What does it do? WHat is all that

8. Given the rewrite we did, how many scripts need to be running for mma
I still have 6 scripts running?


What is holy👑

Ways to send mass messages:
FollowUp1 -> FollowUp2 -> FollowUp3 -> PPV1 -> PPV1Fu -> 

Manual -> (F1,F2,F3,F4,F5) (F9,F10,F11,F12,!F12), (F6,F7,F8,null,null)
        these are holy and always work no matter what, these are fallbacks
        most users want these, they will rebind but these need to exist
        "Send f1/fx manually"

Positional -> Pre-set the model order and just use tab color
        current working, ROBUST, recommended

OCR Model name + Color 
        most convenient

Use one button for follow ups [toggle]
[hotkey name] OneButtonFu -> Works with all 3 models
* Works with any of the 2 modes (positional/OCR)
* Should live as a toggle exactly below them in settings
* Does nothing if those 2 arent selected

Major bugs on SACRED FEATURES

HotstringOCR (featureName + hotkey binding) = Ctrl+Shift+O rename to "Add hotstring with OCR" 
currently isnt working

OneClickImport (Ctrl+leftClick) currently isnt working


## BUG: follow-up part suffixes only accept .5 and .7 — .1/.2/.3 are silently dropped

WRONG BEHAVIOUR. Both spellings should work. `.1 .2 .3` is the obvious way to write
"part 1, part 2, part 3" and it is what anyone would try first.

What happens today: a prefixed paste containing

    f1 first part
    f1.1 second part
    f1.2 third part

parses `f1` and **throws the other two away without a word**. No error, no log line, no
missing-field marker — the parts simply are not there when you press the key. It looks
exactly like the parser not handling multi-part follow-ups at all.

Where it is:

* `FPrefixToSlot()` in `src/mass/parser.ahk` — matches `^[Ff][Uu]?\s?(\d+)(?:\.(\d+))?`,
  then tests only `SubStr(d,1,1) = "5"` → `_5` and `= "7"` → `_7`. Anything else falls
  through to `return ""`, and the caller's `if slot = ""` → `continue` drops the line.
* `StripPrefix()` matches the same shape, so the prefix IS recognised — it is only the
  slot mapping that refuses it. That is why it fails silently rather than treating the
  line as message text.
* `keyMap` in `src/ui/main_window.ahk` has the same gap: it lists `f1.5`/`f1.7` and no
  `f1.1`/`f1.2`, so **keyword mode** drops them too.

Wanted: `.1`/`.2`/`.3` and `.5`/`.7` both map onto the same three underlying fields
(`fuN`, `fuN_5`, `fuN_7`).

    f1      -> fuN          f1.1 -> fuN     (or should .1 mean the 2nd part? DECIDE)
    f1.5    -> fuN_5        f1.2 -> fuN_5
    f1.7    -> fuN_7        f1.3 -> fuN_7

The one thing to settle before implementing: does `f1.1` mean the FIRST part (same as
bare `f1`) or the SECOND? `.5`/`.7` are the 2nd and 3rd, so `.1/.2/.3` reading as
1st/2nd/3rd is the intuitive mapping — but then `f1` and `f1.1` are the same slot and a
paste containing both silently overwrites. Probably: `f1.1` = 2nd part, `f1.2` = 3rd,
i.e. `.1/.2` are aliases of `.5/.7`, and `.3` is a no-op — OR widen the record to a real
4th part. Decide, then make the field count follow from `store.ahk` rather than a
hard-coded three.

While in there: anything the parser REFUSES should leave a `LOGW`, not vanish. A dropped
line is the exact class of silent failure the logging pass exists to kill, and this one
survived it because the drop is a `continue` with no else.

Docs note: `docs/guide.html` and `docs/mass-format.md` currently document `.5`/`.7` as
the only accepted form, flagged as a known bug rather than as intended design. Update
both when this is fixed.