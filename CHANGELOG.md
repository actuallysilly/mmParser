# Changelog

## Unreleased

### A chat simulator: write a mass as the conversation it becomes

The GUI edits a mass as a grid of boxes — `mass`, `fu1`, `fu1_5`, `fu1_7`, `fu2` … Every
box is correct, and between them they hide the only thing you actually need to know:
what the fan sees.

**Ctrl+Alt+C** opens a mock chat. Your messages are the bubbles, his replies sit in
between, and a composer at the bottom sends the next one — straight into the next empty
slot, in send order, the way you would actually write the conversation. Click any bubble
to reword it. Switch the composer to **Him** to write what he says back, so f2 is written
against something rather than into the air.

Four things it shows that a grid of boxes cannot:

- **How many messages this is.** Three boxes under F1 are three separate messages, about
  1.5s apart — the gap is drawn between them — unless `FuSingle` is on for that model and
  group, in which case they are one message with line breaks, and it says so.
- **What pastes and what sends.** The opener and the PPV blurb land in the chat box
  without an Enter. They are drawn as dashed drafts, not as sent messages, because the
  difference is the whole reason you get to read them first.
- **Where the f3 fallback comes from.** A mass with no f3 does not send silence, it sends
  the `DefaultFu3` text from Settings. That bubble now says where it came from.
- **What a branch actually changes.** Pick one in the header and the conversation redraws
  on it — including the groups the branch has no wording for, where the trunk's goes out.

His replies are kept in `userdata\chat_sim.json`, never in `masses.json`. Everything in
that file goes out to somebody, and a line that exists so you can read your own follow-up
in context must never be one keystroke from being sent.

### One answer to "what does this mass send"

The simulator could not have been trusted otherwise. The rules — which fields make up a
follow-up, when `DefaultFu3` applies, what `FuSingle` joins, what a branch contributes —
were spread across `core\utils.ahk` and `mass\runtime.ahk`, and **no window can include
either**: the first registers hotstrings and binds keys the moment it loads, the second
binds the follow-up keys.

So a second copy in the new window was the obvious route, and it would have agreed with
the engine until the week somebody changed one of them. Instead the rules moved to
**`mass\shape.ahk`** — unchanged, and already pure: the comment above `BranchList` had
said *"these helpers are pure (take the mass object)"* for as long as they had been
there. The engine and the simulator now read one copy, and `tools\test\mass_shape_test.ahk`
pins every rule.

**Two bugs this turned up, both silent.**

`MASS_AsObject` converts a stored mass (a Map) into the property form every send helper
is written against. Nothing had ever needed the way back, because the engine reads and
never writes — and a window that edits a record does. Handing the object form to
`MASS_Set` throws nothing and logs nothing: `MASS_Normalise` keeps a record only if it
`is Map`, so it is quietly swapped for a blank one on the way to disk. **The mass looks
saved until you reopen it and find it empty.** `MASS_AsMap` is the missing inverse, and
the test asserts both directions — including that the wrong one loses the record, so the
trap stays written down.

The second was the first one's disguise: the window came up correct, silent and
completely blank, because a bare `try` around "build the state and send it to the page"
ate the exception from building it. Both ends of that bridge now report — the AHK side
logs what it could not build, and the page reports its own script errors into `mma.log`
rather than into a console nobody is looking at.

### The hotstrings you actually use, on one key

The message library is 134 triggers. Two of them are most of a shift and you know those
by heart; the rest you half-remember. Until now the ways in were: type an abbreviation you
have to recall exactly, bind a key to one hotstring (which runs out of chords after five),
or open the manager and search.

**Ctrl+Alt+H** now opens a popup at the cursor with your **pinned** hotstrings on top and
the **recently used** ones under them. Click one and it sends exactly as its trigger
would — including the overload picker, if it has one. Press **1**-**9** for the first nine
rows. **Shift-click** a row to pin or unpin it.

Pins are manual on purpose. Recency alone gets the ordering wrong for the message you send
twice a day: it is exactly the one that falls off a most-recent list, and exactly the one
worth a menu for.

Two things this needed, both new:

- **`userdata\hotstring_usage.ini`** — the store. Every message file is a separate
  process, so "what did I use recently" has to cross a process boundary, and MMA's answer
  to that everywhere else is a file in `userdata\`.
- **A way to know which hotstring is firing.** A hotstring body is `snd("…")` and nothing
  else — there is no trigger in scope, and adding one to 134 hand-written blocks would be
  a line you have to remember to write. `A_ThisHotkey` answers it, and
  `A_TimeSinceThisHotkey` is what separates *the three sends of one hotstring* from *three
  hotstrings*: within one fire it only ever goes up, and a new fire resets it to zero.
  (Measured: 0, 406, 812 across three steps.)

The key is bound by **exactly one** message script — the first file `content\` lists,
which is `general.ahk` — because every script includes the same file and binding it in
each would open three identical popups on top of one another. The menu still covers the
whole library whichever script owns it.

### Hotstrings are editable in the GUI now — all of it

The Hotstrings manager listed, searched, overloaded and deleted. Changing what a hotstring
*said* meant leaving it: VS Code, the right line, and getting AHK's string escapes right
by hand.

**Edit…** (or double-click a row) opens the lot: the trigger, `::` vs `:*:`, the message
text, which function sends each line, the wait after a `Sendt()`, and which message file
the whole thing lives in. Save writes the block back where it stands and restarts the
owning script, because a message script binds its hotstrings at load.

**Two ways to edit the body, and both are necessary.** *Steps* is a row per message with a
box for the words — no AHK, no quotes to escape. *Source* is the body as written in the
file, and it is not a flourish: `content\accounts\BRI.ahk` has blocks that open with
`t := 500` and pass `t` to every `sendt()` below. Rebuild one of those from its steps and
the line those steps depend on is gone, leaving a script that no longer loads. A body that
is not send-calls-and-nothing-else opens on Source with the reason on screen, and switching
to Steps asks first.

**A rename is a migration, not a string change.** Three files key off a trigger — the key
bound to it in `hotkeys.ini`, its variants in `hotstring_overloads.ini`, and its pin and
use count in `hotstring_usage.ini`. All three move with it. Without that, renaming a
hotstring silently broke its key, stopped its overload firing and reset its history.

Also here: a **✦ column** and a **Pin** button, a **Used** count, and two more sort
orders — *Pinned first* and *Most used*.

**One bug this shipped with, and how it was caught.** `HSI_Escape` wrote the replacement
for a double quote as a *single*-quoted AHK string containing one backtick and one quote.
The backtick is AHK's escape character inside single-quoted strings too, so that
expression is a one-character string holding a plain quote — and the replacement was a
no-op that compiled and ran. Every quote in a message would have been written out
unescaped, ending the block at the first `"` in your own words. `hotstring_edit_test.ahk`
asserts the round trip character by character, which is why this is a paragraph in a
changelog rather than a message that came out wrong in a real chat.

### The wait time is a setting now, like everything else

`waitTime` — the pause between the parts of a send — was the only setting in MMA stored as
**source code**: a literal inside `core\utils.ahk`, the file every message script and the
mass engine `#Include`.

That one difference cost a lot. Saving it had to **rewrite a source file**, through a
regex, a temp file and a `FileMove`, guarded three ways because `FileOpen(…, "w")`
truncates before it writes and a failure halfway leaves every script including an empty
`utils.ahk`. Two more files then read the value by scraping the same regex back out, so
renaming that one line broke reading *and* writing in four files that had no other reason
to know how `utils.ahk` is worded.

It is `[Settings] WaitTime` in `mass_gui.cfg` now. `SW_SaveWaitTime` and its three call
sites are gone, the settings-parity test checks it like every other row, and it still asks
for a restart — the scripts read it once, at load, exactly as they read the literal.

The default is **1500**, which is what that line shipped with. The `350` that used to sit
in the callers was never a default anybody ran with: it was the answer when the regex
*missed*.

### The README was describing a version of MMA that stopped existing

Nothing here changes what MMA does. It changes what MMA *says* it does, which had drifted
far enough to be misleading on first read.

- **"Three model slots."** It has been three to twelve since 2.0.2. The README still
  promised three.
- **"Python — optional, and only for two things."** Four: the automation listener, the
  pinger, typelog and autoword. The installer's own header said "exactly two" as well,
  and its package note claimed `pynput` was for typelog only — autoword needs it too, at
  a higher version floor.
- **"Auto-updater — checks for updates silently on startup."** That check is **off by
  default**, and has been since it was given a switch: it prompts in front of whatever
  you were doing, on somebody else's release schedule. **Settings ▸ Models ▸ Check for
  updates** works whatever it is set to.
- **The Settings table listed four options** — model names, hotkeys, wipe temp, check
  update. Settings is eight tabs. The table is now the tabs, with a line saying the thing
  that is easy to get wrong: Features is the only tab that offers a feature's on/off box,
  and no key has a checkbox in two places.
- **The file tree was missing `activity/` and `branch/`**, still listed a `modes` window
  that was deleted, and described `vendor/` as "OCR.ahk" when it also carries WebView2
  and the JSON parser.

A sweep of every comment in the source turned up eleven more of the same kind, all now
corrected: a header claiming "Five children" for what is nine services plus two, three
files asserting the Features tab is the *only writer* of a feature key when four places
write one, a logging header listing six levels when `LOGD`/`DEVL` made seven, and several
pointers to functions deleted in earlier releases. Comments that say *"X stood here"* were
left exactly as they are — those explain where something went, and they are the reason
this sweep was possible at all.


### Two background tools were lying to you, and the reason was a list

Switching **Activity tracker** off in Settings ▸ Features wrote the setting and left the
process running. The checkbox said off; it went on counting your keystrokes until you
restarted MMA. **Autoword** did the same thing. Neither ever appeared in the code that
stops a service when you untick it — that code was a hand-written if/else chain covering
seven of the nine, and those two were the two it missed.

For features whose entire defence is *you switched this on deliberately*, that was the
wrong bug to have.

The same chain existed three more times, and it had drifted three different ways:

- **At startup**, the list was missing the Fansly detector, the activity tracker and
  autoword — so all three started five seconds late, on the first watchdog tick, and with
  **Auto-start scripts** off (which is what Easy mode does) they never started at all.
- **The Tools window** kept its own copy of the nine ids, retyped, with a comment
  explaining that it had to be kept in step by hand.
- **The Tools button's count** kept a fourth copy, with a comment saying that getting out
  of step cost a wrong number on the button.

Four lists of the same nine things, none of them checked against the others.

**There is one list now.** Every background service is declared once, beside the feature it
belongs to, and everything that acts on services walks that declaration: startup, the
Features tab, the Tools window, the button's count and the watchdog. A service cannot be
missing from a list, because there are no lists.

Nothing about how MMA behaves for you changes, except that the two bugs above are gone and
three services now start when MMA starts rather than five seconds later. Every switch,
label and setting is exactly where it was — the registry reads them from the same place
Settings always did.

For anyone reading the code: eleven near-identical `Launch*`/`Stop*`/`*Running` triples in
`core/processes.ahk` became one declaration table and nine generic functions — the file is
864 lines down to 747, and most of what replaced the triples is the comment explaining why
they went. Adding a background service is now one line there, one line in `core/modes.ahk`,
and the file itself. `tools/test/services_test.ahk` is what stops a fifth list growing
back; it runs from Settings ▸ Debug with the rest.


### The window Edge draws is the one MMA opens

The WebView main window has been selectable in **Settings ▸ GUI ▸ Main window** for a while,
under a label that told you not to pick it. It was honest: it drew the panel beautifully and
did none of the work behind it. Choosing it launched MMA with **no mass engine, no sequence
watcher, no startup scripts, no background services and not one hotkey bound** — a control
panel for a program that was not running.

It is the default now, and Classic (Win32) is the supported fallback rather than the starting
point. Picking Classic is still a one-click, fully-working choice; take it if WebView2 will not
start on a machine, or if you prefer the Win32 window.

**What it had to grow to get here:**

- **It starts MMA.** The engine and the sequence watcher come up *before* Edge does, which
  matters more here than it did in the Win32 window: standing up the WebView2 runtime is far
  slower than laying out sixty controls, and every one of those milliseconds used to be MMA on
  screen with its hotkeys dead. Startup scripts, the automation listener, the pinger, the model
  detector, the stats overlay, typelog, the reply box and the watchdog all follow at the end.
- **It answers the messages other processes send it.** Ctrl+clicking a Discord message posts an
  auto-parse to "the MMA window", and the Hotstrings manager's **Add hotkey…** button asks the
  main window to open a dialog built out of the main window's own globals. Both addressed that
  window by the Win32 shell's file path — an AHK script's window title *is* its full path — so
  under the WebView shell both would have found nothing and reported MMA as not running while
  MMA was plainly open. They now ask which shell is actually up.
- **It has the keys.** OCR grab, Add-hotkey grab, the branch builder and double-MM were bound
  only by the Win32 window.
- **Closing it closes MMA.** Its X was a bare `ExitApp` — fine for a window that started
  nothing, orphaning for one that starts nine scripts and three Python services. It asks the
  same Yes/No/Cancel the Win32 window has always asked, and "Yes" stops the services too:
  they are not AHK windows, so nothing else goes looking for them. There is a **Kill all
  scripts & Exit** entry on the tray icon as well.

### Starting MMA no longer waits for Edge

Found by timing the first real launch: **60.8 seconds** from double-clicking MMA to
`general.ahk` starting. That file is every hotstring MMA has, so for a minute after launch
typing did nothing, once per launch, with the window sitting there looking ready.

Nothing was wrong with the startup itself — it was in the wrong place. Both shells started
their scripts and services as the last thing they did, which costs nothing in the Win32 window
(its controls exist in milliseconds) and costs a minute in this one, because
`CreateControllerAsync` blocks until the Edge runtime is up.

