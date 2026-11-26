# lore_gatherer: decisions so far

Grilling session 2026-11-20. **No code until every open question below is answered**
(Silly's standing rule). Source of the feature: `# answer to The MMA — Unfinished Work Re.md`.

## Decided

| # | Question | Answer |
|---|---|---|
| 1 | Which window scrolls and reads? | The window it was started from. In practice a separate 2nd or 3rd Infloww window, never the one Silly chats in. |
| 2 | What does one run cover? | The core does **one fan**. Lists come from automation on top: e.g. 10 tabs open, Ctrl+W each finished tab, then restart. 2–4 fans at once is fine; RAM is the only limit. |
| 3 | When does it stop scrolling up? | Several strategies, picked per run. Default: **the AI decides it has enough**. |
| 4 | A fan harvested before? | Read the new messages, join at the newest saved one, then optionally keep going past the oldest saved one. Saved text is never thrown away. |
| 5 | What is captured per message? | **Everything.** It is one system: one recorder saves all messages into a fan file, and the summaries are made from that file. |
| 6 | Old shiftlog / typelog / OBS data? | Start fresh. Old data stays as training material and never enters fan files. |
| 7 | Fan identity | Key on the `@handle`. It shows in the all-chats list (often cut off) and on the open fan. The only fully reliable read is to **click the name and read the handle from the modal**. Do that for any fan it doesn't recognise. A fan with a nickname is someone important. |
| 8 | Input use in the harvesting window | Brief real input is OK: it may take the mouse or focus for under a second (e.g. to click the name), then put everything back. |
| 9 | Definition of done for the core | 3 real fans (short, medium, long baller). Silly checks each saved file in the viewer against Infloww: nothing missing, doubled or out of order, with PPVs and times correct. |
| 10 | First build scope (2026-11-24) | **Both together:** the harvester (dedicated window) and the live recorder (work window) write the same fan files from day one. |
| 11 | Live recorder, unknown fan | **Ask Silly:** a small prompt shows the guessed fan, and one key confirms or corrects it. The live recorder never clicks in the work window. |
| 12 | "Tabs" | A fan chat tab inside one Infloww window (Ctrl+W closes it). Running 2–4 fans at once therefore means 2–4 windows. |
| 13 | Stop rules (picked per run) | Default: the AI says enough. Also: whole chat, back to a date, last N messages, last N **spending events**. |
| 14 | Spending event | Purchases with no gap longer than **6 hours** between them count as one event. |
| 15 | AI clash on the GPU | **Harvest wins.** A deep run takes the GPU; Silly won't use AI tools meanwhile. |
| 16 | What OCR can't read | A typed placeholder (`[photo]`, `[voice 0:32]`, `[gif]`) **plus an image crop** of the bubble. |
| 17 | Times | Every bubble's footer has the time (`transcript.py` `_TIME` also accepts `Today` / `Yesterday` / `Nov 3[, 2025]`). The live capture shows the **date on separator lines** between days ("Nov 20"), so the date comes from the last separator above a message. Every message gets a real timestamp. |
| 18 | Media storage | D: drive, compressed JPEG crops, **no cap**. |
| 19 | Fan files + viewer | One folder per fan, e.g. `D:\FanData\<account>\<@handle>\`. Viewed in **Shift Viewer, reworked** onto fan files (inflowwclone renderer, crops inline). |
| 20 | Notes | Copied every harvest (Ctrl+A/C only), **latest copy kept**. The live recorder never touches Notes (no clicks in the work window). |
| 21 | Failures | **Stop clean, resume later:** save what was captured plus a "reached up to here" mark, log why. Auto-restarting Infloww is a later assistant script. |
| 22 | During a shift | **Quick, bounded lookups only** (one fan, a minute or two). Long and whole-chat harvests are off-shift only. |
| 23 | Quick lookup AI | Mechanical stop rule (no AI mid-scroll), then **one summary call** at the end, which may briefly take the GPU. |
| 24 | Starting a run | **Hotkey + small picker** in the harvesting window with the fan open. Last-used rule preselected, Enter starts. |
| 25 | Old chatreader / shiftlog | **Replaced.** Side jobs (unread ping, purchase sound, Live Trainer, suggestions input) keep working on the new recorder's reads. |
| 26 | What a finished run shows | A **fan card** (tier + spend, one-line notes summary, what happened recently, 2–3 reach-out ideas) with a button that opens the full chat in Shift Viewer. |

## Live recorder (decided 2026-11-24)

| # | Question | Answer |
|---|---|---|
| 27 | Build order | **Live recorder first,** then the harvester. |
| 28 | When the unknown-fan prompt appears | **Instantly, non-blocking:** a corner toast that never takes focus; ignored ones go to a pending pile. |
| 29 | Partial handle (`@u813…`) + name match exactly one known fan | **File it, no toast.** Toast only for a fan with no file yet, or two matches. |
| 30 | Brand-new fan, handle cut off | The toast **reminds Silly to click the name**. The recorder reads the modal Silly opens and files the fan properly. No provisional files. |
| 31 | Source of Silly's own messages | **Screen only.** Typelog stays separate (autoword). |
| 32 | Fan insights panel | **Ignored live;** only harvests read it. |
| 33 | Done, so chatreader/shiftlog retire | **One shift beside the old recorder,** then 5 fans spot-checked in the viewer (nothing missing, doubled or misfiled), and the unread ping and purchase sound still fire. |

Nothing to answer from Silly: the live recorder reuses the background capture (PrintWindow, no input), reads on screen change as chatreader does, and needs the same stitching as the harvester (Silly scrolls up while working).

## Build status: live recorder (2026-11-24)

All six steps are built and pass their offline checks against the reference captures in `tools/ui-research/` (`work_window_list.png`, `name_modal.png`, `harvest_scrolled.png`). **Not yet run on a live shift.**

| Step | Where | Check |
|---|---|---|
| 1 Identity | `src/services/llm/fanid.py`: list-row handle (prefix + edge-truncation), name modal (handle + tags), account heading ("CIN"), day separators | `python fanid.py` (12 checks) |
| 2–3 Fan store + stitching | `src/services/llm/fanstore.py`: `<Root>/<account>/<handle>/{reads.jsonl, fan.json, media/}`, `_pending/`, days filled from separators, crops of both sides; alignment imported from shiftlog | `python fanstore.py` (12 checks) |
| 4 Toast | `src/services/llm/toast.py`: no-focus corner toast, 9 s | shown live: foreground unchanged |
| 5 Wire-in | `fanrec.py` (`Recorder.on_read` / `on_frame`), hooked into `chatreader.pyw` beside shiftlog; FEAT `fanRecorder` (default on) in `modes.ahk` | `python fanrec.py` (8 checks: pending → toast → modal adopts → prefix match) |
| 6 Viewer | `tools/shiftview/shiftview.pyw` + `ui/view.js`: fan files are the default source; a "Source" button switches to the old shift log; panel shows handle, names, tags, notes | API read-back of a recorded fan |

Side fixes: `transcript.capture_conversation` and `unread_ping.grab` now prefer the WORK window (the one with a chat list) when a harvest window is also open. The old shift log turned out to file every chat under account "333", because the title's "333" is a badge count, not the account name.

Next: one real shift beside shiftlog (decision 33), then 5 fans spot-checked in the viewer. Then the harvester.

## Seen on screen (2026-11-24 captures)

- **Fan insights panel** shows Total spend ($2.03k), Last spend (4d ago, PPV $196.75), Highest spend (with date), PPV/Tip totals, Spending power (Top 1%), and Subscription. Read the baller tier straight off it. "Last spend" is a cheap anchor for the spending-events rule.
- **Profile ▸ Nickname** field (e.g. "baby"): the nickname Silly said marks an important fan.
- **"Open in new tab"** in the chat header opens a fan in its own window with no chat list. That is the harvesting window.
- Date separator lines ("Nov 20", "Nov 21") sit between days. Footers carry only the time inside a day.

## The problems to solve (from the decisions above)

Each is separate and testable. Nothing here is built yet.

1. **Background scroll: SOLVED (probe, 2026-11-24).** Yes. `PostMessage WM_MOUSEWHEEL` (delta +360, lParam = a screen point over the pane) sent to the window's **`Chrome_RenderWidgetHostHWND` child** scrolled an unfocused spare window ("Open in new tab" on keefe). It also triggered Infloww's lazy-load spinner at the top, as a real wheel does. The same message sent to the top-level window did nothing. Foreground and cursor stayed untouched. Caveats: the child HWND can come and go (the work window lost it between two listings), so look it up before every scroll; and the spinner means "wait until it's gone" is part of stitching. Probe: scratchpad `bgscroll_probe.py` (throwaway).
2. **Stitching.** Turn overlapping screens into one ordered message list with nothing missing or doubled. Every earlier attempt died here (BallLore, shiftlog `merge()`, `__analyse` "does not line up").
3. **Message parsing.** Side, text, footer time and date, PPV price and paid state, tips, placeholders and crops for anything unreadable.
4. **Fan identity.** Harvest: click the name and read `@handle` from the modal. Live: the one-key confirm prompt.
5. **Fan store.** Folder layout, the resume mark, joining a re-run at the newest saved message, and extending past the oldest.
6. **Stop rules.** AI-enough, whole chat, date, last N messages, last N spending events (6-hour gap).
7. **Live recorder.** Replace chatreader's capture and move its side jobs onto it.
8. **Notes copy.** Ctrl+A/C only, latest kept.
9. **Front end.** Hotkey + picker, fan card, Shift Viewer reading fan files.

**Done** = decision 9: 3 real fans checked by eye.

## Still to settle before code

- Confirm this document is complete (Silly's sign-off).
- The build order of problems 1–9.

## Related open threads (after lore_gatherer)

- **fandata:** what farmolijer's farm log and reminders recorded; how reminders should arrive (Discord, popup).
- **MM Gatherer redo** via Discord `!mm` search: one pass over all channels split by model, or one channel at a time?
- **`.vbs` launchers:** delete them now that the runner works? Waiting on a yes.

## Prototype: the 3-part suite (2026-11-24)

Silly's three asks, as built:

| Part | What | How to use |
|---|---|---|
| 1 Recorder | `fanrec.py` inside the chat reader: every chat you open, both sides, filed by `@handle` in `D:\FanData` | automatic once MMA runs (Features ▸ Fan recorder) |
| 2 Lore gatherer | `lore.pyw` (`__lore`): picker → reads his @handle from the name popup → scrolls UP in the background → keeps every page → LLM card (`prompts/lore.md`) saved as `summary.md` | type `__lore` in a spare "Open in new tab" window with the fan open |
| 3 Database | the fan folders + Shift Viewer: fan list with spend + baller tier, chat, lore card, tags | Tools ▸ Shift Viewer |

**Known limit, measured live:** background scrolling works when Infloww keeps its `Chrome_RenderWidgetHostHWND` child, or when the window is VISIBLE where the chat is (another monitor). Fully covered, with no child, nothing reaches it: not the wheel, keyboard or accessibility requests (all tried). `__lore` says so and stops instead of failing silently.

Added after: the Notes card is OCR'd (panel scrolled in the background, the box never clicked: without __analyse's keyboard guard a click + Ctrl+A could let a stray keystroke into his notes). Still not done: an AHK hotkey (it's the typed `__lore`) and a live end-to-end run.
