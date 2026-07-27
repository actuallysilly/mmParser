# Infloww UI element map

Derived by measurement from `Whole UI.png` (the full basic UI, no modals), cross-checked
against `One model tab open.png`, `two model tabs open.png`, `3 Model tabs open.png`.
Every number below was measured, not eyeballed — except where marked ~approx.

Companion to `UI-element_desc.md` (hand notes) and `UI-ELEM-DETECTION-OPTIONS-BY-CLAUDE.md`
(technique menu). This file is the *what and where*.

## Coordinate basis — read this first

- Source image is **1920 x 1034**, RGB. There is a 1px window border at y=0 (`#3a3a3a`).
- **The live window is 1920x1032, not 1034** (verified against the running app with
  `GetWindowRect`). Those 2 rows are trailing border in the capture, **not** a layout
  difference — the tab-strip bands (y 1/49/81) and the composer dividers (y 862/907) land on
  identical coordinates in both. So every coordinate in this file is valid live; only treat
  1032 as the real window size. `automation.py` accepts both.
- This is the app **maximised on a 1080p monitor**, window origin at screen (0,0). That is
  why image coords and the screen coords in `live_detector_config.json` agree.
- **All coordinates here are window-relative.** They are only screen coords while the window
  is maximised on this monitor. Anchor to the window rect (`WinGetPos` / `foreground_title`)
  before using them, or they silently drift.
- `live_detector_config.json` stores **x, y, w, h** — not corners. Confirmed at
  `live_detector.py:505` (`rx, ry, rw, rh = region`). The saved regions decode as:
  tabs `0,0 → 597,48` · chats `2,263 → 400,1032` · messages `397,82 → 1640,864`.

## The headline finding: three fixed grids

Tabs and chat rows are **uniform grids with exact pitch**. Slot geometry is arithmetic —
no blob detection needed. Detect *state* by reading one pixel per slot, not by finding
the element.

| Grid | Slot n bounds | Pitch | Index from coord |
|---|---|---|---|
| Model tabs | x `30+150n` .. `180+150n`, y 9..46 | **150** | `(x-30)//150` |
| Fan tabs | x `3+170n` .. `168+170n`, y 58..80 | **170** | `(x-3)//170` |
| Chat rows | y `271+96n` .. `367+96n`, x 0..400 | **96** | `(y-271)//96` |

Verified: model icons at x 39/189/339 across the 1/2/3-tab captures; fan tabs measured at
3..168, 173..338, 343..508, 513..678; chat separators at exactly y 367/463/559/655/751.

## Colour reference

Neutral greys separate cleanly by brightness (max channel), which is what the existing
detectors key on.

| Colour | Meaning | br |
|---|---|---|
| `#0d0d0d` | model tab strip bg; **inactive** model tab | 13 |
| `#151515` | page bg; **active** fan tab; input box | 21 |
| `#232323` | insights card bg | 35 |
| `#262626` | **fan** bubble; fan avatar; inactive filter pill; spend badge bg | 38 |
| `#2b2c30` | **active** model tab pill; fan tab strip **empty bg** | 48 |
| `#353535` | **model** bubble; media message container | 53 |
| `#4d5159` | **inactive** fan tab | 89 |
| `#666666` | list avatar circle; scrollbar | 102 |
| `#d9d9d9` | body text | 217 |
| `#3467ff` | Online Fans button; active filter pill | — |
| `#2ad4ac` | Notifications button | — |
| `#ff7c71` | unread dot / unread timestamp / count badge | — |

### ⚠ The `#2b2c30` trap

`#2b2c30` means **opposite things in the two strips**:

- Model strip (y 1..48): it is the **active tab pill**, on black `#0d0d0d`.
- Fan strip (y 49..80): it is the **empty background**. Inactive tabs are the *lighter*
  `#4d5159`; the active tab is the *darker* `#151515`.

So the active/inactive polarity is **inverted** between the strips, and a
"find `#2b2c30`" scan that isn't tightly y-clamped will match the wrong strip and return
garbage. Clamp model-tab scans to **y ≤ 46**. (An earlier scan of mine leaked to y=52 and
reported the pill as 699px wide.)