Startup is in three phases now, and the rule is that **nothing you reach for waits on a window
being drawn**: the engine and sequence watcher first, then the startup scripts, the automation
listener and the background services, and only then — after Edge — the two timers that
genuinely need a window (the Tools button's caption and the unknown-model prompt). The `[gui]`
hotkeys moved ahead of Edge for the same reason.

Measured again after: **0.11 seconds**.

### One copy of what the window does

The two front ends had each grown their own implementation of the same logic — **thirty-four
functions written twice**, and they had already drifted apart: `ApplyFile` differed by 56
lines, `PickMassSlot` by 28, and the WebView's `LoadFile` refreshed the model header where the
Win32 one did not.

That is the exact shape of the mass-# bug in 2.0.3, where what you *saw* and what the keys
*sent* disagreed. Two copies of one truth are one copy plus a lie waiting to be found.

Everything that is not *drawing* now lives in one file that both shells share — the parser and
import path, the model-name repository, the mass slots, the updater, the Add-hotkey dialog,
Wipe temp, the collision check and the boot sequence. The rule is: if it does not touch a
control's position, size or creation, it is not the window's business.

Reconciling the two copies turned up a bug that had been sitting in the Win32 window: Parse
cleared a model's boxes by matching the key prefix `"m" mNo "_"` against the **first three
characters**, which is only the right length while the model number is a single digit. At ten
models or more it matched nothing, so Parse filled the boxes without clearing them first and
the old text stayed underneath. The WebView copy had it right; the shared one takes that.

**Nothing about either window changed on screen.** This is the plumbing underneath, and the
point of it is that the next fix lands in both windows instead of one.

### Settings is a page now

Eight tabs of pixel-positioned controls, and the reason it was eight tabs is that a Tab3 page
cannot scroll — so every setting had to *fit*, and where it went was decided by where there was
room. Nothing has to fit on a page. So the shape is the one the settings actually have: a list
of sections down the side, one scrolling column, and a search box over the whole lot.

The **Models** section is a straight port of the Win32 Models tab rather than a rewrite of it:
same rows, same order, same wording, the same NAME/PLATFORM table, the same greying (manual
strategy greys the automatic block; the shared keys off greys the strategy too), the same live
"Detector sees" readout, the same "Reset model fields". It is the section most visited and the
one where a wrong answer is expensive — a shared key that resolves to the wrong model sends one
model's message into another model's chat — so nobody who knows that tab should have to re-learn
it here. What it drops is the constraint that shaped it: a Tab3 page cannot scroll, so everything
had to *fit*.

- **Search across every setting**, including the feature switches, by name or by the help text.
- **A line under each setting saying what it does**, instead of a label and a guess.
- **A `restart` badge** on the handful that do not take effect until MMA is restarted.
- **The theme previews live** as you pick it, before you save.
- **Nothing is written until Save.** Close really does discard — the window edits a copy.

**It holds no list of settings.** The feature switches are drawn from the registry in
`core/modes.ahk`, so a new `FEAT_Def` line appears here with no edit; everything else comes
from one declarative table that travels to the page *with* the values.

Two bugs fell out of writing that table down and checking it against the code that reads the
keys: `CreditPicture` is a **boolean** — `CREDIT_On()` reads it as one — and was being offered
as a text box you could type a filename into, which would have left it reading a filename as a
number; the picture's name is a separate key and is now a dropdown of what
`assets/decoration/` actually holds. And the model-count default here was 2 where
`MMA_ModelNames()`, the function that decides how many slots exist, says 3.

**Hotkeys, calibration and the probes are not in it** — they are buttons that open the real
windows. Those drive screen capture, drag-to-measure overlays and colour pickers, and neither
is a stub.

The Win32 Settings window is unchanged and still there under Classic.

### The hotkey editor is a page too, and it can still read a Scimitar button

Ninety-nine actions across seventeen features. The Win32 editor lists them well — the previous
release is most of why — but a ListView cell that says `^!F1` is a cell you *decode*, and a
"Clashes with" column that names ids is a column you cross-reference.

- **Every key is drawn as keycaps.** `Ctrl` `+` `Alt` `+` `F1`. The keycap is the button —
  click the key you want to change, not a row and then a *Set key…* button.
- **Clashes are on the row, in words and in colour.** "⚠ same key as Follow-up 1 — active
  model", against a tinted row, instead of an id in a column at the far right.
- **Filter chips with live counts** — All, Changed, Clashes, Unassigned — so "is anything
  double-bound" is answered before you click anything. On this install: **18 keys clash**, all
  of them a per-model key and the shared active-model key holding the same F-key.
- **A section rail with a count per feature**, and a dot on any feature holding an unsaved edit.
- **Search across the action, the feature, the key and the id.**
- **Reset one, unbind one, reset everything, or discard the lot** without closing the window.

**The page never reads the keyboard, and that is why this works.** The capture is the same
`InputHook` the Win32 editor has always used, unchanged and now shared between them. It is a
system-wide hook, so it does not care which window has focus, and it runs without the `V`
option, so the keystroke is *swallowed* before the page sees it. `Alt`, `F10`, `Ctrl+W`, `F12`
and the Windows key record like any other chord — which a page listening for `keydown` could
never manage — and `XButton1`, the wheel and the Scimitar side buttons record too, because
those are AHK hotkeys rather than anything a browser has a name for.

What the page draws is the overlay: which action, what it is bound to now, and the chord as you
hold it. While it is up the mouse is being watched as well, so **there is no Cancel to click** —
clicking would *be* the new binding. Escape cancels and Backspace unbinds, and the overlay says
so in letters you can read across a desk.

**Both editors now share every rule that is not drawing** — the capture, the key names, the
clash test, and the write to `hotkeys.ini`. Not tidiness: they report on the same keys and
write the same file, and a disagreement between them about what counts as a clash is a bug you
could only find by having both windows open at once and noticing they said different things.
Open them side by side and they say `99 keys · 18 clashing · 13 off` in both.

**Where to find it:** a **Hotkeys** button on the main window, and **Hotkeys editor…** in
Settings. The Win32 editor is still there, still runnable on its own when the main GUI will
not start — and if the Edge runtime will not start, this window opens it for you rather than
leaving you with no way to fix a key.

### The activity chart has a button

It has existed for a while and had exactly one door: the `gui.activity` key. That is a door you
have to already know about, and the log settles it — `act.boot` every session since the tracker
went in, `act.chart` **not once**. A feature nobody can find is a feature nobody has.

So there is an **Activity** button on the main window now, in both shells, hidden with its
feature like Hotstrings and Variants are.

It does not open the chart itself. The tracker owns the minute in progress and flushes it before
opening — without that the chart comes up showing everything *except* the minute you pressed the
button about. So the button fires `gui.activity` through the hotkey registry and the tracker
answers, exactly as the Actions menu runs a key that lives in another process. One
implementation; the button and the key cannot drift.

Every branch that cannot do that says so out loud rather than doing nothing: the feature switched
off gets a dialog saying where to switch it on, and a tracker that is not running still opens the
chart directly — everything already on disk is worth looking at, only the current minute is
missing.

### Every window that comes in two kinds now lets you pick

The main window has been WebView-or-Classic for a release. Settings and the hotkey editor now
are too, each with its own choice in **Settings ▸ GUI**, because WebView2 being fine for one of
them says nothing about the others and the Win32 versions are not going anywhere.

- Only the **main window** restarts MMA. The other two are read when you press the button.
- All three go through one function — `MMA_ShellFor` in `core/paths.ahk` — so every launcher
  gets the same answer, and any of them falls back to Classic on its own if the WebView file is
  missing. A preference must never be able to leave you with no window at all.
- The choice is offered in **both** Settings windows on purpose. The Win32 one is where you are
  when the other will not open, so it has to be the one that can send you back.

That last point fixed a half-truth: the Classic main window's Settings button could only ever
open its own Win32 tabs. Pick "WebView Settings", run the Classic main window, and you got the
Win32 tabs anyway with nothing saying why. Both windows' Settings buttons now go through the
same opener.

### Importing a new model and telling MMA her name now names her

Ctrl+click a mass in Discord, type the model's name, tick **Remember this name for the model** —
and the tab still said "Model 3". You went to Settings and typed the same name a second time.

That checkbox means two different facts and only wrote the first:

- the **alias** (`[ModelAliases]`) — what this model is called *somewhere else*: Infloww's tab,
  the Discord channel the import came from. A slot can carry any number of these.
- the **name** (`[Settings] Model<n>`) — what MMA itself calls the slot, on its tab and its Load
  and Save buttons. There is exactly one.

The name is now **adopted when the slot has never been named** — blank, or still the "Model 3"
placeholder. A slot that already has a real name keeps it, because that is precisely the case
where the two differ on purpose: MMA calls her Dessy, Infloww's tab says "Dessy 🌸", and
overwriting the first with the second puts an emoji on the tab.

### Saving Settings from the WebView window now reaches the main window

The Win32 Settings is a Gui built inside the main window's own process and calls
`UpdateModelButtons()` directly when you save. The WebView Settings is its own script and cannot
— it broadcast a message saying "I saved", and **nothing was listening**. A rename or a theme
change made there landed in `mass_gui.cfg` and nowhere on screen until MMA was restarted, which
reads exactly like the setting did not save.

Both shells now handle that broadcast, and re-read the model names before repainting — the
Win32 `UpdateModelButtons` redraws from the in-memory array, so without the re-read it would
have repainted the names it already had, which looks identical to the message never arriving.

## 2.0.4 — 2026-08-23

### Clicking the next chat while f1.7 is still going out no longer splits the follow-up

A follow-up is not one message. `f1`, `f1.5` and `f1.7` go out as three, with a pause between
each, so a single keypress owns the chat box for a good second. Click the next conversation
inside that second and the parts still in flight land in the chat you just moved to — one fan
gets half a follow-up and a stranger gets the other half, and nothing anywhere says so.

MMA already dropped a stray **key** pressed mid-send; it has done since the anti-fumble guards
went in. All three of them were blind to this, because a click on the conversation list is not
a hotkey at all — it is the browser doing exactly what it was told.

So while a send is running there is now a wall over the list. **The click is held, not lost:**
its position is remembered, and the moment the send lands it is played back at the same point.
You click once, nothing appears to happen for a beat, and then the chat opens.

- **Nothing to calibrate.** The walled rectangle is `[ClickWall] Region` if you set one, else
  the conversation list you already measured for reply timers, else everything to the left of
  the `[NextFu]` pane — which is the list, on any install where the follow-up walker works.
- **It checks the list has not moved before clicking.** Infloww sorts conversations by most
  recent message, and the send holding your click is what makes one most recent — so a point
  that meant "row 4" when you pressed it can mean a different fan a second later. The wall
  keeps a patch of pixels from under the pointer and re-reads it before playing back; if the
  rows moved it says so and leaves the click to you, rather than opening the wrong chat.
- **Only the list, only while sending.** Clicks anywhere else are never touched — no hotkey is
  even registered for them — and drags and double-clicks behave exactly as they did.
- Off in Easy mode, and a checkbox in **Settings ▸ Features ▸ Sending** otherwise, read fresh
  on every send so unticking it takes hold on the next follow-up rather than the next restart.

### The hotkey editor keeps your place, and reads like a list of features

Changing a key sent you back to the top. Every time. The editor rebuilds its whole list after
an edit — it has to, because one new key can change the clash report of a row thirty lines
further down — and a rebuilt ListView scrolls to the top and forgets what was selected. So
rebinding the last three hotkeys in the list meant scrolling to the bottom three separate
times, and the further down you worked the worse it got.

Now the row is remembered **by id** and the scroll position by its top line, and both are put
back after the rebuild. Searching still starts at the top, because there the row set itself
changed and the top of a new list is the right place to be.

The same rebuild had a second bug in it: clicking a column header sorted the rows while the
panel's index of them stayed in insertion order, so from that click on, every button acted on
a different row than the highlighted one. Sorting is off — the list is grouped by feature, so
there was never a sort worth having.

**And it looks like something now.** The `Feature` column that repeated a name down the left
edge is gone, replaced by what it was trying to be: a blank line and a heading per feature, so
the groups separate whichever column your eye is in. Around that:

- **A search box that says what it searches**, and a **Show** dropdown next to it — everything,
  only what you have changed, only what clashes, only what is unassigned.
- **A mark per row.** ● means you have edited it and not saved; ○ means it is saved but is not
  what the defaults say. "What have I actually touched here" used to need the ini open beside
  the window.
- **A count on the right of the toolbar** — keys, unsaved edits, clashes, and how many are
  switched off. It counts the whole registry, never the filtered view.
- **Right-click a row** for set / default / disable / copy key.
- Mouse buttons read as `Mouse 4` and `Wheel up` rather than `XButton1` and `WheelUp`, and an
  unassigned key is an em dash rather than an empty cell — everywhere those labels appear,
  including the hotstring window's key capture.
- The capture overlay names the action it is about to rebind, and shows the key it has now.
- The standalone `hotkeys_window.ahk` follows the theme like every other window, instead of
  being the one grey box in a tinted set.

`tools/test/hotkeys_panel_test.ahk` is new and covers the scroll bug directly: it fills the
real list, scrolls it, edits through the real method and reads the scroll position back off
the control. It writes nothing — Save is never called.

### Reply timers — the list tells you a fan has been waiting four minutes

Infloww's conversation list gives you a wall-clock stamp and nothing else. Turning `7:45 am`
into "four minutes" is a subtraction you do in your head, against a clock you have to go and
look at, once per row, forty times an hour — and the row you get wrong is always the one you
were about to scroll past.

So MMA does the subtraction and paints the answer. Any conversation that is **unread** and has
been sitting past a threshold gets a thick border in that threshold's colour:

| waiting | box |
|---|---|
| under 3 min | nothing |
| 3–4 min | yellow |
| 4–6 min | red |
| 6–10 min | pink |
| 10 min+ | bright white |

Those are the **defaults**, not the design. There is no "five tiers" anywhere in the code —
`[ReplyBox] Tier1..TierN` is read until it runs out, so a sixth colour is a sixth line. Times
and colours are edited under **Settings ▸ General ▸ Reply timers** (a colour picker per tier,
clear a row's minutes to delete it), and the whole thing lives in `[ReplyBox]` in
`mass_gui.cfg` if you would rather type it.

**Only unread rows, and that is what makes it maintenance-free.** A box means "this fan is
waiting", so the row has to be one that is. Infloww marks those with a coral `#ff7c71` dot at
the right-hand end, and that dot is what MMA looks for — which means nothing has to notice you
replying. Open the conversation, the dot goes, the box goes with it on the next tick, and
there is no state kept anywhere to get out of step. Boxing *every* row was the alternative and
it is much worse than it sounds: the list is sorted by recency and runs off the bottom of the
screen, so every conversation you had already answered would keep a frame until it scrolled
away.

Four things are worth knowing about how it reads the screen:

- **It is calibrated by drawing, twice**, and it ships doing nothing until it is. Both
  measurements are rectangles on *your* screen at *your* window size, so neither has a default
  worth shipping. **Calibrate the list…** stores the region in the **window's client
  coordinates**, so moving or maximising Infloww takes it along. **Calibrate a row…** takes both
  numbers a row needs off one drag round a single conversation: the height is the box you drew,
  and the offset is where the unread dot turned out to be inside it. That second number matters
  more than it sounds — **the dot is not in the middle of its row**. It shares a line with the
  timestamp, below the fan's name, so centring the box on it drew every frame high by the
  difference. It is measured now rather than assumed.
- **A scroll blanks the layer instantly.** Finding the dots is one BitBlt and a walk down a
  46px band — sub-millisecond — while reading the stamps is Windows OCR at tens of
  milliseconds. So they run at different rates: the fast tick (400ms) exists mainly to notice
  that the set of dot positions *moved* and take every box down at once, because a frame that
  lingers half a second over the row that slid into its place is worse than no frame at all.
  The OCR pass follows at 5s.
- **One OCR for the whole column**, not one per row — same price for twelve rows as for one —
  and it reads only the right-hand strip. That is worth more than the speed: a preview reading
  *"see you at 9:30"* is a clock time in the same font as the stamp, and a wider box would have
  made it one.
- **A stamp one minute in the future is clock skew, not yesterday.** A message that lands at
  7:45:50 is stamped `7:45` and may be read at 7:45:20. Subtract naively and you get −1, which
  wraps to 1439 minutes — so the *newest* message in the list wears the *loudest* colour in the
  palette, the exact inverse of the feature. There is a two-minute grace window on the future
  side, and `tools/test/reply_tiers_test.ahk` (64 assertions) is what holds it there, along
  with midnight wrap, `12:15 am` vs `12:15 pm`, and 24-hour locales.

`Yesterday` and bare dates are floored at midnight today, so their wait comes out as however
long today has been — deliberately a floor, never an estimate. It can only ever understate,
which is the safe direction.

The frames are click-through (`WS_EX_TRANSPARENT`) — the entire point of a conversation row is
that you click it — `WS_EX_NOACTIVATE` so nothing can steal focus from what you are typing, and
`WDA_EXCLUDEFROMCAPTURE` so the next tick's scan reads Infloww's dots and never MMA's own
borders. Each one is a single window with its middle cut out by `SetWindowRgn`, so there is no
chroma key anywhere near it and none of the three failures `tab_marks.ahk` documents can
happen here.

That last flag has a cost nobody expects until they hit it: **the boxes do not appear in
screenshots.** That is the feature working, but it also means you cannot show anyone what you
are looking at. **Settings ▸ General ▸ Reply timers ▸ "Keep the boxes out of screenshots"**
turns it off when you need a picture. Safe with the shipped palette — the nearest tier colour to
the unread coral is red, 50 away against a tolerance of 20 — but pick a coral-ish tier of your
own with it off and MMA can start seeing its own borders as unread dots.

**Off by default.** Switch it on under **Settings ▸ Features** or in the **Tools** window,
where it has a live running state like every other background tool. `[gui] toggleReplyBox`
shows and hides the frames without stopping the service, and ships unbound.

*Also:* the system colour dialog moved to `THEME_ChooseColour` in `core/theme.ahk` — the tab
bars and the reply tiers both need it, and one hand-packed 72-byte x64 struct is enough.

### Typelog — mine your own Infloww typing for hotstrings

The old standalone `typelog` project is now an MMA background service. It records the text
you type **while Infloww is in front** into `userdata\typelog\YYYY-MM-DD.log`, so you can find
your most-repeated phrases and turn them into hotstrings — the Hotstrings manager's job from
the other end.

It is wired in exactly like the pinger and the automation listener: a headless Python process
(needs `pynput`) with no console and no window, launched via a `.vbs`, driven by a named
stop-event, kept alive by the watchdog, and toggled from **Settings ▸ Features ▸ Typelog** or
the **Tools** window with a live running state.

Two things set it apart, both on purpose:

- **It is OFF by default, and it is the one tool that keeps *what* you type.** The activity
  tracker was built so it structurally cannot; this is built to. Within Infloww that includes
  fan handles and message text, so it ships off and must be switched on deliberately — the same
  consent gate as the tracker, for a stronger reason. The log lives under `userdata\`
  (gitignored) and never leaves the machine.
- **Pause it before typing anything private.** The `[typelog] pause` hotkey (default
  `^!F9`) lives in `hotkeys.ini` like every other key and is edited in the Hotkeys GUI —
  but bound by Python (pynput), same arrangement as `[automation]`. `typelog.pyw` converts
  the AHK key string into pynput's format so `^!F9` just works.

### Autoword — next-word suggestions trained on your own typing

Typelog collects the corpus; this is the thing that reads it back. While you type in Infloww,
Autoword predicts the next word and offers it on **Tab**. Because the corpus is what you typed
*by hand*, and everything you send through a hotstring never passes a key hook at all, it is
trained by construction on exactly the phrasing no hotstring covers yet.

**Ctrl+Tab** runs the other way: instead of the next word it offers other words for the one you
just finished — `touched` → `caressed`, `stroked`, `grazed` — out of a group file you own, with
the inflection carried across so `touched` does not become `caress`.

It is wired like the pinger and typelog: a headless Python process (needs `pynput`), no console
and no window, launched via a `.vbs`, stopped by a named event, watched by the watchdog, and
toggled from **Settings ▸ Features ▸ Autoword** or the **Tools** window.

**Off by default, and it ships blind on top of that.** Typelog is off because it keeps what you
type; Autoword is off for that reason *and* one of its own — Tab puts text into the message box,
and nothing that types on your behalf should ever arrive already switched on. So switching the
feature on still shows no UI: it starts in `Render=off`, predicting normally and writing what it
*would* have suggested to `debuglogs\autoword_shadow.log`. That measures accuracy against your
real typing with nothing on screen and no wrong suggestion able to cost you a keystroke. Set
`Render=strip` in `userdata\autoword.ini` when you want to see it.

Two seams are protocols rather than classes — `Predictor` (the trigram model) and `Renderer`
(`off` / `strip` / `ghost`) — so swapping either is one new class and one line in `autoword.pyw`.
`ghost` — grey text drawn at the caret — is deliberately **not implemented**; `strip` anchors to
the foreground window instead, which is the whole reason it is the simple one, since it needs no
accessibility API and nothing about it breaks when the target app re-renders.

`python autoword.pyw --evaluate` reports held-out accuracy and changes nothing; `--train`
rebuilds the model from the corpus.

### Grab a message off the screen and make it the follow-up

The OCR grab (`^+o`) has always ended in the same place: **Add Hotkey**, which writes a
hotstring — a trigger you type. But the text you drag a box around is usually a message you
just sent **by hand**, and the reason you grabbed it is that it worked better than the
follow-up MMA has. That belongs in the mass, and until now the only route was to remember it,
find the model's tab, find the right box and retype it.

```
drag a box (^+o)  →  Replace follow-up…  →  model · mass · follow-up  →  Replace
```

**The three dropdowns open on the follow-up you last sent.** That is the whole ergonomics of
it: you press f2, the fan does not bite, you write something better yourself, grab it — and
the window is already aimed at f2 of that model's live mass. The engine notes model, mass slot
and group on every follow-up and PPV press (`[LastSent]` in `mass_gui.cfg`), on the **press**
rather than on a successful send, because a follow-up that had nothing to send is exactly the
one you are about to go and write.

Two verbs, on one window:

- **Replace** overwrites the trunk — what the plain key sends. One message per line, up to
  three; a fourth is refused with both counts rather than dropped. Sub-slots the new text does
  not fill are **cleared**, so a replace can never leave an old `f2.7` trailing a new `f2`.
- **Add as alt** files the same text as a branch instead — the overload, offered on the
  follow-up key with `Tab`.

It is the **Add alt-FU** window, not a new one: same four questions, same preview of what the
follow-up says right now, same `::name` parsing. It only differs in the two places it must —
where the dropdowns open, and whether it saves. Reached from a capture it commits (through the
same `ApplyFile` the Save button calls, so the library still has exactly one writer), because
during a capture the main window is behind Infloww and "now go and press Save" is a trip that
would not be made. Reached from the Variants grid it still writes into the grid and waits, so a
mistake is undone by closing the window. The line under the buttons says which of the two you
are in.

The Add Hotkey window is left open behind it — a grab is expensive to make twice, and
cancelling over there should not cost you the text.

### A branch builder — draw the conversation, get a mass

`^!b` opens a visual editor for the thing the old `docs/proposals/branching.md` asked
for: a conversation drawn as a tree, with what **the fan says back** as a node in it.

```
!mm  →  fan replies  →  f1  →  fan replies  →  f2  →  f3
```

One column per follow-up, so the room you have left is on screen *before* you run out of
it. Cards carry the message; the orange chip on top is what the fan said to get there.
`+ next` continues a route, `+ fork` adds another thing they might have said, and two
routes can **merge** back into a shared ending — edited once, sent by each.

**It compiles to an ordinary mass, and that is the whole trick.** One root-to-leaf path
through the tree = one named branch. The first route is the trunk (f1/f2/f3); the rest
become `::named` branches, named after the fan reply that forked them — so `::plays-along`
instead of `::br2` when you are staring at a picker window mid-shift. Nothing in the
engine or the parser changed: the builder emits the same `!mma` text `Export !mma`
already writes. The preview pane under the canvas shows exactly what MMA will receive,
and it is produced by the same compiler that Save uses, so the two cannot disagree.

**Limits are reported with a count, never truncated.** A route with four messages after
the opener has nowhere to put the fourth, and seven forks is one more than a mass holds.
Both say so, and say which route — losing a message you typed is the one failure a
builder can hand you that looks like success.

`Copy !mma` puts the compiled text on the clipboard for the normal paste-and-Parse flow;
`Save to a mass…` writes it straight into a model's slot. Flows live in
`userdata\branch_trees.json` and autosave as you type.

### An activity tracker, and a chart of how you actually work

New background tool, **off by default**: it counts keystrokes, characters, backspaces,
mouse clicks and active seconds into `userdata\activity\`, one row per counter per minute.
`^!g` opens the chart — four KPI tiles, a timeline of the day, a weekday×hour heatmap of
when you actually work, and the correction-rate curve through the day.

Beyond keys-per-minute it answers the questions keys-per-minute cannot:

- **Keys per *active* minute.** Wall-clock minutes only measure how long the window was
  open. A second counts as active when there has been physical input in the last two
  seconds (`[Activity] IdleMs`), so breaks come out of the denominator instead of
  flattening the average.
- **Correction rate** — backspaces per 100 characters, by hour. It climbs as you tire,
  and it is the clearest end-of-shift signal in the data.
- **Longest stall**, recorded in the minute it *ended*, so a pause is attached to the
  time you would look at when asking what happened around then.
- **Mouse share**, for whether a shift went through the keyboard or the mouse.

**It counts and never records what.** The file format has nowhere to put a character —
`minute,counter,value`, with a closed list of counter names. No text, no window titles, no
hotstring triggers. MMA's own sends are excluded (`MinSendLevel := 1`), so a mass paste
does not inflate your typing speed — otherwise the number would go *up* the more work MMA
did for you. Off by default because "counts your keystrokes" is something you switch on
deliberately, not something you find already running; its hotkey is dead while it is off.

Nothing is written for a minute you were not there, so leaving MMA running overnight adds
no rows at all and a year of this stays in the low megabytes. `[Activity] KeepDays`
prunes older files; `0`, the default, keeps everything, because this is a log kept in
order to spot a pattern across months.

The chart is drawn by WebView2 — the same runtime the WebView main window uses — and the
tracker keeps recording whether or not it is open.

### A mass can be written under a bare `!mma`, and the `!mm` box can hold it

The shape people actually paste — the marker alone on the top line, the message under it:

```
!mma:

If you were my artist, how would you picture me? 🎨

Would my curves take over the entire canvas...
Or would you only sketch the parts you couldn't stop thinking about? :3

Would your artwork be bold enough to leave people speechless? ♡
```

That is **one** message. The blank lines in it are paragraph breaks, not group separators.

**What it did before.** Every other form puts the mass *on* the marker line, so a marker with
nothing after it set the mass to the empty string — and then positional mode read the paragraphs
as `f1`, `f2`, `f3` and dropped the fourth with a line in the log. The opener went out as three
replies, or as nothing at all, and the only thing that said so was `__mm` reporting an empty slot.

The block ends at a `---` fence (eaten with it), at a labelled line — a field name, an `f`/`fu`
prefix, `ppv`, a `::branch` — or at the end of the paste. **Close it with a fence if follow-ups
come after it**, because positional follow-ups carry no label to stop it with themselves.
`Export !mma` writes exactly that form whenever the mass spans lines, so a multi-line mass
round-trips through Export and back.

The `!mm` box in the window is **multi-line** now, like `ppv`. It had to be: a single-line Edit
renders those paragraph breaks as little boxes you cannot see past or edit around, which would
have made the mass unreadable in the one place you edit it.

### Tab marks are now just bars, and they stop flickering

The stars are gone and the divider is the whole feature — and it went from **four hotkeys to one**.

`^!,` puts a bar where the pointer is. That is the entire keyboard surface. Everything else is the
bar itself: **left-drag** to move it, **right-click** for its menu — remove · colour (eight presets,
the system colour picker under *Custom…*, or apply one to every bar) · size (taller / shorter /
wider / narrower) · add another · hide the lot. Colour is **per bar**, so you can group the strip by
more than position; the cfg line grows a third field for it (`Bar2 = 338,44,4AC9FF`).

**Why there were four keys.** The bars were click-through — every click landing on the tab
underneath as if they were not there — because they sit on the most-clicked object on the monitor.
A window you cannot click is a window you cannot drag or right-click, so every verb had to become a
key, and moving one needed a whole mode to turn the click-through off and back on.

The reasoning was sound and the conclusion was wrong, because of the scale: a bar is **five pixels
wide** and it goes in the *gap* between two tabs, which is where a divider goes by definition. The
thing being protected was five pixels of a 180-pixel tab, in the one place on the strip you were
never aiming at. Not worth three hotkeys and a mode. The bars are ordinary little windows now. They
keep the half that matters — clicking one never takes focus off the chat box you are typing in — and
`[Marks] ClickThrough=1` puts the old behaviour back for anyone the five pixels does bite.

Dragging is **Windows' own move loop**, not a timer. An earlier cut had a "carry" mode where a
picked-up bar chased the pointer at 25 ms, and it felt awful for a reason no tuning fixes: a timer
polls, a drag loop is driven by the mouse messages themselves. Forty ticks a second still trails the
cursor and arrives after you stop.

Bars are also **wider and taller** by default — 5×36 rather than 3×26.

**The flicker was a real bug, not a tuning problem.** `MARKS_Sync` cached the client rect so a still
window would not redraw, then called `MARKS_Build`, whose first act cleared that cache. The guard
could therefore never hold, and a full-client-width, always-on-top, layered window was **destroyed
and recreated every 400 ms, forever**, on top of a compositing browser. Each rebuild also showed a
full-width magenta band for one frame, because a transparency key can only be applied to a window
that already exists.

**And they were placed wrong on any display above 100 % scaling.** The overlay had no `-DPIScale`.
`Gui.Show` multiplies its coordinates by the display scaling; `MouseGetPos` does not — so at 125 %
a bar placed at x=400 landed at x=500. Every other screen-coordinate overlay in the tree already
carries that flag and says why.

Both are structural to the old design, so the design changed: **a bar is now its own tiny window**,
three pixels wide, filled with its own colour. No chroma key (nothing to punch out), no controls, no
glyph, no font. Moving one is a `WinMove`; the timer never creates or destroys anything. That is
also why the stars had to go — a glyph is what needed the transparency key that caused all of it.

Existing `Mark1 = sep,412,44` lines are converted to `Bar1 = 412,44` on the first start. `star` lines
are dropped, with a line in the log for each. `[Marks] GrabPx` sets how close the pointer has to be
to pick a bar up.

### Lock a model, and the side buttons stop asking

"I pick" mode opens a window on every shared follow-up key to ask which model. That is the right
question when you do not know, and the wrong one for how a shift is actually worked: every message
for one model, then the next model. Twenty minutes of the same side button is twenty windows for
one answer — and a window you dismiss by reflex has stopped being a safeguard.

**Locking answers once.** While a lock is on, every `[mass.active]` key — the side mouse buttons
included — sends that model, with no window and nothing read off the screen. The sequence it is
built around:

> pick the model in the window → **`^!l`** → clear that model's messages → **`^!l`** → next model

The lock is also a **toggle in the "Send follow-up" window itself** — the checkbox on its bottom
row, which names the key beside it and flips the lock the moment you click it, reading
`Locked to <name>` while on. Clicking a different model button with it ticked *moves* the lock.
There is a **Lock to *name*** button in the main window too, which locks to the model tab in front
(hence the name on it). All three write one setting, so none of them can disagree.

`^!l` locks to whichever model is already resolved — in "I pick", the one you last chose. If MMA
has no answer it **refuses and beeps low**; locking to a guess is the one thing this must not do.

**Moving to the next model does not need an unlock:** press its `^!N` and the lock *moves*. The
unlock in the sequence above is there to put the "which model?" net back for the model you have not
chosen yet.

A small **LOCKED** badge sits in the corner naming the locked model for as long as the lock lasts.
It never takes focus, and **clicking it unlocks** — as does `^!l` again, or the button, which reads
`Unlock (name)` while a lock is live. Unlocking gives the picker back, unchanged.

That badge is not decoration; it is the condition on which the whole feature is offered. A lock is
a mode in which a key you press sends to a model **nothing on screen identifies**, which is exactly
the shape of mistake that puts one model's message in another model's chat — reached on purpose
this time, and only acceptable because something on screen says so. A tooltip could not do the job
(they expire; this state lasts twenty minutes) and neither could MMA's own window, which is behind
Infloww all shift. Move it if it is in the way — `[Lock] BadgeX` / `BadgeY` in `mass_gui.cfg`, in
screen pixels — but keep it where you will see it.

It is a lock, not a fourth strategy: it applies whatever Settings ▸ Models says, so it will
override a working detector if you ask it to. The numbered per-model keys are untouched by it, as
by everything else in that section.

### `::branch` on its own line now parses — and two of them are not four follow-ups

A mass written the way a mass is actually written did not parse:

```
which curve of mine entices you the most        <- f2

::tits
would you mind if I smothered you with them?

::ass
I want to make you my personal throne
```

Two separate faults, and the result was worse than nothing happening. `::tits` with no text after
it was read as *"this branch has nothing to say here"*, so the sentence underneath **fell through to
the trunk's f3** — one branch's wording became the message every fan gets. Then the `::ass` block
was counted as a **fourth** follow-up group, and there is no fourth, so it was **dropped entirely**.
One line in the log for the second one; nothing at all for the first.

Both are fixed:

- **A marker alone on its line owns the lines under it.** `::tits` followed by a sentence means that
  sentence is the branch's, and several lines under one marker are several parts of its answer (f3,
  then f3.5) — exactly as repeating the marker would be. A marker *with* text on its line still
  keeps its hands off the next line, which is what every mass written before this relies on, and a
  marker with nothing under it still says nothing rather than sending a blank line.
- **A group that opens with a marker is the next follow-up, and consecutive branch-led groups share
  it.** They are choices at the same step, not successive messages. In the paste above that is one
  f2 asking a question and two f3s answering it, with **no trunk f3 at all** — which is correct,
  since what goes out depends on her answer.

It also works in the labelled modes, where an unlabelled line under a marker used to be dropped on
the floor for having no slot of its own. A line carrying its own `f2` / `ppv` label always closes the
capture — without that precedence one marker would have eaten the entire rest of the paste, which is
exactly what the first version of this fix did until the test caught it.

`branch_parse_test.ahk` covers the reported paste and both boundaries: 62 assertions, up from 40.

**`docs/mass-format.md` was describing a format MMA does not read** — `alt:` and `--Name`, both
removed a while ago — which is a fair part of why this looked like a parser bug rather than a
syntax mismatch. That section is rewritten around `::name`, and the guide gained the own-line form
and the branch-led-group rule.

### Stars and separators you can stick on your own tabs

Eight near-identical tabs are hard to read at a glance, and no amount of detection helps: the
problem is not that MMA cannot tell them apart, it is that you cannot, quickly, forty times an hour.

So draw on them. **`^!.`** puts a star on the tab under the pointer, **`^!,`** puts a thin separator
there for splitting the strip into groups, and either key pressed over an existing mark takes it off
again — that is the whole of removal, because the layer has to be click-through and therefore cannot
be clicked. **`^!0`** hides the lot when you want the tabs bare. Off switch in **Features ▸ Tools**.

**A star means whatever you meant by it.** MMA never moves one, never reads one, and never works out
which model is which from one. That is deliberate and worth stating plainly: a mark MMA also
*maintained* would be a second, silent claim about which model is which, and this tree has already
paid for one of those. Which model is live is the LOCKED badge's job, and it looks nothing like a
star.

Marks live in `mass_gui.cfg [Marks]` as `kind,x,y` in the target window's own coordinates — so they
ride along when you move or resize it, and **nothing has to be calibrated first**, which is what
lets this work on a strip MMA cannot read at all. The same section carries the look (`StarChar`,
`StarColor`, `StarSize`, `SepColor`, `SepWidth`, `SepHeight`) and `WinMatch` for which window they
belong to. Deleting the section clears them.

Three things it was made to get right, all of them measured rather than assumed: every click passes
through to the tab underneath and the layer can never take focus off a chat box; the overlay asks
Windows to leave it out of screen capture, so MMA's own tab-strip scan reads the tabs and not the
stars; and the glyph is drawn with a magenta transparency key, because a discreet near-black key —
the obvious choice, and the first one tried — does not key at all and paints every star into a solid
black box.

### A Fansly model is no longer offered as an Infloww tab

**Settings ▸ Models** built both order rows out of every model: one dropdown per model on each
site, each listing all of them. On a mixed setup that is a question with no right answer in it —
"which model is Infloww tab 3" has none when only one of your four models is worked in Infloww, and
offering a Fansly model as the answer invites a mapping that sends that model's mass into an
Infloww tab, silently, at a real fan.

Each row is now built from the **Platform** column above it: as many dropdowns as that site has
models, each listing only those models, with `no models are set to Infloww` in place of the row when
a site has none. It follows the Platform dropdowns **live**, so moving a model to Fansly takes it
out of the tab order in front of you rather than after a save and a reopen.

Two things that come with it: the saved order is written through the same filtered list the row was
built from (a dropdown's index is no longer the model number, and getting that wrong would write
"tab 1 = model 2" while the screen said something else), and positions the site does not have are
written as **0** — read as *"no answer"*, so the shared keys do nothing instead of acting on a
stale `Pos3=3` left behind by a model that has since moved sites.

### The Discord Ctrl+click import is quicker off the mark

It opened the context menu, slept a flat **250 ms**, and then looked for "Copy Text" exactly once —
paying the full 250 on every import even when the menu was up in 60, and failing outright if it was
not up yet, because there was no second look.

It now polls: first look at 60 ms, again every 55 ms, up to 600 ms from the right-click. Each look
is also cheaper — the OCR read is boxed to a rectangle around the cursor (the menu opens *at* the
cursor) instead of reading the whole Discord window at scale 2, which was ~157 ms a go, and the
bitmap match's search box shrank with it. If the boxed reads all come up empty it still falls back
to one whole-window read, so nothing that worked before stops working; that fallback says so in the
log, since a common one means the box is too small.

The log line now carries how many looks it took and the ms from the right-click, so "is it actually
faster on this machine" is a question the log answers.

### A hotstring can have a hotkey now

Some messages go out often enough that typing the trigger is the slow part. Any hotstring can
optionally have a key as well: select it in the Hotstrings window, press **Hotkey…**, press the
key. Esc cancels, Backspace removes one, and a new **Key** column shows what is bound.

The trigger keeps working exactly as before — the key is a second way to fire the same thing.
Overloaded hotstrings still offer their variants from the key, because the handler goes through
`Overload_Run`, the same path the trigger takes. What gets sent is read from your `.ahk` source at
load through the same index the Hotstrings window uses, so **the message is never copied**:
reword it and the key's message changes with it.

It is stored in `hotkeys.ini` under `[hotstring]`, one line per binding, `trigger = key` — the
same file, format and conflict report as every other key in MMA. Binding one checks for a clash
first and names what already owns that key.

This is the sanctioned version of something that was already happening: `content\accounts\TEMP.ahk`
has had bare `!9::` and `!8::` blocks written straight into it, each sending one message. Those
work, and they are invisible to the Hotkeys tab, invisible to the conflict report, and lost the
first time that file is tidied — TEMP.ahk's own header says as much about the `!1::` before them.

**Add hotstring… has a Record button**, so a key can go on at the moment you write the message —
which is when you know it is one you will send forty times a day, rather than later in another
window having remembered. Press Record, press the chord, press Append. Nothing is written until
Append, and Clear drops it. It is recorded rather than typed: the Hotkey box in that dialog has
always accepted `^!9` as *text*, but that writes a bare hotkey block into the message file, which
is the invisible-to-everything shape described above.

**Duplicates are refused, in both places** — you are told what already owns the key and asked to
pick another, with no "bind it anyway". Elsewhere in MMA two ids may share a key when their window
contexts do not overlap; a hotstring key is global, so it overlaps with everything, and "both fire
and whichever script loaded last wins" is not a state worth offering as a confirm button. The
check is `HK_KeyOwner`, which reads the ini rather than the calling process's own declarations —
the GUI has never heard of an id declared only in a message script, and a duplicate check that
only knows one process's ids goes quiet exactly when it matters.

Two more things worth knowing:

- **The key is global**, like the hotstring it stands in for. A hotstring fires wherever you type,
  so its key fires wherever you press it. Pick chords you would not otherwise hit.
- **A new binding restarts the message script that owns it**, and says so — a script reads its
  keys when it loads, so until it does the key does nothing, which is indistinguishable from the
  feature being broken. Changing an existing key applies live.

#### Dotted triggers, and a rule that was pointed the wrong way

The first cut of this refused any trigger containing a dot, on the grounds that hotkey ids are
`section.name` and split at the **last** one — so `hotstring...intro` read as a section that does
not exist, and the key would have been written in one place and read from another. That reasoning
was right and the conclusion was backwards: 23 of the 110 triggers in the library are named
`..intro`, `..ppv4f2`, `..bump2`. It was a rule about MMA's id format, dressed up as a rule about
someone's triggers, and it turned away a fifth of them.

`HK_Split` splits `[hotstring]` ids at the **first** dot instead — that section has no
sub-sections, so everything after it is the key, and the ini reads exactly as the trigger is
written: `..intro = ^!1`. Every other id still splits at the last dot.

The one character that genuinely cannot work is `=`, and the guard for it is at the two windows
that write a binding rather than at the reader — which is worth writing down, because the reader
is the obvious place to put one and it would be dead code there. `IniWrite` of the trigger `a=b`
emits `a=b=^!1`, which reads back as a trigger called `a`: mangled before any reader exists to
object. No trigger in the library has one.

The ids are declared **after every static one**, which is load-bearing rather than tidy: the
Actions menu runs an action by broadcasting its index in `HK_ORDER`, and these come from the ini,
so a script started before you bound a hotstring has a shorter list than one started after. Keeping
them in a tail past everything static means every static index still means the same thing in every
process, and the Actions menu skips these rows so nothing it displays can shift.
`tools/test/hotstring_key_test.ahk` asserts exactly that, plus the sort that keeps the tail stable
and the dot refusal.

### Variants ▸ Add alt-FU… — a form, instead of knowing how the grid works

The Variants grid shows a whole mass at once, which is the right shape for reading one and the
wrong shape for adding a line to it. To add an alternative there you had to already know that a
row is a branch, that a column is a follow-up, that the row needs a NAME before the picker can
offer it, and that a second wording goes on a second *line* of one cell rather than in the next
column. None of that is written anywhere on the window.

The new button asks the four questions in order — **which model · which mass · which follow-up ·
what does it say** — and shows what that follow-up currently says, plus which branch names are
already taken, because you are writing another wording of something and the something was the
one thing you had to go and look up.

The paste box takes either form, and that is the point rather than a convenience:

- **No markers** — the box is one branch, one message per line. Named from the Branch name box,
  or `alt`, then `alt1`, `alt2`… if the mass already has one. A name you *type* is never renamed
  behind your back: typing one that exists means "add to that branch".
- **`::name` lines** — parsed exactly as a real paste is, markers kept, **nothing auto-added**,
  several branches in one go. Working alt code copied out of Discord goes straight in. A bare
  line under a marker continues that branch; a line *above* the first marker is the trunk being
  copied along for context, and it is dropped rather than filed as an alternative of itself.

Detection is `BranchMarker()` from `mass/parser.ahk`, not a regex of the new window's own — two
answers to "is this a marker" is two behaviours, and the one that would be wrong is the one a fan
sees.

It writes into the **grid**, never to `masses.json`: you see what it did before committing, Save
to file stays the only writer of your library, and closing the window undoes a mistake. The
status line says as much after every Add, because "it worked and nothing is saved yet" is the
state people get wrong.

`tools/test/altfu_build_test.ahk` covers it — 52 checks over the writer, the auto-naming, the
paste rules and the window build.

### The self-tests moved to `tools/test/`

A probe binds a key and stays resident so you can look at your screen through it; a test asserts,
prints `N passed, M failed`, and exits. They had nothing in common except a folder, and the only
thing that distinguished them was the filename — which lied in both directions.

The eleven assertion files are in [tools/test/](tools/test/) now, with a README covering how to
run one by hand and which of them write real settings. `model_detect_test.ahk` and
`discord_header_test.ahk` stayed in `tools/` because they are **probes** despite their names —
`debug_panel.ahk` has always listed the first of them under `PROBES`. Renaming those two to
`*_probe.ahk` is worth doing and is not done here.

Two things came out of it: `branch_parse_test.ahk` was written and then never added to
**Settings ▸ Debug ▸ Run all**, so it only ever ran by hand — it is in the list now, along with
the new alt-FU test. And nothing broke in the move, which is worth a line: `MMA_ROOT` comes from
`A_LineFile` in `paths.ahk` and not from `A_ScriptDir`, so a test one folder deeper still
resolves every path in MMA. Only the tests' own `#Include "../src/…"` lines needed the extra
`../`.

### The Hotstrings window was too narrow for its own footer

Its footer is two clusters that grow towards each other — six buttons pinned left, Sort and Text
size pinned right — and the width was a round number rather than a measured one. Left cluster
ends at 686px, right cluster claims the last 310: that is 996 with the two touching, against a
1000px default and a **900px minimum**. So at the default there were four pixels between them,
and anywhere below 996 the buttons were drawn *underneath* the dropdowns.

Now 1120 wide with a 1020 minimum, both derived from those measurements and written down next to
them. The window also lays itself out through its own `OnSize` on open instead of trusting the
coordinates each control was created with — a Gui does not fire `Size` on `Show`, so the window
you got before touching it was laid out by one set of rules and the window you got after dragging
it by another.

### Settings ▸ Models is about one question now, and asks it once

The tab was three settings stacked in the order they were written: model rows, the wait time,
then "Which model is on screen" — a heading that named a symptom rather than the feature. What
all of it actually configures is **one key per action instead of one per action per model**, so
that is what it is called: **Use a single hotkey for all masses**.

It now reads top to bottom as one decision:

- **Enabled** — a new `[Settings] SharedKeys`. Off, every `[mass.active]` key bails and says so
  in the log, and the numbered per-model keys carry on untouched. That is a real answer, not a
  broken one, for a machine where nothing on screen identifies the model and a picker window in
  front of every keypress is not wanted. Read per keypress, so it applies to the next key —
  no restart. It is deliberately **not** a `FEAT`: Easy mode switches off everything in that
  registry, and doing it here would silently kill every shared key on a setup that has nothing
  else. See `SharedKeysOn()` in `core/active_model.ahk`.
- **Strategy — Manual, or Automatic.** "I pick" is gone as a name; the mode it described is
  Manual, and the window does the picking (`mass/model_picker.ahk`). Its "I pick — active model"
  dropdown went with it. That value still exists in `[Settings] CurrentModel`, written by the
  picker and by the `[mass.select]` keys — but it is a consequence of what you last picked, not
  a thing to set, and a dropdown for it was a second place to answer a question the window
  already answers.
- **Automatic, per site.** Two sites, two detectors, two answers, and a mixed setup is the
  normal case. **OnlyFans (Infloww)** keeps `[Settings] ModelMatch` (`name` / `position`), which
  is all that key has ever described. **Fansly** gets `[Fansly] Match` — which has existed since
  the rail detector shipped and had **no control anywhere**; setting it meant hand-editing
  `mass_gui.cfg`. The rail order (`[FanslyPos]`) was in the same state and now has its dropdowns
  next to Infloww's tab order.

Manual greys out every automatic control the moment you click it, and switching the section off
greys the strategy too — rather than at Save, or not at all. A control that is live but ignored
is the shape of every "I set that and it did nothing" this window has produced.

### New tab: General

The **wait time** was on the Models tab, between the model rows and the detector block, splitting
the one page you go there to read. It says nothing about a model. It is on a **General** tab of
its own now — the first tab, with room for the next setting that belongs to MMA rather than to
one feature — and it carries the warning it never had: it is the one setting stored as *source
code*, so saving it rewrites `core\utils.ahk` and restarts the scripts.

Every tab after it shifted by one. Settings is eight tabs.

### Smaller things

**Button labels are bold again**, on every MMA window and on every theme —
`THEME_BoldButtons()` in `core/theme.ahk`, applied after the controls exist. It is deliberately
not part of the theme pass: that returns early on the classic theme, where Windows owns the
colours, and a classic window should still have readable buttons. Weight is not palette.

**Changing the theme restarts MMA.** It used to repaint in place, which reached the background
and the input boxes but not the colours baked into controls when they are created — the label
ink and the tab strip's accent — so the window ended up half in the new theme and looked broken.
Now it reloads, the same as changing the model count.

**Settings ▸ Debug has a "Desktop shortcut" button.** It writes `MMA.lnk` pointing at
AutoHotkey with `MMA.ahk` as its argument, not at the `.ahk` file itself: a bare `.ahk` shortcut
goes through the file association, which might be v1 or missing on another machine, and then the
shortcut fails in a way that looks like MMA is broken rather than unlaunchable.

**Hotstrings' "Add hotkey…" button is "Add hotstring…"** — it is called what it makes. (The
dialog it opens is shared with the grab-selection hotkey and still calls itself Add Hotkey.)

**The empty corner has someone in it.** `assets\anime_girl.png` is drawn in the dead space under
the right panel's button stack, above the credit — the one block that is empty at every window
size, because the stack is a fixed height and the panel is not. Any source image works; the
aspect ratio is kept. No file, no picture, no error.

She is scaled to the space rather than pinned to one size: eight copies are built at startup and
the largest that fits is shown — 156x180 in a default window, **312x360** maximised on 1080,
468x540 on a bigger screen, and 113x130 at the minimum window size. She sits at the bottom of
the z-order, so any control that ever reaches that corner is painted over her, not under.

Which one fits is decided against the panel's actual control rectangles, not a box drawn under
the whole button stack. That rule was far too mean: the stack's bottom half is a status line and
a grey note, both left-aligned in a panel half again as wide, so it threw away a tall column of
genuinely empty space and capped her at a third of what fits. Two labels down there were also
wider than anything they hold (320px and 330px), and empty pixels inside a control are not free
when something else is sizing itself to what no control claims — they are 220 and 300 now.

(Eight copies, and not one that resizes, because a Picture control scales its bitmap when it is
*created* and AHK v2 cannot destroy a single control — the alternative was rebuilding the window
on every drag. The steps are spaced rather than fine because each one is a GDI+ scale of the
source at startup.)

### Alts and branches were never two things

A mass could carry two kinds of alternative and they were the same idea wearing different
clothes. An **alt** (`alt:` / `alt0:`) was another wording of one follow-up. A **branch**
(`--Name`, in a block of its own at the bottom) was another wording of one follow-up that also
implied the next two. Two syntaxes to write, two shapes on disk, two halves of the Variants
window to edit — and at send time the follow-up key merged them back into one list anyway,
which is what you actually saw in the chat box.

So there is one of them now, and it is the branch:

```
!mma the mass

follow up 1
::alt folow up 1 alternative
::mexican mehico
::german germaniaaaaa
::german gernabiaaa22222

follow up 2
::alt fu2
::alt ffu2.1
::mexican
```

**`::name text` is the only marker.** `alt` is not a feature — it is the name you give a branch
when the wording has no better name. A branch keeps its identity by *name* across the whole
mass, so the `::mexican` under follow-up 2 is the same mexican you picked at follow-up 1, and
picking it still commits you to it for f2, f3 and the PPV.

**The same name twice in one group is one branch with two parts**, not two choices: `::german`
above answers f1 with two messages, which go out as f1 and f1.5 — exactly as two unmarked lines
are the trunk's f1 and f1.5. Three per group, the same three sub-slots the trunk has.

**A branch is written where it belongs**, in the follow-up it answers, instead of in a block at
the end that repeated the whole positional layout. `::mexican` with nothing after it says
nothing for that group — it does not send an empty message.

**Six branches per mass**, up from three, because branches now carry what the three alt fields
used to.

#### The Variants window is a grid

|          | FU1 | FU2 | FU3 | PPV |
|----------|-----|-----|-----|-----|
| main     | *(echo of the main panel)* | | | |
| mexican  | mehico | | | |
| german   | germaniaaaaa<br>gernabiaaa22222 | | | |

It was four cells — one per follow-up — each listing "main", three alt boxes and three branch
boxes. One branch was therefore four boxes in four corners of the window, tied together only by
a repeated row label, and the alt boxes in between belonged to no branch at all. Answering
"what does mexican say?" meant looking in four places.

Now: across a row is one branch's whole conversation, down a column is every way to answer that
one follow-up — which is the list the key stages and <kbd>Tab</kbd> walks. The name is edited in
the row it names.

#### What this costs

The `fu<N>_alt<i>` fields are **left on disk and no longer read**. Nothing is deleted, so going
back to 2.0.2 finds your alts intact — but until a mass is re-pasted, alts written in the old
syntax are not sent. `--Name` branch blocks parse as ordinary message lines now; the branches
already *saved* from them are untouched and still work, since a branch is stored exactly as it
was.

`tools/branch_parse_test.ahk` covers the format: 40 checks over the shipping parser, including
the example above.

### "Manual" is not a platform

Settings ▸ Models offered **Infloww (detect) / Manual (you say) / Fansly (detect)** per model.
The middle one is not a site — it is a way of deciding which model is on screen, and that
question already had its own setting three rows further down (**Decide which model by: I pick**).
One question with two answers in two places, and the two could disagree.

The dropdown is now **Infloww / Fansly**. A config still holding `Platform2=manual` reads as
Infloww; the word stays on disk and nothing rewrites it. "I pick" is unchanged and still does
what it always did.

**The import prompt now asks which site a model is on.** Ctrl+clicking a Discord message from a
channel MMA has not seen before opens *Import — route to model*, which is the moment you are
telling MMA about that model — so it asks there, once, instead of leaving the platform on its
default in a window you have no reason to open. It follows the model dropdown (platform is a
fact about the slot) and is saved whether or not "Remember this name" is ticked.

### The selected model is purple, and Load/Save follow it

The tab strip marks the selected tab with a few pixels of shading. On the dark theme that is
close to nothing, so "which model am I typing into" was a question you could get wrong for a
whole mass — and the way you find out is a save into the wrong model's file.

**The selected model's name in the tab strip is now violet and bold.** The others are not.
Same strip, same tabs, same names — only the one you are on is coloured. (A tab control gives
you no say over its text colour, so MMA draws the labels itself: the system still draws the
tab shapes in your visual style, and only the text is ours.) On the classic theme, where
Windows owns every colour and a hard-coded hue could land unreadably on a high-contrast
scheme, the selection is marked with bold alone.

**The right panel's load/save grid is now one Load and one Save.** They act on the tab in front
of you and they carry its name — **Load Bellarama**, **Save Bellarama** — and both relabel the
moment you switch tab.

The grid was a fair layout at two models, where it was four buttons. At eight it is sixteen,
wrapped over six rows, and picking `save Bellarama` out of them is a reading task performed at
speed next to `save Bella` — while the tab in front of you already said which model you meant.

Nothing about *what* a save writes has changed: it is still the **mass #** picked on that
model's own tab.

**Settings → GUI → "Use legacy Load/Save UI"** brings the per-model grid back. It is a real
fallback, not a courtesy: the grid can load or save a model you are *not* looking at, and the
pair cannot. It decides which controls the main window builds, so ticking it reloads MMA —
same as the model count.

### The bottom strip loses five things it was only holding for lack of anywhere better

The main window's bottom row is what you reach across on every send, and half of it was
things you touch a few times a year. Nothing here is removed as a feature — four of the five
moved to where you are already standing when you want them.

**Open with Code** and **How to Use** are in **Settings → Scripts**, on the row that already
holds Wipe TEMP and Check update. One opens an editor over the whole source tree and the
other opens the manual in a browser; on the strip they sat *between* Settings and Add Hotkey,
which are things you press mid-shift, so every real press had to read past them.

**Add Hotkey** is in the **Hotstrings** window, at the top beside the title. What it writes
*is* a hotstring in one of the message files — the very files that window indexes, searches,
overloads and deletes — so "add one" now sits beside all of that instead of on the row you
reach across mid-send. The "grab selection → Add Hotkey" hotkey is unchanged, and so is the
window itself, New Script and all. (Hotstrings is a separate process and the dialog is built out of the main
window's own state, so the button asks the main window to open it. If MMA is not running, it
says so rather than opening a dialog that could not save anywhere.)

**New Script** is at the bottom of the **Add Hotkey** window. The only reason to make an
account file is to have somewhere for a hotkey to go, and Add Hotkey is where you choose that
somewhere — so the new file now drops straight into that window's File dropdown and is
selected. That also retires the prompt it used to end on: *"Reload to show toggle button?"*,
which reloaded MMA for the sake of a button that no longer exists.

**The `◻ NAME` script toggles are gone, and so are the "Visible scripts" checkboxes in
Settings that decided which of them appeared.** Their one honest use — a message script stops
responding, you click it off and on again — is now **Hotstrings → Startup scripts**, and it
does that job properly for the first time:

* **It reads the state instead of remembering it**, on a one-second timer. The old button's
  *label* was the state, and the label only changed when you clicked it — so a script that
  died on its own, or was restarted by the watchdog, or by Add Hotkey appending to it, left
  the button reading the exact opposite of the truth. The one moment you go looking is the one
  moment it lied.
* **Restart is one press**, not off-then-on-and-hope-the-label-was-right.
* It shows **which scripts Settings auto-starts**, read-only, so the live view and the config
  cannot disagree. Settings → Scripts still owns "Run on startup" and the watchdog.

It lives under Hotstrings because these files *are* the hotstring library: the manager lists
what is inside them, this lists whether they are running.

The `HiddenScripts` cfg key is left on disk unread rather than deleted, so nothing is lost by
going back to 2.0.2.

### **Pinger: ON** is now **Tools**, and it covers all five background tools instead of one

MMA runs five background tools: the unread pinger, the stats overlay, the Infloww model
detector, the Fansly rail detector and the automation listener. One of them had a button on
the main window — because it was the one people asked about — and the other four were a
window, a tab, a checkbox and a **Save** away in Settings. That is a lot of clicks for
something you switch on and off several times a shift.

**Tools** opens a window with a row per tool: what it is, whether it is running *right now*,
and an **On** / **Off** that greys out on the side it is already on.

* **The state is read, not remembered.** The pinger and the listener answer through the named
  events they hold; the three AHK tools through their hidden windows. Same fix as the script
  toggles above — `Pinger: ON` was a *label*, refreshed on a timer that only ran while the
  main window was up.
* **Three states, not two.** *running*, *off*, and **on, not up** — which is what a missing
  Python or a crashed detector looks like, and what a plain on/off paints over.
* **On and Off write the same cfg keys the Features tab writes**, so this is the same
  statement as the checkbox over there rather than a temporary override of it. Open Settings
  afterwards and the box agrees. It also has to work that way in both directions: `Launch*`
  gates on the key, so launching without writing it first does nothing at all — and the
  watchdog restarts anything whose key is on, so an "off" that skipped the write would come
  back by itself within five seconds.
* **The button counts.** `Tools (2)` means two of the five are up. That is what is left of the
  old label, except it is read on the watchdog's tick and covers everything.

Easy mode still switches every tool off, and the window says so out loud rather than letting
the buttons look broken.


### `__mm` asks which model, and the numbered triggers stop at twelve instead of three

**`__mm1` / `__mm2` / `__mm3` are now `__1mm` / `__2mm` / … / `__12mm`.** The old names
are gone, not deprecated — typing `__mm1` now expands `__mm` on the second `m` and leaves
a stray `1` behind, so this is a retrain, and it is the point of the change. `__mm` is
declared `:*X:`, which fires the instant the trigger is typed with no ending character, so
while `__mm` was live the `1` in `__mm1` was never reached. The two could only ever be
mutually exclusive, and `UniversalSendActive` / `NumberedSendActive` existed solely to
arrange that: bare `__mm` was live exactly when the numbered form was dead.

Putting the digit in front dissolves it. `__1mm` shares no prefix with `__mm`, so both are
live at once with nothing gating either. It also does not run out at nine — `__mm11` could
never have fired, `__11mm` is just another trigger — which is what lets these follow
`ModelCount` all the way to twelve. They are registered by a loop rather than written out,
because a hand-kept list of three is precisely what went stale when 2.0.2 made the count a
setting.

The loop sits at the **top** of `mass/runtime.ahk`, far from the trigger it belongs beside.
Top-level code stops running at the first hotstring definition in the script, and `__mm` is
one; written next to it, the loop would parse cleanly, read correctly in a diff, and never
execute — the numbered triggers would simply not exist, with nothing in the log to say so.

**Bare `__mm` now asks.** One model configured, it pastes that model's live mass exactly as
before. Two or more, it opens the "I pick" window — generalised from a follow-up group to a
`"mass"` group — with **the first line of each model's mass printed on the button that will
paste it**. Previously `__mm` resolved through the detector, which meant that away from it,
finding out which mass you were about to paste meant going back to Discord to read it.

The preview is also the only place in MMA that shows an **empty** mass slot *before* you
paste it. "`__mm` does nothing" is almost always a live `massNo` pointing at a slot nobody
filled in; that slot now reads `(empty)` on its button instead of failing into the log
after the keypress.

`__mm` is **ungated** now. It used to sit behind `UniversalSendActive()`, which meant it
went dead in exactly the situation it is most wanted in: several models, no detector, no
way to be sure which one you were on. A window can answer that question; a silent no-op
could not.

Picking a model for `__mm` aims that one paste and **nothing else** — unlike the follow-up
pick, it does not call `SetManualModel`. Choosing a model for a follow-up is a statement
about which model you are working on, and the shared `[mass.active]` keys should follow it.
Choosing one to paste a mass is not, and making it stick would be a mode change wearing a
convenience's clothes.

### The shared PPV keys ask too, and F4/F5 are now shared

The picker was follow-ups only. The shared PPV keys had the follow-up keys' exact
failure shape — in "I pick" mode they send, confidently, to a model nothing on screen
names — and a PPV goes out with a price attached to a specific account. `ppv` and
`ppvFus` now open the same window, with the PPV base (or the first PPV follow-up, and
how many follow it) previewed on each button.

Behind **its own** Features switch, `Ask which model on the shared PPV keys`, not the
follow-up picker's. The follow-up keys fire constantly and the window is a rhythm you
either want or do not; the PPV keys fire a handful of times a shift, so wanting the ask
on one and not the other is a reasonable position. Like the follow-up ask, it only bites
in "I pick" mode — with a detector resolving the model there is nothing to ask.

A PPV pick **sticks** (it calls `SetManualModel`), with the follow-ups rather than with
`__mm`. A PPV opens an exchange the follow-ups then continue; answering "model 3" for the
PPV and having the next fu1 go elsewhere would be the wrong-fan bug with extra steps.

**F4 and F5 moved from `[mass.1]` to `[mass.active] mPpv` / `mPpvFus`.** They meant model
1 and nothing else; they now follow the active model and ask which one when it cannot be
read. `[mass.1] ppv` / `ppvFus` are left **empty** rather than repointed — a key bound in
two sections registers twice in the one engine process and the later registration
silently wins, so "model 1's PPV on F4" and "the active model's PPV on F4" cannot both be
true. F16/F17 keep working; `mPpv`/`mPpvFus` are the overload slots, and nothing in them
requires the second key to be on a mouse.

Which exposed a bug: **`_MassApplyMouseControl` darkened slots by NAME.** Any slot
starting with `m` was treated as a mouse binding, so turning off "Mouse-button follow-ups"
would have killed F4/F5 — a setting about mouse buttons reaching across to unbind two
function keys, with nothing to connect the two for anyone debugging it. It tests the bound
KEY now (`_IsMouseKey`, modifiers stripped, wheel included), which is what the setting was
always about.

### Notes

Both gate functions are deleted, with a note at their old site in `core/active_model.ahk`
saying where they went; their assertions in `active_model_test.ahk` and `position_test.ahk`
go with them. Nothing replaces those assertions, deliberately: the thing worth testing is
that `__<n>mm` aims model *n* and not the last one, and firing that handler ends in
`DoMass()`, which puts text on the clipboard and presses Ctrl+V into whatever window is in
front. See `docs/decisions.md` §5.2.

## 2.0.2 — 2026-08-01

### N models, not three

`MASS_MODELS := 3` in `mass/store.ahk` was the one number pinning MMA to three
models — everything downstream already looped over it. It follows `[Settings]
ModelCount` now, clamped to `MASS_MODELS_MAX` (12), so adding a model is a setting
rather than a release. Measured: `1→3, 2→3, 5→5, 12→12, 40→12, "abc"→3, absent→3`.

**Lowering the count cannot delete masses.** `MASS_Normalise` looped `MASS_MODELS`,
which was correct while that was a constant. With it following a setting, going from
8 models back to 3 would have dropped models 4-8 on the next normalise and written
that out on the next save — silently, taking every mass in them. It keeps
`Max(MASS_MODELS, whatever the file already holds)`, so lowering the count HIDES
models and raising it brings the text back. Nothing else migrates: the library pads
itself on load, so an existing three-model `masses.json` opens at any count.

The cap is where the GUI stops being usable, not where the data stops working.

Everything that assumed three:

* `ModelNameForSlot` ended `: model3Name` — slot 4 did not fail, it answered with
  **model 3's name**, on every label, dropdown, import prompt and log line. A wrong
  answer that looks right, so the `model1Name/2Name/3Name` triplet is gone rather
  than extended; out of range now says so.
* the load/save buttons were one row at `modelCount = 3 ? 143 : 175`px, which has no
  answer for a fourth model. They wrap three to a row, and everything below shifts
  by the rows added.
* Settings' three "Active models" radios became a dropdown. They were also the only
  way to read the count, via `rdMC1.Value ? 1 : rdMC2.Value ? 2 : 3` — which
  silently answers 3 when nothing is checked. Name/platform rows go two-column past
  six models so the detector section does not fall off the bottom of the window.
* the model tabs, the variants window, `VarRefresh`, and `MMA_ModelNames`.

Models 4+ have no numbered `[mass.N]` hotkeys and no `^!N` select key — `[mass.1]`
to `[mass.3]` already spend F1-F15. They are driven by the shared `[mass.active]`
keys and the picker below, which is what makes N models practical at all.

### New: pick the model, then send — "I pick" mode has a window now

`ModelMatch=manual` reads nothing off the screen: the active model is whatever you
last said it was, remembered in the cfg. For a follow-up key that is the worst shape
of confident — it sends, to a model nothing on screen names, and you find out
afterwards.

In that mode the shared follow-up keys now ask, and the answer sends. With the stock
`[mass.active]` bindings that is XButton2, XButton1 and Ctrl+middle-click. No new
hotkeys and nothing to rebind: this changes what the keys you already have DO in one
mode, which is why there is no `[mass.pick]` section. Name and position modes are
untouched — they know the answer, so asking would be an insult.

Pick by mouse, by Tab and Enter, or by pressing 1-9 (10 is not a hotkey; past nine
it is the mouse or Tab, and the hint line stops promising a key that does not exist).
The number keys are scoped to the picker window — the engine owns a lot of keys and
a global "1" would be a catastrophe. Only follow-ups ask; PPV, `__mm` and
next-follow-up keep the remembered model, because a window in front of every shared
key is a window in front of everything.

Two things it has to get right, both learned the hard way:

* **the window must not open under the cursor.** Centred, the pointer lands inside a
  model button — the window opens with a live Send under the mouse, and the first
  end-to-end test sent a real follow-up into a real conversation off the release of
  the button that opened it. The cursor sits on the header strip now, clear of the
  grid at every model count.
* **focus.** The follow-up is typed, so the window that was in front is saved on open
  and re-activated, with a `WinWaitActive`, before a character is sent.

The picker lays out four to a row rather than one row of N: twelve models in a row is
a 1.8-metre window.

### Masses per model, edited in place

A tab is a MODEL now, and each tab carries its own `mass #` radio row under the last
field. It replaces the `-- Set massNo --` grid in the right-hand panel, which was one
row of radios per model — 408px of them at twelve, off the bottom of the panel and
out of reach.

Picking a slot **loads it in place**, so mass 2 of a model that only has a mass 1
comes up blank instead of leaving mass 1's text sitting there looking like it belongs
to mass 2. Saving writes the boxes into the picked slot and makes it that model's
live slot — otherwise you save into mass 2 and go on sending mass 1, which is the
"the hotkeys are broken" report `SetMassNo` already warns about.

Every model tab is filled from its live slot at startup. With a tab per model,
leaving them blank until you press "load" is a window that lies about your library —
and it made the first slot switch of every session falsely claim unsaved changes,
since empty boxes against a stored mass IS a difference.

### Fixed

- `LoadFile` and `ApplyFile` indexed by mass slot while the tabs became models, so
  loading a model scattered its three masses across the first three MODELS' tabs and
  a save would have written model 2's and 3's text into model 1's masses.
- the all-fields-empty guard scanned every control in the window. With a tab per
  model that calls a blank model "not empty" because another tab has text — defeating
  the check that exists to stop a save blanking a model.
- the import prompt's "Mass #" radios set `tabs.Value`, which is now the model. The
  model comes from the dropdown and the mass # from the radios, as the labels say.
- a fast-parse import filled the tab that was in front and saved the model it had
  matched, which are not necessarily the same one.

## 2.0.1 — 2026-07-30

### New: themes, and a Settings → GUI tab to switch them

Three: **Pink** (default), **Dark**, and **Classic** (what MMA looked like before — system
windows, dark picker).

Pink is `#FEF7F9`, white with a little pink in it rather than a pink window. Kept that pale on
purpose: MMA's windows are mostly **text**, and a real pink behind black text is tiring across a
whole shift. Measured on 2.0.26 — static controls (Text, Checkbox, Radio, GroupBox) follow
`Gui.BackColor` automatically, while Edit, ListView and Button keep system colours, so the light
themes need nothing but the one background.

Dark needs four colours, not one, because nothing inherits a *foreground*: set only the
background and you get black text on a black window. It splits in two, and the split is not
optional:

* **Labels get their colour from the window font, before any control exists** —
  `g.SetFont("s9" THEME_FontOpt(), …)`. Colouring them afterwards does not work, and fails two
  different ways depending on how you try it. A static **on a tab page** that is sent `SetFont`
  loses its inherited background and repaints with the system colour — a pale box behind every
  label on a dark window. Add `+Background` to fix that and the same static comes back
  `#000000`. Measured: an identical label *outside* the tab takes an explicit background
  correctly (`#1E1D26` as asked); on a tab page it is `#000000`. Tab children are painted
  through a different path and will not be told what to do after the fact.
* **Everything else is walked afterwards** by `THEME_ApplyTo()` — the tab control (which paints
  the whole panel), the Edit/ListView/dropdown interiors, and the title bar via
  `DWMWA_USE_IMMERSIVE_DARK_MODE`.

The tab pass runs on **every** theme that sets a colour, not just dark — without it the main
window's tab page was never pink either.

**Buttons and ListView headers stay light**: Windows draws those and ignores a colour unless the
whole control is owner-drawn. That is on the tin in the GUI tab rather than left as a surprise.

`core/theme.ahk` is the single source. It has to be a **name in the cfg**, not a variable —
the main window, Settings and the follow-up picker are three different *processes*, and the cfg
is the only thing they share. Each reads it per use, so switching applies without restarting
anything: the main window repaints immediately, Settings on its next open, the picker on the next
follow-up key. Adding a fourth theme is one edit in that file; the radio buttons are generated
from `THEME_List()`.

The GUI tab also holds the picker's `AltGuiWidth` and `AltGuiLift`, which were ini-only.

Three notes for anyone extending this. A `Tab3` paints its own page interior, and that page
covers everything but an 8px frame — so `sg.BackColor` alone changes a border you cannot see; the
tab control needs its own `Background` option. Setting a control's colour is not the same as
repainting with it: without `Redraw()` the Edit boxes keep the colours they were created with,
the same way the picker's highlight bar did. And **radio buttons group by creation order** — a
group ends at the first control that is not a radio, so adding each radio followed by its
description `Text` made every one a group of one, all three themes could be lit at once, and Save
wrote whichever it found first. The radios go in as one run now, descriptions afterwards, and
`settings_build_test.ahk` asserts that exactly one is checked, because a control census cannot
see this.

`settings_build_test.ahk` grew a `hold [tab] [theme]` mode for looking at the result — the theme
goes through the `MMA_THEME` environment variable, never into your cfg, because a tool that
leaves your settings changed has broken something.

### New: `docs/ahk-gui.html` — the advanced AHK v2 GUI reference

Self-contained page (inline CSS, nothing loaded from the network, light and dark) on the parts
of `Gui` that do something other than put a button on a form: `WS_EX_NOACTIVATE` overlays, the
DPI-scaling trap that silently clips a window's last control, measuring controls before showing
them, restyling in place, hotkeys scoped to one window, and how to build- and screenshot-test a
GUI without a pair of eyes on it. Claims are tagged **measured here** (demonstrated against
2.0.26 on this machine) or **capability** (documented behaviour), because they are not worth the
same. Ends in a symptom → cause trap sheet.

### Fixed: Enter could send EVERY variant instead of the one you picked

The staged preview went **into the chat box**. Enter then cleared the box (`Ctrl+A`, `Delete`),
pasted the marked variant and sent it — and that clear is not reliable. Infloww's composer is a
web editor, and `Ctrl+A` in one of those can be swallowed outright or select the page instead.
When it missed, the preview was still sitting there, the chosen variant was pasted onto the end
of it, and **Enter sent the lot to the fan**: every variant, the markers, the labels, as one
message.

No settling delay fixes that, because it is not a race — it is the composer refusing the
keystroke. So the preview does not go in the chat box any more.

**The variants now show in a small window** above the composer: always on top, `WS_EX_NOACTIVATE`
so it never takes focus off the chat, one band per variant with the marked one lit. `TAB` walks
it, **`SHIFT+TAB` walks back** (new — `*Tab` fires on Shift+Tab too, so going backwards needed
its own binding), `Enter` sends, `Esc` cancels. The chat box is never written to and never
cleared, so the variants **cannot** be sent: they were never in the thing that sends.

Two consequences worth knowing:

* Anything you had typed in the composer stays. It is yours, and Escape no longer wipes it
  either. A chosen variant lands after it — visible while you pick, since the window sits above
  the composer rather than on it.
* The picker cannot outlive the chat. `Tab`/`Enter`/`Esc` are scoped to the window staging began
  in, which left a hole: switch away and **Escape stopped reaching the picker**, leaving an
  always-on-top window with no title bar and no key that worked until the 45-second timeout.
  A watchdog now closes it if that window is gone, and hides it while you are in another app —
  come back and it is where you left it, marker and all.

**Settings → Sending → "Don't use a GUI for alt FUs"** puts the preview back in the chat box, bug
and all. It is the way out if the window misbehaves on your setup, not a preference. Read per
keypress, so it applies to the next follow-up key with no restart. Two ini tunables come with it:
`AltGuiWidth` (default 560, "at 100% zoom") and `AltGuiLift` (default 150, how far above the
window's bottom edge it sits). A window that fails to build falls back to the chat box by itself.

`tools/altgui_test.ahk` covers the label/body rendering and the walk, and `… show` puts the
window up against a stand-in chat window so it can be looked at without Infloww.

### Fixed: the alt picker pasted `/` into a composer where `/` is a command

`AltStagePartSep` — the separator between the parts of one staged variant — defaulted to
`  /  `. The staged preview is **pasted into the Infloww composer**, and `/` is Infloww's
command trigger: it opened the slash-command menu over the box, which then swallowed the `Tab`
and `Enter` that the picker runs on. The picker looked frozen, and escaping it could send the
wrong variant.

Now `  |  `. Changing the default was not enough on its own — `AltStageSetting` *seeds* the cfg
the first time it reads a key, so every machine where a choice had ever been staged already had
`AltStagePartSep=\s\s/\s\s` on disk, and a stored value always beats the fallback. So there is a
one-time migration that rewrites **only the untouched original**; a separator you set yourself is
left exactly as it is, slash or not.

### "How to Use" is a real guide now

**`docs/guide.html`** — one self-contained page (CSS inline, nothing to install, nothing loaded
from the network), opened in the default browser by the main window's **How to Use** button.
Light and dark, with a sticky contents sidebar and **real screenshots** in `docs/img/`.

Written for somebody who has been chatting for months and needs to know where things are in
*this tool*, not what a follow-up is: the window control by control, a full key reference, the
paste format as reference rather than tutorial, the two footguns that eat afternoons
(`massNo` pointing at an empty slot, and load/save moving all three tabs at once), the three
ways MMA decides which model is on screen and why "I pick" exists, Tab-staging, the six
Settings tabs, the logging switches, and a symptom → cause table.

Screenshots are captured from the running app with the message fields pixelated — the copy in
them is live working text, not sample data.

That button previously dumped `docs/mass-format.md` into a read-only, non-wrapping Edit control
in a 600×480 window — and because nobody could stand to read it, nobody noticed the content had
gone stale: it still told you to open `1_mass.ahk` and `2_mass.ahk` to change your hotkeys, and
neither file has existed since the v2 tree. It also documented the follow-up part suffixes as
`.1` and `.2`, when the parser has only ever accepted **`.5` and `.7`** — so anyone following it
had parts silently dropped.

`docs/mass-format.md` survives as the markdown format reference, rewritten against what
`parser.ahk` actually does.

### Logging — every process, one file, and a switch that turns failures into dialogs

MMA is up to eight processes talking through ini files and `PostMessage`, and none of
that produces a stack trace when it goes wrong. It produces **nothing** — which is the
actual bug report this answers: *"it silently failed to do something on my friend's
machine."*

- **`src/core/log.ahk`**, included at the end of `paths.ahk` — the one file every entry
  point already includes. Every process now gets a `BOOT` line, an `EXIT` line (with the
  reason, so a `ProcessClose` from the watchdog is visible) and an `OnError` hook that
  records the **stack**, with no per-script wiring and no way to drift out of step.
- **A `BAIL` level**, which is the point of the exercise. `INFO`/`WARN`/`FAIL` were never
  the problem; the problem is the branch that returned early on purpose — feature off,
  key unbound, mass slot empty, window not in front. All correct, all invisible, all
  indistinguishable from a broken app. Roughly 200 of those now say which one they were.
- **Settings ▸ Debug** grew the three switches, and is their sole writer:
  *Write a log file* (default **on**), *Report errors with a pop-up*, *Max logging*.
  Written on click, not on Save — they are read by eight processes, all of which re-read
  the cfg on a 1.5s timer, so a click is live everywhere with no restart.
- **Pop-ups carry the last 20 log lines**, so a user on another machine can screenshot
  the context instead of finding, opening and sending a file. Budgeted — same message
  once per process, 15 per process, 60s timeout — so a failure inside a 500ms timer
  cannot become a machine you have to reboot.
- **`MMA_DEBUG=max|popups|off`** in the environment overrides all three, for the machine
  you cannot open Settings on. When set, the checkboxes disable themselves and say why.
- **Diagnostic report** button: one file to hand over — environment, both config files in
  full, and the last 400 log lines. Masses and message text are deliberately excluded.
- `error_log.txt` is now failures only (short enough to read top to bottom);
  `mma.log` is the full timeline and rotates at 8 MB.

Instrumented throughout: the hotkey registry (every bind, every refusal, every
anti-fumble drop and by how many milliseconds), the feature gate, every child process
launch and the watchdog, model resolution, the whole send path, the mass library,
next-follow-up, the Discord import, the detector's OCR, and the updater.

Every `ClipWait` on the send path is now a `FAIL` rather than an ignored return value —
a clipboard that does not take the text means Ctrl+V pastes **the previous clipboard**
into a real fan's chat and presses Enter, which was previously undetectable.

### The Discord Ctrl+click import has no switch left to lose

It has been reported broken four times, and the cause has never once been the import's own
code. Every time it was a switch somebody could turn off: the `StartupScripts` checkbox
(whose default list does not include it, so fresh installs never had it), the same box
unticked by a Settings save, and — after those were fixed — the **Features tab**, plus
**Easy mode**, which switches off every feature in the registry in one radio button and took
the import down with them, silently and with no box to look at.

So `sequences` is no longer a feature. It is gone from the registry in `core/modes.ahk`,
which is what makes it always-on: `FEAT()` answers true for any id it does not know, in Easy
mode as much as Advanced. Its hotkeys lost their `FEAT_HOTKEY_MAP` entry, so `HK_Bind`
registers them whatever the mode, and `LaunchSequences()` lost its gate. It is core now,
exactly like the mass engine — a script that owns hotkeys should not be a checkbox.

`sequences.ahk` and the engine also **start first** rather than last. Both used to be
launched at the bottom of `main_window.ahk`, after three tabs, the variants window and the
settings tabs had been built — 280–390 ms in which MMA is on screen with every hotkey it owns
dead, which is exactly when you would reach for one. Measured after the move: engine at
**38 ms**, `seq.copyDiscordMsg` bound and live at **223 ms**.

### Fixed

- `Clear logs` swept `*.txt` only, so it would have left `mma.log` — the one file that
  actually grows — behind.
- `MMA.ahk` had a stray word pasted after `ExitApp`, which is a **load-time** syntax error:
  the launcher — the one thing you double-click — put up an error dialog and started nothing.

## 2.0.0-alpha — 2026-07-27

First 2.0.0 pre-release. A clean break: no migration shims, no compatibility aliases.

### The tree

Seven roles that were all peers in the repo root are now `src/ content/ userdata/
assets/ tools/ docs/`. Every path resolves from **one anchor** (`src/core/paths.ahk`,
via `A_LineFile`), replacing 37 uses of `A_ScriptDir` that only worked while every entry
point sat in the root — and that fail *silently* from a subfolder, because `IniRead` with
a default just returns the default.

### One mass engine, and the data left the code

`1_mass.ahk` / `2_mass.ahk` / `3_mass.ahk` were three processes holding three copies of
the same behaviour around three blocks of data. The data is now `userdata/masses.json`
(`src/mass/store.ahk`); the behaviour was already shared. What was left was three
processes fighting over the same hotkeys, which took **five** separate arbitration
mechanisms — a 350ms timer per process, an in-handler re-check, a shared-id list, and a
conflict-report exemption to stop the GUI flagging three copies of one key. One process
needs none of them. All five are gone.

Migration was verified field by field before the old files were deleted.

### Sending

- **The mouse buttons stopped belonging to model 1.** `mFu1`-`mFu3` were declared under
  `[mass.1]`, so pressing XButton1 in front of model 2 sent *model 1's* follow-up to
  model 2's fan. There is one XButton1 and it is under your thumb whichever tab is open;
  shared keys live in `[mass.active]`, resolved at fire time.
- `[mass.active]` now covers the whole action set — PPV, branches, alts, the mass body —
  not just follow-ups, on the free Scimitar buttons.
- Per-model keys (`F1`-`F3`, `F9`-`F11`, …) are untouched and never gated. The key you
  press *is* the model selector, whether or not any detector is running.

### Knowing which model is on screen

Three ways, chosen per install, plus a platform flag chosen **per model** so an Infloww
model and a Fansly model can coexist. See docs/decisions.md §5.1.

The detector itself was rebuilt around one measurement: **`PixelGetColor` costs ~30ms a
call on a composited desktop.** Sampling three tab slots took 4632ms; a full band sweep
took 10828ms against a 500ms poll interval. The service was ~20x slower than its own
poll — permanently behind, never once returning a current reading. Every earlier
explanation (wrong colours, wrong tolerance, tab counting) fitted the symptoms and fixed
nothing, because each was tested against data that was seconds stale. One BitBlt into a
memory DIB: 4632ms → 10ms.

With fresh input the rest is arithmetic. Tab positions are fixed, so the lit pill's x
*is* the tab index; which model that tab is comes from Settings, because no pixel carries
that fact.

Throughout, a detector that cannot see now **says so**. "No answer" costs a keypress; a
confident wrong answer costs one model's message in another model's chat.

### Also

- Hotstrings replace seven `acc/ALIW.ahk` functions that were canned messages wearing
  hotkeys (see Unreleased, below).
- `automation.py` resolved its root one folder short, so it read a `hotkeys.ini` that
  was not there — every `[automation]` key was silently dead — and wrote a second,
  tracked `error_log.txt`.
- The updater compared versions by **equality**, so any difference read as "update
  available", including an older remote. It compares order now; a pre-release no longer
  offers to downgrade itself to the last release.

### Known unverified

Detector geometry (`TabOrigin`/`TabPitch`) is measured Infloww at one zoom level.
`tools/detector_probe.ahk` prints what your strip actually contains.

## Unreleased

### Breaking

- **The `[aliw]` and `[temp]` hotkey sections are gone.** Seven messages in
  `acc/ALIW.ahk` were written as *functions* — `AliwIntro()`, `AliwWhatLoved()` and friends —
  each bound to an alt-key through `hotkeys.ini`. A canned message had been turned into a
  named, resident piece of code: invisible to the Hotstrings manager (which indexes
  `:trigger::` blocks, not functions), so it could not be searched, edited or overloaded,
  while every other message in the same file was plain data.

  They are hotstrings now, with the text unchanged:

  | was | now |
  |---|---|
  | `!I` `AliwIntro()` | `..intro` |
  | `!e` `AliwLoved()` | `..loved` |
  | `!F1` `AliwGlimpse()` | `..glimpse` |
  | `!L` `AliwWhatLoved()` | `..whatloved` |
  | `!F2` `AliwAscend()` | `..ascend` |
  | `!9` `AliwOpenThat()` | `..openthat` |
  | `!8` `AliwInfiniteLust()` | `..infinitelust` |

  (`..openthat`, not `_OPENTHAT` — `general.ahk` already owns that trigger, with a different
  message.) All seven now show up in the Hotstrings manager; the library went from 103
  indexed messages to 110. `temp.fantasy` went with them: it was declared in `hotkeys.ahk`
  and offered in the Hotkeys window, but `acc/TEMP.ahk` never bound it, so the key did
  nothing.

  `acc/TEMP.ahk` had the same thing spelled a third way: a bare `!1::` written straight into
  the file. Not data, and not declared in `hotkeys.ini` either — the one shape that escapes
  both. It is `Fu1` now, beside the `Fu2` under it.

  Only keys that **run something** — open a chat, type an amount, drive the mouse — belong
  in `hotkeys.ini`. The message library is at 111 indexed messages, and no trigger is
  shadowed by a shorter one (a `:*:` trigger fires the moment it is typed, so `..fu` would
  make `..fu1` unreachable — checked, none are).

### Bug fixes

- **The Settings window overlapped itself.** Rows were placed with hand-counted offsets
  (`y + 126`, `_sy + 102`), which held only while every label happened to fit on one line.
  Two of them had outgrown their width, wrapped onto a second line, and printed over the row
  beneath them and over the button strip. Rows are placed with a running cursor now, so a row
  that needs more height simply takes it. The per-script checkbox rows also wrap at the window
  width instead of marching off the edge once you have six acc scripts, and the status lights
  have their own column that the labels stop short of.

- **The Hotkeys window cut its buttons in half.** Two sets of hand-counted offsets that
  had to agree and didn't: the static layout put the button row at `LV_H+48` with the status
  line 38px below it, while `OnSize` put the buttons at `h-40` and the status at `h-22` —
  *inside* the button row. A Text control paints its background, so the status line erased
  the bottom 12px of all seven buttons. It looked right only until the first `WM_SIZE`, which
  arrives the moment the window is shown, so nobody ever saw the correct version. Laid out
  from the floor upwards in one place now.

  Two more in the same window: `AutoHdr` on all five columns overflowed the list and left a
  horizontal scrollbar hiding the Conflict column — four columns are fixed and Conflict takes
  the remainder, so widening the window widens the one column with variable-length text. And
  there was no `MinSize`, while the left button group ends at x548 and Save/Close are placed
  from the right edge, so under ~780px wide they walked into each other.

- **Resizing.** Three separate faults:
  - ~60 controls moved on every `WM_SIZE` with no redraw batching, so dragging an edge tore
    the window. Drawing is suppressed for the batch and the window repaints once.
  - The bottom button strip was positioned at fixed x, up to `TAB_X+745`. On any window
    narrower than ~1300px, "Alt FUs…" and "Branches…" slid underneath the paste panel. The
    strip now reflows: laid left to right, wrapped to the left panel's current width, and
    hidden controls are skipped so a switched-off feature closes the gap rather than leaving
    a hole.
  - The 66/34 split gave the right panel a couple of hundred pixels on a narrow window, for a
    column of 460px-wide rows — "Export !mma" and "Load from archive" ran off the edge. The
    split is now proportional only until a side would be squeezed below what its controls
    measure. `MinSize` was 750x500, which was wishful; it is 900x640, derived from those
    measurements.
  - The paste box kept a flat 52% of the height, pushing the massNo radios past the bottom
    edge on anything under ~650px tall. It is capped to what is left above the button stack.

### Removed

- **Report Bug.** The button opened a pre-filled GitHub issue.

## 1.9.2 — 2026-07-26

### Bug fixes

- **Hotkey capture ended on the modifier** — the Hotkeys window set every key as an
  InputHook end key (`KeyOpt("{All}", "E")`), modifiers included. Pressing Ctrl therefore
  finished the capture immediately with `EndKey = "LControl"`, while `Mods()` also saw Ctrl
  held — recording the chord as `^LControl`. The only way to enter a real chord was to hit
  both keys in the same instant, so it usually took several attempts.

  The eight modifier keys are now excluded from the end-key set, giving the behaviour every
  other application has: hold the modifiers and the capture waits for an actual key. The
  overlay also shows the chord as it builds ("Ctrl+Alt+…"), so holding a modifier visibly
  does something.

  The held modifiers are now read in `InputHook.OnEnd`, at the instant the end key arrives,
  rather than after the capture loop exits — releasing Ctrl a few milliseconds after F1 used
  to record plain `F1`.

## 1.9.1 — 2026-07-26

### Features

- **Easy vs Advanced mode** — Easy is MMA as it stood at **v1.4.0**, the last version
  before britishizer and the feature run after it: paste, Parse, Clear, Export, per-file
  load/save/massNo, the model tabs, the script toggles, and a Settings window with model
  count, Add Hotkey, How to Use, New Script, Wipe Temp, Report Bug and Check Update.
  Nothing else. For scale: v1.4.0 was 2,167 lines across 10 files; today is 11,599 across 33.

  Easy switches the extras **off**, it does not hide them. A hidden feature still
  interferes — the model detector quietly gating a model's send keys off (see below) is
  exactly the surprise this removes. In Easy, 52 hotkeys register; in Advanced, 92.

  Alt follow-ups, `--Name` branches, the archive, the hotstrings manager, the actions and
  quick-action menus, the recorder, the capitalizer, sequences/Discord import, editable
  follow-ups, open-in-new-tab, double-MM, the stats overlay, the model detector, the
  automation listener and the pinger are all Advanced-only.

- **A toggle for every optional feature** — new `modes.ahk` registry: one `FEAT_Def` line
  per feature carries its cfg key, label and default. Each can be switched off
  individually inside Advanced, and Easy switches all of them off **without touching those
  choices** — flip back and every checkbox is where you left it. Existing cfg keys are
  reused verbatim, so upgrading loses no settings. Settings gains a **Mode…** button;
  that window is generated from the registry, so new features appear in it automatically.

  Mode defaults to **Advanced** — an existing install has a workflow built on these
  features, and demoting it on upgrade would look like MMA had lost half of itself.

- **`install.bat`** — installs AutoHotkey v2 via winget (with `--no-upgrade`, so an
  existing install is never silently moved), optionally installs Python plus `numpy`,
  `pillow` and `opencv-python`, and creates the desktop shortcut. Detection asks the tools
  themselves rather than `winget list`, which only knows what winget installed.

### Bug fixes

- **The model detector read whatever was on screen** — `WinMatch` defaulted to empty,
  which disabled the foreground check entirely. The scan looks at a fixed screen
  *rectangle*, not a window, so it published other applications' titles as the active
  model. Because `ModelIsActive()` auto-claims the first unnamed `[ActiveMap]` slot, a
  junk reading could be captured permanently, after which that model's name never matched
  and **every one of its send keys was held off** — with nothing wrong in the model file
  or the hotkey registry. Now defaults to `Infloww Messages`, the same window
  `automation.py` gates on. Existing installs must also clear the poisoned `[ActiveMap]`
  entry; a code default cannot reach it.

- **MMA now runs cleanly with no Python** — only two optional features need it, but
  `AutomationListener` defaults on and its launcher ended in an unguarded `shell.Run`, so
  a machine without Python got a WScript error dialog on **every startup**. Both launcher
  `.vbs` files now resolve a real interpreter and exit quietly when there is none, and
  `PythonAvailable()` stops MMA spawning them at all. Switching a Python feature on by
  hand now explains itself instead of appearing to do nothing.

- **Python launchers picked the Microsoft Store stub** — `where` lists the zero-byte
  WindowsApps App Execution Alias *before* the real interpreter, so reading one line either
  opened the Store or wrongly concluded there was no Python. Both files now scan every
  match and take the first with a non-zero size. This also fixes a **duplicate automation
  listener**: one started through the stub could not see the real one's single-instance
  mutex across the Store's virtualised namespace, so `^!u` unsent twice.

## 1.9.0 — 2026-07-26

Structural release. No new features; the point is that a model file is now data,
the shared behaviour has one definition, and the Python listener is in the repo.

### Bug fixes

- **Settings did nothing for models 2 and 3** — `EditableFu1/2/3`, `WalletCheckFu3`,
  `OpenTabFu2/3` and `OpenTabPpv` existed only in `1_mass.ahk`. The Settings window
  broadcast every toggle to all three model scripts (`_BroadcastEditableFu`), but 2 and 3
  had no handler and passed a hard-coded `false` instead, so the checkboxes moved and
  nothing happened. All models now share one implementation and honour all of them.
  **If `OpenTabFu2` is on, models 2 and 3 will start opening a new tab after follow-up 2 —
  that is the fix, not a regression.**
- **Ctrl+follow-up was ungated on models 2 and 3** — their `DoAltFu*` skipped the
  `FuGate()` check that model 1 ran, so the key could fire while another model was active.
- **Regenerating a model file deleted its branches** — `BuildMassTemplate` emitted its own
  copy of `DoFu1/2/3` and `DoPpv` but never the alt or branch functions, so rebuilding a
  model silently dropped `--Name` branch support and the Settings-aware follow-ups. It now
  emits data plus one `MassInit()` call, identical in shape to a hand-written model file.
- **PPV pasted a stale clipboard** — `DoPpv` with an empty `ppv_base` cleared the clipboard,
  timed out on `ClipWait`, then pasted whatever was there before. It now returns early.

### Internal

- **`automation.py` is in version control** — the 1,705-line listener that serves the
  `[automation]` hotkeys lived in the gitignored `infloww ui elements/` folder, so a fresh
  clone produced a silently half-working install. Moved to `automation/` and tracked, with
  its launcher and UI map. Only the screenshots and detector prototypes stay ignored.
- **New `mass_runtime.ahk`** — every model's behaviour, once. `1_mass.ahk` 481→225 lines,
  `2_mass.ahk` 336→170, `3_mass.ahk` 331→170; message content untouched.
- **`mass_gui.ahk` split 2,971→1,757 lines** — `archive.ahk` (the archive file format, its
  readers and its window), `mass_parser.ahk` (the mass text format and its escaping) and
  `processes.ahk` (launching, stopping and watching the five child processes).

## 2026-07-20

### Features

- **Delete in the Mass Archive** — New **Delete** button in the archive viewer (`OpenArchive`, `mass_gui.ahk`). Confirms with the timestamp, model and message text first, then rewrites `mass_archive.txt` without that entry via a temp-file swap. The rewrite re-reads the file rather than dumping the viewer's in-memory list, so masses archived while the window sat open are not silently lost. Selection keeps its place across a delete instead of jumping back to the top.

- **Delete in the Hotstrings manager** — New **Delete** button in `hotstrings_gui.ahk`, backed by `HSI_DeleteBlock` in `hotstring_index.ahk`. This is the **only** path in MMA that writes to a message `.ahk` file, so it: re-derives the block's line span from the file (never trusts the index snapshot), refuses if the trigger on that line no longer matches, copies the file to `<name>.ahk.bak` first, and preserves the file's existing BOM and line endings. Also drops the trigger's overload entry — left behind, it would keep firing for a hotstring whose source is gone. The owning script must be restarted for the deletion to take effect.

- **Larger text in both windows** — Archive viewer and Hotstrings manager bumped roughly one step throughout (titles 14→15, search 11→12, lists 10→11, buttons 9→10), with control heights and resize math adjusted to match. The Hotstrings manager's own "Text size" control still governs the showcase pane independently.

- **Louder pinger alert** — `pinger.pyw` no longer uses the `SystemExclamation` alias, which plays at the Windows *System Sounds* mixer level (separate from master volume, easy to leave low, and unreachable from the script). It now synthesises a two-tone 880/1320 Hz square-wave beep at full scale and plays it on its own channel, tunable via `ALERT_VOLUME` / `ALERT_TONES` / `ALERT_BEEP_MS`. New `--test-sound` flag plays it once for tuning.

## 2026-06-22

### Features

- **ACC script visibility** — Settings now has a "Visible scripts" row with a checkbox per `/acc` file. Unchecked scripts are hidden from the main GUI toggle bar. Hidden list stored as `HiddenScripts` in `[Settings]` cfg.

- **Double MM moved to Settings** — Removed from the main toggle bar. Now a live-toggle checkbox in the Settings window (same instant WM-message behavior as before). MButton hotkey still works.

- **Wallet check FU3** — New Settings toggle. When on, F3/Ctrl+MButton pastes the combined fu3+fu3_5+fu3_7 as one clipboard paste **without sending Enter**, so the text lands in the input box for review/edit before manual send. Live-toggled via WM message (0x8002) — no reload needed.

- **Editable FU toggles (F1/F2/F3)** — New "Ed" header row above the FuSingle M×F grid. Each checkbox makes that FU paste its combined parts without Enter, same logic as wallet check. Live-toggled via WM messages 0x8003–0x8005. Shared `SndFuEditable()` helper in `1_mass.ahk`.

- **Alt+0 custom-timing send** — Checkbox + numeric ms field added to the right panel ("Apply to file" row). When enabled, Alt+0 pastes the current clipboard and presses Enter, sleeping the exact ms typed in the field instead of the global `waitTime`.

### Bug fixes

- **PPV escape char insertion** — Refactored edCtrls to always store **raw** (unescaped) values. EscQ is now applied once, only in `BuildBlock`, when writing to the `.ahk` file. Previously, PPV fields typed directly into the GUI were written without escaping `"`, `` ` ``, and `;`, producing broken AHK syntax. `LoadFile` now applies `UnescQ` when reading back escaped strings from file so edCtrls stays raw.