## Region map (top level)

Vertical bands, measured at x=900:

| y | Band |
|---|---|
| 0 | window border `#3a3a3a` |
| 1..48 | model tab strip / title bar `#0d0d0d` |
| 49..80 | fan tab strip `#2b2c30` |
| 81..1029 | content |
| 1030..1033 | window bottom border |

Columns, measured at y=900: left panel **0..400** │ centre **401..1637** │ insights **1638..1920**.

---

## 1. Model tab strip — y 1..48

The MMA-critical strip: it says which model is active.

| Element | Geometry | Identify by |
|---|---|---|
| Tab slot n | x `30+150n`..`180+150n` | arithmetic |
| Active pill | y 9..46, ~151x38 | fill `#2b2c30` (inactive `#0d0d0d`) |
| Model icon/avatar | x `39+150n`, ~30x30, near-black `#020202` | present in both states — **ignore for active-detection** |
| Model name | inside pill, right of icon, near-white | OCR (RapidOCR; Tesseract too weak) |
| Count badges | at `x0+47`, y 31..43 | red `#ff7c71` and/or green `#2ad4ac` |
| Tab ✕ close | ≈ `x1-14`, y 29, ~14px, br ≈170 | low-sat bright square |
| New-tab `+` | x ~203, y 29 | fixed |

**A tab can carry TWO badges, not one:** red `#ff7c71` *and* green `#2ad4ac` (the green is
the same colour as the Notifications button). The AW tab shows only red `5`; the BUT tab in
`two model tabs open.png` shows red `7` **and** green `2`. Badge **width grows with digit
count** (~18px for `5`, ~23px for `15`), so don't treat it as a fixed rect. Inactive tabs
still show their badges.

**Model names are near-white in every tab** — `#eff4ff` active, `#d6d9df` inactive. There is
no per-model accent colour to shortcut with, so OCR stays necessary. (The gold/blue pixels
you'll find on the glyph edges are **ClearType subpixel fringing**, not real colour — see
gotcha 9.)

**Relevance: highest.** This is the `detector_status.ini` `active_model` source.

**Actionable:** `model_detect_test.ahk` hardcodes `SPLIT_X := 165` for a 2-model left/right
guess. The real pitch is 150 with tab 0 centred at 105, so it generalises to N tabs:
`index := Round((centroidX - 105) / 150)`. That removes the 2-model ceiling with no new
technique. Note the true tab-0/tab-1 boundary is x=180, not 165 — 165 happens to work only
because centroid classification tolerates any split between 105 and 255.

**Caveat:** in all three multi-tab captures the *newest* tab is the active one, so those
images don't prove the detector handles "active tab is not the last one". Worth a capture.

## 2. Fan tab strip — y 49..80

| Element | Geometry | Identify by |
|---|---|---|
| Slot n | x `3+170n`..`168+170n` | arithmetic |
| Active tab | — | fill `#151515` (merges into page bg below) |
| Inactive tab | — | fill `#4d5159` |
| Inter-tab gap | 14px `#2b2c30` at x `164+170n` | — |
| Empty strip | x 674..1918 | `#2b2c30` |
| Tab ✕ close | ≈ `x1-18`, y 68 | grey circle |
| Unread dot | left of ✕ (e.g. Jason Holmes x~465) | red `#ff7c71` |

Slot 0 is **Home** (the fan-list + conversation view, permanent). Slots 1..N are opened fan
chats. In `Whole UI.png`: Home *active*, then Aaron Raines / Jason Holmes / Tmurf1963.

**Relevance: high** — tells you whether you're in the list view or a detached fan chat, which
changes what the centre column means.

## 3. Left panel — x 0..400

| Element | Geometry | Identify by |
|---|---|---|
| Model label ("AW") | x ~12..40, y 107 | OCR |
| Compose / Search / `+` icons | x ~299 / ~338 / ~376, y 107 | fixed |
| Header divider | y 132 | — |
| **Online Fans** button | x 10..179, y ~150..182 | fill `#3467ff` |
| **Notifications** button | x 209..378, y ~150..182 | fill `#2ad4ac` |
| "All inboxes" dropdown | x ~12..160, y ~190..222 | bordered box |
| "Newest first" + sort + refresh | text x ~211..250; icons x ~343, ~384 | fixed |
| Filter pills | y 233..260 | active `#3467ff`, inactive `#262626` |

Pills measured at y=246: All `11..50` · Pinned `61..127` · Priority `138..205` ·
**Unread `216..284` (active)** · With Tips `295..376` · one more clipped at x≥387.
Pinned/Priority/Unread carry red count badges (99+ / 4 / 5).

### Chat list rows — y 271.., pitch 96

Row n origin `y0 = 271 + 96n`. Offsets within a row:

| Sub-element | Offset | Identify by |
|---|---|---|
| Avatar circle | x 19..58, `y0+17 .. y0+56` (40x40) | fill `#666666` |
| Online dot | x ~50..57, `y0+48` (~8px) | teal, bottom-right of avatar |
| Spend badge ("$0", "$1.43K") | x ~28..52, `y0+61 .. y0+76` | bg `#262626`, orange text |
| Fan name + `@handle` | y ≈ `y0+28` | white bold + grey |
| Preview text | y ≈ `y0+68` | bold white when unread |
| Timestamp | x ~320..370 | `#ff7c71` when unread |
| Unread dot | x ~378 | `#ff7c71` |
| "OFF" badge | under avatar | violet (see Jason Holmes row) |
| Separator | `y0+96`, x 120..390 | does **not** span full width |

Five rows populated (y 271..751); below that the list is empty. Separator pitch was exact —
row height did **not** vary in this capture despite the note in `UI-element_desc.md` that
sizes aren't always const. Treat 96 as reliable-but-reverify.

## 4. Centre column — x 401..1637

### Conversation header — y 82..132

Back arrow x ~430 · fan name ("Steven Martin") x ~452, y 99 + edit pencil · "Available now"
+ green dot y 121 · star / bell / note / pin icons x ~550..660 · Gallery x ~712 · Find x ~775 ·
**Open in new tab** x ~1455..1560 (blue) · refresh x ~1585 · kebab x ~1616. Divider at y 132.

### Message scroll area — y 135..861 (divider `#444444` at y 862)

The one genuinely non-grid region: bubble size and position vary with content.

| Element | Identify by |
|---|---|
| **Fan** bubble | fill `#262626`, left-aligned, starts x ~465 |
| **Model** bubble | fill `#353535`, right-aligned, ends x ~1585 |
| Fan avatar | x 418..452 — **also `#262626`** |
| Model avatar | x 1592..1627 — photo, not a flat fill |
| Media message | `#353535` container, model side |
| **Model kebab (⋮)** | **3x13 px, dots `#666666`, 12px left of the bubble** |
| PPV price tag | red pill, e.g. "$49.49 not paid" x ~1403..1490 |
| Timestamp / ✓✓ / chatter name | under bubble, right side |
| Scrollbar | x ~1632, `#666666` |

### The model kebab is a model-message marker

**3x13 px, three `#666666` dots on a 5px pitch, ~15 dot pixels.** Every model message has
one, and only model messages do — fan messages get pin / comment / heart / translate on their
*right* instead — so its presence alone identifies the side. Verified on the reference (3/3),
a dense 10-message conversation (4/4 model, 0 of 6 fan), and live.

#### Anchored to the bubble's BOTTOM-left corner

    kebab centre = (bubble_x0 - 12, bubble_y1 - 19)

Exact — `dx=12, dy=19` on every bubble measured, reference and live. **Not the bubble's
centre**: centre only coincides for single-line bubbles. On a tall multi-line bubble the
centre is empty background (measured brightness 22) while `y1-19` lands on the kebab.

#### Detection needs two passes

Neither is complete alone, so `find_model_kebabs()` does both and merges:

1. **Direct scan** for the dot triplet. Catches kebabs beside standalone media messages,
   which have no bubble to anchor to.
2. **Bubble-anchored** at the offset above. Rescues kebabs the direct scan drops when
   antialiasing breaks a dot run.

Anchored hits must be **verified, never trusted**: the media half of a media+caption message
is a `#353535` bubble *with no kebab of its own* (the caption owns it), so a blind offset
invents one. In `Whole UI.png` the container at (1150,135,1579,376) anchors to (1138,357),
where there is nothing.

#### Isolation is the discriminator — not colour, not shape

`#666666` is also the avatar and scrollbar, and **shape alone is not enough**: the fan row's
comment icon (a speech bubble with dots in it) and antialiased italic quote text both fake a
dot triplet on a dark neutral background. What separates them is that **a real kebab has
nothing else `#666666`-ish within 6px**:

| candidate | core px | ring px |
|---|---|---|
| real kebab (every one) | 15–21 | **0** |
| fan comment icon | 12 | 16 |
| italic quote text | 10 | 9 |

A ring of 0 vs 9–16 is the widest margin of any filter here. Keep the dot-count and
neutral-surround checks too (the latter rejects photo content that fakes a triplet:
brightness 161 / saturation 51 vs a real kebab's 21 / 0).

#### Two traps that cost real time

**Y-locality.** An early scan grouped every dot sharing an x-column across the whole region
and required exactly three. The region holds **~626 dot-sized blobs** from text antialiasing
(one column had 9), so a single stray in a kebab's column silently rejected it. That scored
3/3 on the sparse reference and **0/4 on a busy conversation**. Match runs within a ~10px
window instead.

**Bubble x0 contamination.** `find_model_bubbles` originally took any column with `>2` mask
pixels as bubble. The **live capture sits a shade off the reference PNG** (window border
`#3d3d3d` live vs `#3a3a3a` in the file), so the kebab's own antialiasing lands inside
`#353535±6` live but not in the file — three stray pixels dragged `x0` 12px left, onto the
kebab itself, making the anchor miss by exactly `dx`. Require a column to be
`MODEL_BUBBLE_FILL` (0.5) of the band: real bubble columns run 59–64 of 64 rows,
contamination is ~3. **Colour thresholds tuned on the PNG are not automatically valid live.**

Measured bubbles: model media `1150..1579 × 134..376` · model text `807..1585 × 381..444` ·
model `1412..1585 × 477..516` · fan `465..875 × 549..588` · fan `465..609 × 781..820`.

**Two independent discriminators** — fill colour (`#262626` vs `#353535`) *or* side
(fan avatar column ~418..452 vs model ~1592..1627). `live_detector.py` uses side. Colour is
more direct but has one trap:

**⚠ The fan avatar is the same `#262626` as the fan bubble**, so a naive colour blob merges
avatar+bubble into one box (my projection returned fan bubbles starting at x=418, the avatar
edge, instead of x=465). Either exclude x<460 or split on the gap.

### Composer — y 863..1029

| Band | Contents |
|---|---|
| y 863..906 | Emoji quick bar: smiley x ~427, gear x ~457, emoji run x ~480..1045; **Scripts** button `1503..1583 × 872..897`; clock x ~1610 |
| y 907 | divider `#444444` |
| y 908..1029 | Input box `#151515`, placeholder *Press "/" + keyword to quickly search scripts* at y 929..937 |
| y ~970..1020 | Toolbar: GIF ~435, image ~475, calendar ~515, tag ~556, @ ~595, Aa ~635, translate ~676 |
| — | **Send** button ~x 1553..1620, y ~982..1012; text `#7b8c99` = **disabled** (empty input) |

**Relevance: high** — the input box and Send are where MMA types. The Send fill doubles as a
"is the input non-empty" signal.

## 5. Insights panel — x 1638..1920

Header "Fan insights" y ~107. Four collapsible cards, fill `#232323`, 13px gaps, each with a
drag handle (⠿) left and a collapse chevron right (x ~1887):

| Card | y | Fields |
|---|---|---|
| Spending behavior | 133..406 | Total spend `$93.66` · Last spend `1d ago` · PPV total/avg · Tip · Highest spend + date |
| Organization metrics | 419..522 | Spending power `Top 1%` · Chargeback risk `Low` (green badge) |
| Subscription | 535..683 | Status `Active` (green) · Cost · Duration · Auto-renewal |
| Profile | 696..905 | Nickname · Birthday · location · Local time · Source · Salary |
| Bottom nav | ~905..1032 | Insights (active) / Sales / Notes |

**Relevance: low for automation, high for context** — all data, no controls MMA drives. But
card y-positions **shift when a card is collapsed**, so don't hardcode field coords; anchor
to the card header.

---

## Gotchas, collected

1. **`#2b2c30` is polysemous** — active model pill *and* empty fan strip bg. Clamp y.
2. **Polarity inverts between strips** — model: active=grey/inactive=black. Fan:
   active=dark/inactive=grey.
3. **Fan avatar shares the fan bubble colour** `#262626` — colour blobs merge them.
4. **Coords are window-relative**, valid while maximised at 1920x1034. Re-anchor otherwise.
5. **Insights card positions move** when cards collapse.
6. **The model icon is near-black in both states** — useless for active-detection, useful as
   a slot anchor (x `39+150n`).
7. **Config is x,y,w,h**, not x1,y1,x2,y2.
8. Multi-tab captures only ever show the *newest* tab active — coverage gap.
9. **ClearType subpixel fringing** puts gold (`#c48e30`) and blue (`#7dbef2`) pixels on the
   edges of white text. Single-pixel sampling on any glyph will lie to you; take the dominant
   colour over a patch instead. This cost me a wrong "per-model accent colour" theory.
10. **Model tabs carry up to two badges** (red + green), and badge width varies with digits.

## automation.py

`automation.py` is the shared foundation for driving this UI: window gate, DPI, capture,
detection, cursor. Future automations import from it rather than re-deriving primitives.
(`live_detector.py` predates it and still carries its own copies of `foreground_title` /
`set_dpi_aware` / `grab`; it could import them from here.)

```
automation_listen.vbs                         # background listener, no console
python automation.py --stop                   # ... and end it
python automation.py --status                 # ... is it up?

python automation.py --listen                 # same, but in this console
python automation.py --image "Whole UI.png"   # offline: detect + report, no mouse
python automation.py --dry-run                # live: detect + report, no mouse
python automation.py --hop                    # live: hop the cursor over each kebab
```

### Running as a background listener

`automation_listen.vbs` starts it under **pythonw.exe**, so there is no console — it sits in
the background like the resident AHK scripts. A `.cmd` would flash a console for a moment
even with `start`; wscript doesn't.

Headless has two consequences the code handles explicitly:

- **`sys.stdout` is `None` under pythonw**, so a bare `print()` raises `AttributeError` —
  every print in the module would be a landmine. Output is swapped for a writer that emits
  MMA's own log format into `error_log.txt`, next to the AHK entries:
  `2026-07-16 21:20:37  [automation.py]  listening ...`
- **There's no console to Ctrl+C**, so `--stop` signals a named event and the listener exits
  cleanly. `--status` reports whether one is up.

Single-instance is a named mutex, the same idea as `#SingleInstance` on the AHK side — two
listeners would run every action twice. A second start refuses and exits.

**The ini hot-reloads; the code does not.** A running listener picks up key changes live, but
a *new* action needs a restart — a listener started before `action_unsend_last` existed
correctly logged `! [automation] 'unsendlast' has no action in ACTIONS - ignored`. Restart
after editing `ACTIONS`.

**Stop event must be reset on start.** `CreateEventW` returns the *existing* object when the
name is still live, and it's manual-reset — a stale set event from the previous listener
makes a fresh one exit instantly. `listen()` calls `ResetEvent` immediately after creating it.

## unsend

`unsendLast` (default `^!u`) unsends your bottom-most message. If your **last run** —
everything you sent since the fan's last reply — has more than one, a prompt appears:

    <hotkey> again  ->  unsend the whole run
    tap Esc         ->  unsend just the last
    HOLD Esc        ->  cancel        (~0.6s; a tap is a different answer)
    ~15s no answer  ->  cancel

**Only the last click is destructive** — opening the kebab menu, picking Unsend, and reaching
the modal are all reversible. So `--dry-run` walks the entire real flow and cancels at the
modal, which makes it a genuine test rather than a stub:

```
python automation.py --unsend --dry-run     # everything except the final click
python automation.py --unsend               # for real
```

Every step is verified before the next click, and it aborts rather than guessing:
kebab found → menu opened → menu **really says "Unsend"** → modal opened → modal really says
"unsend this message" → blue button found → click.

- **Read the menu, don't count it.** The item is `Unsend 23h 56m` — a countdown, so the
  option **expires**. The last menu item is not reliably Unsend; OCR confirms it.

#### The menu's geometry

Measured off a real capture: kebab at (290,76), menu spanning **x 10..556, y 22..54**. So the
menu is **centred on the kebab** (centre 283 vs kebab 290) and **always above it**. Its width
breathes with the countdown text, so `MENU_BOX` pads generously.

**Never clamp the menu box to `R_MESSAGES`.** The menu reaches ~266px *right* of the kebab —
a kebab at x=1487 puts its right edge near **1753**, past the message pane's 1637 edge.
Clamping there silently sliced off the rightmost item, which is Unsend, and looked exactly
like "this message has no Unsend". Clamp to the window only.

**Esc is not free.** Only send it when a menu or modal is definitely open — with nothing up it
goes to Infloww and navigates. An abort path that fired Esc after the menu *failed to open*
is what made it "randomly switch windows".

**Detecting the menu needs change, not just stillness.** An unopened menu is perfectly stable,
so waiting only for a box to settle returns instantly and OCRs empty background. Require
changed-vs-before AND stable-vs-previous-frame.

#### Four bugs that made it "tend to not finish" — all found in error_log.txt

**RapidOCR strips spaces.** The menu came back as `'y/Unsend23h59m'`, so a literal needle like
`"unsend this message"` can never match the modal's real text
(`areyousureyouwanttounsendthismessage`). Normalise both sides to letters+digits (`_norm`).
The menu check only survived by luck, because "Unsend" is a single word.

**Menus animate.** Returning on the first frame that differs handed OCR a half-faded menu — it
read as empty and aborted ~1s after the click, too fast for OCR to have run. `wait_for_change`
now needs two conditions: differs from `before` AND is stable against the previous frame.

**The modal dims the page**, so the changed region is the whole window. OCR'ing it upscaled 3x
is 3711x2181 — that's the 7-second modal check in the log. Locate the button first (cheap,
no OCR), then OCR only a 640x205 box around it.

**Never average all the blue.** `#3467ff` appears ~6.6k times across the window (Online Fans,
the active pill, "Open in new tab", the blue chatter name) spanning x10..x1583; their centroid
is **(315,241)** — empty space in the chat list. With the page dimmed and the whole window as
the search box, that is what a naive "find the blue button" clicks. Find button-*shaped*
connected blue blocks instead, and confirm each by the text around it before clicking.

Matching uses **several short needles against all the OCR text joined** (`ocr_contains`), not
one long string per box: OCR splits sentences unpredictably across boxes, and a single
mis-read character kills an exact match on a 44-character sentence. Verified it still rejects
a kebab menu and a *different* modal ("Delete this message?").
- **`last_model_run()` fails safe.** With no fan bubble in view there's no boundary to
  measure, so it returns only the bottom-most message rather than every message on screen —
  otherwise one missed detection silently turns "unsend ALL" into "unsend the conversation".
- **Re-detect between unsends.** Each unsend reflows the list; coordinates captured up front
  go stale (a live scroll moved every kebab 156px between two calls).

### Hotkeys

Keys live in **`hotkeys.ini` under `[automation]`** — never in the Python, same rule as the
AHK side. Default `hopKebabs = ^!k`. Blank disables, and edits apply live (the listener
watches the file's mtime, matching the ini's own "Changes apply live" promise).

The ids are **declared in `hotkeys.ahk`** (`HK_Section` + `HK_Def`) so the Hotkeys GUI lists,
edits and conflict-checks them like any other key — but **nothing calls `HK_Bind`** for them.
Python owns the binding, so `--listen` must be running for them to fire. Adding one means
three steps, mirroring the AHK pattern: an entry in `ACTIONS`, a line in `hotkeys.ini`, and
an `HK_Def`. Note `configparser` lowercases keys, so `ACTIONS` is keyed lowercase.

It **polls** (`GetAsyncKeyState`) rather than using `RegisterHotKey`, deliberately:
`RegisterHotKey` is global and would swallow the key from every other app even when Infloww
isn't active. Polling only observes, so the key still reaches whatever you're using — and it
matches `live_detector.py`, which polls Esc/F8 the same way.

Two gates in `require_window()`, both enforced before anything moves: the window must be
**active** (same rule as `#HotIf WinActive`), and it must be **1920x1032**, because every
coordinate here is window-relative and a different size would mis-click silently. `--force`
overrides. Esc aborts a hop, focus loss stops it, and nothing in the module clicks.

`find_model_kebabs(rgb)` returns window-relative centres, top-to-bottom. Verified 3/3 on the
reference and 2/2 live.

## Notifications > Purchases (sales tally)

**This panel lives in the MESSAGES app.** Infloww Home has a bell too — it opens an
*unrelated, empty* "System Notifications" page with a **Clear all** button beside it. Wrong
app, and an expensive place to misclick. Everything here is the Messages window.

Opened by the teal **Notifications** button at **(293, 165)**, next to "Online Fans". The
flyout is anchored to it, so its box is fixed: **(219, 182) → (781, 885)**, bg `#262626`,
page `#141414` either side. Scrollbar thumb `#666666` at x 771..778.

Tabs at **y 245**, centres: Subscriptions 287 · Tips 391 · **Purchases 485** · OnlyFans 594.
The active tab is an accent-blue (`#3467ff`) pill, ~94–113px wide.

| Field | Where | How it reads |
|---|---|---|
| **PurchasedBox** | band between two dividers | variable height — see below |
| **Amount** | `has purchased your message for $25.00!` | `$` is unreliable — see below |
| **Responder** | `Silly responded to the notification` | separate OCR box; **optional** |
| **Timestamp** | `Jul. 17, 2026 at 1:04 AM` | own line, consistent format |

**Cards are NOT a fixed grid.** Measured 162px when answered, 184px when the body wraps to
two lines or an unanswered card carries a Quick-reply box. Dividers, not pitch.

**A divider is a 1px `#444444` rule — and so is the Quick-reply box border.** Left unfiltered,
the reply box splits one card into three. They separate by **width**: real dividers measured
**444–475px**, reply-box borders **334–337px**. Nothing lands between; threshold 400.

**"Panel open" is decided on the header band, never the tab pill.** The chat list's own blue
`Unread` pill sits at **cx=250** in the same row — only **37px** from the Subscriptions tab at
287, so a plausible tolerance reads a *closed* panel as "open, on Subscriptions". The header
band (230,190)→(760,226) has no such neighbour: **0.95** `#262626` open vs **0.04/0.24**
closed. The pill only identifies *which* tab, once open.

**Take the widest contiguous RUN of blue, not `cols.min()..cols.max()`.** The extent spans
*between* unrelated blue things and reported cx=396 for a pill actually centred at 486 — the
same mistake that put the Unsend click 25px off (see the `MENU_PANEL_FILL` note under unsend).

**OCR reads the `$` as `s` about half the time** — `for s49.49!` came back live, while
`$25.00` in the same capture read fine. It is non-deterministic, so the currency mark cannot
be part of the match: anchor on `for … !` and keep only digits and the dot. Anything not
shaped exactly `NN.NN` is **refused, not guessed** — this is money, and a silently wrong
total is worse than a loud failure.

**The responder's name is its own OCR box, to the LEFT of the phrase**, and comes back
lowercase: `'silly'` at (315,400), `' responded to the notification'` at (417,399). Splitting
the phrase's own text yields nothing — find the phrase, then take its left neighbour on the
same line (±8px). A regex over the joined text would keep only the last word of a two-word
name. Compare with `_norm()`, since `Silly` reads as `silly`.

**Scrolling has no px-per-notch constant, deliberately.** Each pass re-reads what's on screen
and dedups on `(handle, timestamp, amount)`, so the distance never has to be known — only
that one step moves less than a panel-height (~620px of list). 3 notches ≈ 300px at
Chromium's default, a 2x margin. Consecutive passes sharing *no* card means something jumped
further than we can account for, and that is **reported**, not swallowed. Only bands between
two dividers are parsed; the part-cards clipped at the viewport edges are skipped, since
their text is cut and would parse short.

**PARK THE CURSOR OFF THE LIST BEFORE CAPTURING.** The wheel only goes to the window under
the pointer, so scrolling must put it over the list — but leaving it there hovers a card in
every frame, and the hover restyle corrupts what OCR reads. Park at **(1508, 107)**
("Open in new tab", the user's pick): far from the panel and inert on hover. This bit us —
the first version parked at the panel centre (500, 575), i.e. dead in the middle of the cards.

**"No new cards" is NOT an end-of-list test.** It is also exactly what a lazy-load fetch in
flight looks like, and a short fuse quits early on a list that had more to give ("it likes to
just stop at some point"). The **scrollbar thumb** tells them apart: `#666666` at x 771..778,
contiguous, measured y 272..489 on Purchases. It keeps moving (or shrinks as items load)
while there is more, and freezes only at the true bottom. Require **both** to stall, for
several passes, with a pause between to let a fetch land.

Corollary worth keeping: **no thumb at all means the list is too short to overflow**, so
scrolling can never reveal anything — that must count as stalled too, or a short list spins
the full safety cap (400 passes) holding the user's cursor hostage for minutes.

**Always report WHY the run ended** — "reached the end", "a different person", "hit the
safety cap", "the panel closed". Giving up early and finishing cleanly produce the same tidy
total, and only one of them is trustworthy.

**Stop rule: the run ends at the first card answered by a different person** (the user's
rule), which bounds the work to one shift instead of the whole list. Cards with **no**
responder do not end it — nobody is not somebody else — but they are reported separately
rather than folded into the total.

Known limit: two identical purchases by the same fan in the same minute share a dedup key and
collapse into one, **undercounting**. Rare, but it is real money, so it is worth knowing.

## The element library

`elements/` holds one PNG per element, regenerated by `slice_elements.py` from the reference
screenshots; `ui_elements.json` is the machine-readable manifest (name → src + rect);
`contact_sheet.png` shows all 72 at a glance.

Scope is deliberate: **glyphs, not grids.** Icons and buttons are identified by *shape*, so a
bitmap is the only faithful record — and AHK `ImageSearch` / template matching need real files.
Tabs and rows are identified by colour+position, where a crop is actively *worse* than the
geometry above: it freezes one model, one name, one unread count, and template-matching it
breaks the moment the data changes. Use the pitch tables for those.

Two kinds of entry in the slicer:
- **AUTO** (32) — a band scanned for glyph blobs, so bounds are measured and can't drift.
  Names are assigned left-to-right; if a band's glyph count stops matching its name list the
  script falls back to indices and warns rather than silently mislabelling.
- **FIXED** (40) — hand-specified rects for structural samples and for glyphs too small to
  auto-detect (`convhdr_kebab` is ~4px wide, under the min-width floor).

Exemplars span **multiple sources by necessity**: `Whole UI.png` has only one model tab, so
`modeltab_inactive` and `modeltab_badge_grn` come from `two model tabs open.png`.

## Suggested next steps

- Generalise `model_detect_test.ahk` from `SPLIT_X` to the 150 pitch (N models, pure AHK).
- The three grids mean tab/row detection can drop blob-finding entirely: compute slot rects,
  sample one pixel each, classify. Cheaper and steadier than the current projection passes.
- Capture a model-tab set where the active tab is *not* the last, to close gotcha 8.
- The green badge's meaning is unconfirmed (same colour as Notifications — likely a
  notification count). Worth a capture that isolates it.
