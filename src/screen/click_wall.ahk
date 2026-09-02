#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#Include "../core/modes.ahk"
#Include "pill_scan.ahk"
#Include "../core/dpi.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  click_wall.ahk — an invisible wall over the chat list while a send is running.
; ───────────────────────────────────────────────────────────────────────────────
;  A follow-up is not one message. f1 / f1.5 / f1.7 go out as three, with a
;  waitTime pause between each, so a single keypress owns the chat box for a good
;  second or more. Click the next conversation inside that second and the parts
;  still in flight land in the chat you just moved to — the fan you were talking
;  to gets half a follow-up, and a stranger gets the other half.
;
;  Nothing in MMA could stop that. hotkeys.ahk's anti-fumble guards drop a stray
;  HOTKEY mid-send (see _HK_Fire), and every one of them is blind to a mouse
;  click, because a click on the conversation list is not a hotkey — it is the
;  browser doing exactly what it was told.
;
;  So while a send is in flight, this claims the left mouse button over the list.
;  The click is swallowed, its position is REMEMBERED, and the moment the send
;  finishes it is played back at the same point. You click once, nothing appears
;  to happen for a beat, and then the chat opens — no re-click, and no half a
;  follow-up in a stranger's inbox.
;
;  ─── WHY A HOTKEY AND NOT AN ACTUAL WINDOW ───────────────────────────────────
;  "An invisible wall" describes a transparent always-on-top window over the list,
;  and that is the more literal build: clicks land on the window, so there is no
;  hotkey criterion to evaluate and nothing can slip past while the script is
;  busy. It was not built that way because of how it FAILS.
;
;  A window is state that outlives the code that raised it. If the engine dies
;  mid-send — a crash, a reload at the wrong moment, a throw nothing catches — the
;  wall is still up, still invisible, and still eating every click on the
;  conversation list, with no window on screen to explain why and no hotkey left
;  alive to take it down. That is a machine somebody has to reboot to fix, having
;  never once seen the cause.
;
;  A hotkey cannot do that. It belongs to the process; when the process goes, the
;  claim goes with it, and the mouse is a mouse again. The cost is that HotIf has
;  to evaluate at click time and could in principle time out under a wedged
;  script, which loses one wall — the same click that gets through today, every
;  single time. Losing the guard occasionally beats a desk that cannot be clicked.
;
;  ─── WHY IT VERIFIES BEFORE PLAYING THE CLICK BACK ───────────────────────────
;  Infloww sorts the conversation list by most recent message, and the send that
;  is holding your click is what makes a conversation most recent. So the list can
;  REORDER underneath a held click, and a point that meant "Jess, row 4" when you
;  pressed it can mean "Marie, row 4" a second later. Playing that back is the
;  exact failure this file exists to prevent, arriving by the front door.
;
;  So the swallow keeps a small bitmap of what was under the pointer, and the
;  playback re-grabs it and compares. Different pixels mean the rows moved, and a
;  moved row is not clicked — it says so and leaves the click to you. See
;  CW_PatchSame; the sampling helpers are pill_scan.ahk's, unchanged.
;
;  ─── CONFIG ─────────────────────────────────────────────────────────────────
;  [ClickWall] in mass_gui.cfg. Region is the only one that matters, and it has a
;  three-step fallback so a fresh install needs no calibration at all — see
;  CW_Region. Everything else is a tuning number with a working default.
; ═══════════════════════════════════════════════════════════════════════════════

global CW_ARMED := false        ; is the wall up right now?
global CW_HELD  := 0            ; {x, y, at, patch} of the click being held, or 0
; Said once per process, not once per send. Without a Region the wall is inert,
; and a send happens dozens of times an hour — logging that on every one of them
; would bury the log in the one message that is identical every time.
global CW_NO_REGION_SAID := false

; Long enough that no ordinary send reaches it, short enough that a wedged one
; gives the mouse back before you go looking for the problem. The release on
; hotkeys.ahk's send hook is what normally takes the wall down; this is only for
; the case where that never runs.
global CW_WATCHDOG_MS := 8000

; Written out on first run so the whole section is visible and hand-editable, the
; same way reply_box.ahk and stats_overlay.ahk seed theirs. Region is seeded EMPTY
; on purpose and that is not the same statement it is for reply timers: empty here
; means "use the fallback chain", which for an ordinary install resolves to the
; list beside the [NextFu] pane and needs nothing calibrated. Fill it in only to
; overrule that — and write it in the WINDOW's client coordinates, like the reply
; timer region it sits next to, not screen ones. See CW_RegionRaw.
if (IniRead(MMA_CFG, "ClickWall", "HoldMaxMs", "") = "") {
    for k, v in Map("Region","", "WinMatch","Infloww Messages"
                  , "HoldMaxMs","6000", "Verify","1"
                  , "PatchW","140", "PatchH","20"
                  , "PatchTol","28", "PatchMinPct","88")
        try IniWrite(v, MMA_CFG, "ClickWall", k)
    LOGI("clickwall", "seeded [ClickWall] defaults into mass_gui.cfg — Region is"
                    . " empty, which means the wall derives one from [NextFu]:"
                    . " everything left of the conversation pane, over the same"
                    . " rows. Set it only to overrule that.")
}

; WinMatch is a substring criterion — a browser title is "<page> - Google Chrome",
; so the page name is never the whole of it. 2 is already v2's default; stated
; here because the wall silently stops applying if anything ever changes it, and
; "the wall does nothing" is indistinguishable from the feature being off.
SetTitleMatchMode 2

CW_Cfg() {
    return {
        ; Which window the wall applies in. Blank = anywhere, which is almost
        ; certainly not what you want: the region is measured against Infloww and
        ; means nothing in another app.
        win:      Trim(IniRead(MMA_CFG, "ClickWall", "WinMatch", "Infloww Messages")),
        ; Drop a held click that has been waiting longer than this rather than
        ; play it back. A send that took six seconds went wrong somewhere, and a
        ; click from six seconds ago is a click at a list that has moved on.
        holdMax:  LOG_IniInt(MMA_CFG, "ClickWall", "HoldMaxMs",   6000),
        ; The did-the-list-move check. 0 plays every held click back blind.
        verify:   LOG_IniInt(MMA_CFG, "ClickWall", "Verify",         1),
        patchW:   LOG_IniInt(MMA_CFG, "ClickWall", "PatchW",       140),
        patchH:   LOG_IniInt(MMA_CFG, "ClickWall", "PatchH",        20),
        ; Per-channel distance, the same measure PILL_ColorDist returns. Loose
        ; enough to ride out a hover highlight fading out under the pointer,
        ; tight enough that a different fan's row does not pass.
        patchTol: LOG_IniInt(MMA_CFG, "ClickWall", "PatchTol",      28),
        ; Percent of sampled pixels that must still match.
        patchMin: LOG_IniInt(MMA_CFG, "ClickWall", "PatchMinPct",   88)}
}

; Which rectangle to wall, and WHICH COORDINATE SPACE it is written in. Three
; sources, most specific first, so the common install needs no calibration and an
; unusual one can still say exactly what it means:
;
;   [ClickWall] Region   drawn by hand. Wins outright. CLIENT coordinates.
;   [ReplyBox] Region    the conversation list, already measured — it is the
;                        rectangle the reply timers draw their boxes in, and it is
;                        the same list this wall is protecting. If reply timers are
;                        calibrated, the wall is too, for free. CLIENT.
;   [NextFu] Region      derived. The follow-up walker OCRs the CONVERSATION pane,
;                        so its left edge is where the pane starts, which is where
;                        the list ends. Everything left of it, over the same rows,
;                        is the list — no new number to measure and no new thing to
;                        keep in step. SCREEN, because that is what NextFu is.
;
; ─── THE TWO SPACES ARE NOT INTERCHANGEABLE, AND MIXING THEM IS SILENT ────────
; The first version of this file read all three as screen coordinates. Nothing
; would have complained: a client rectangle IS a plausible screen rectangle, so the
; wall would have gone up, held clicks, and played them back — a few hundred pixels
; from where the user was actually clicking, on a list it was not covering. Every
; symptom would have pointed at the feature "not working" rather than at a unit.
;
; They are stored the way they are for a reason on both sides. The calibrated ones
; are client-relative so that moving or maximising Infloww takes them along
; (reply_box.ahk's RB_Region and tab_marks.ahk say the same); [NextFu] is screen
; because OCR.FromRect takes screen coordinates. So the space is carried WITH the
; rectangle here, and CW_Region does the conversion once, at the edge.
CW_RegionRaw() {
    r := CW_ParseRegion(Trim(IniRead(MMA_CFG, "ClickWall", "Region", "")), "ClickWall")
    if r {
        r.client := true, r.src := "ClickWall"
        return r
    }
    r := CW_ParseRegion(Trim(IniRead(MMA_CFG, "ReplyBox", "Region", "")), "ReplyBox")
    if r {
        r.client := true, r.src := "ReplyBox"
        return r
    }
    x := LOG_IniInt(MMA_CFG, "NextFu", "RegionX", 401)
    y := LOG_IniInt(MMA_CFG, "NextFu", "RegionY", 135)
    h := LOG_IniInt(MMA_CFG, "NextFu", "RegionH", 727)
    if (x < 8 || h < 8)
        return 0
    return {x: 0, y: y, w: x, h: h, client: false, src: "NextFu"}
}

; The walled rectangle in SCREEN coordinates, or 0 when there is none.
;
; `win` is what a client-space region is measured against. CW_InZone passes "A",
; the active window, because by then it has already established that the active
; window is an Infloww one — resolving by TITLE there could pick a different
; Infloww window on another monitor and wall a rectangle nobody is looking at.
CW_Region(win := "") {
    r := CW_RegionRaw()
    if !r
        return 0
    if !r.client
        return {x: r.x, y: r.y, w: r.w, h: r.h}
    if (win = "")
        win := CW_Cfg().win
    if (win = "") {
        ; A client rectangle with nothing to be a client OF. Refusing beats
        ; treating it as screen coordinates, which is the silent failure above.
        LOGV("clickwall", "[" r.src "] Region is window-relative but WinMatch is"
                        . " blank — nothing to measure it against, so no wall")
        return 0
    }
    ccx := 0, ccy := 0, ccw := 0, cch := 0
    try WinGetClientPos(&ccx, &ccy, &ccw, &cch, win)
    catch as e {
        LOGV("clickwall", "could not read the client rect of '" win "' — no wall"
                        . " this time (" LOG_Err(e) ")")
        return 0
    }
    if (!ccw || !cch)
        return 0
    return {x: ccx + r.x, y: ccy + r.y, w: r.w, h: r.h}
}

CW_ParseRegion(raw, who) {
    if (raw = "")
        return 0
    p := StrSplit(raw, ",")
    if (p.Length < 4) {
        LOGW("clickwall", "[" who "] Region is not 'x,y,w,h' — ignored (" raw ")")
        return 0
    }
    r := {x: LOG_Int(Trim(p[1]), 0, "[" who "] Region x"),
          y: LOG_Int(Trim(p[2]), 0, "[" who "] Region y"),
          w: LOG_Int(Trim(p[3]), 0, "[" who "] Region w"),
          h: LOG_Int(Trim(p[4]), 0, "[" who "] Region h")}
    return (r.w >= 8 && r.h >= 8) ? r : 0
}

; ── the criterion ─────────────────────────────────────────────────────────────
; The (*) is required rather than stylistic: HotIf calls its criterion with the
; hotkey's own name, and a zero-parameter function is rejected outright with
; "Invalid callback function." Same reason AltStageActive in core\utils.ahk and
; every context in core\hotkeys.ahk are written this way.
;
; The region test lives HERE, not in the handler, and that is what keeps the wall
; from touching anything else. A click outside the list is never a hotkey at all,
; so it reaches the browser untouched, at full speed, and drags and double-clicks
; everywhere else in the app behave exactly as they did — which they could not if
; the handler swallowed every click and tried to play the innocent ones back.
CW_InZone(*) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    global CW_ARMED
    if !CW_ARMED
        return false
    c := CW_Cfg()
    if (c.win != "" && !WinActive(c.win))
        return false
    ; "A", not the title: the line above has already established that the window in
    ; front is an Infloww one, and a client region must be measured against THAT
    ; window. Resolving by title again could pick a second Infloww window on
    ; another monitor and wall a rectangle nobody is looking at.
    r := CW_Region(c.win = "" ? "" : "A")
    if !r
        return false
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    return CW_PointIn(r, mx, my)
}

; Split out of CW_InZone so the boundary arithmetic can be tested without a mouse.
; Top and left inclusive, bottom and right exclusive — the same convention
; PILL_Grab's rectangles use, so a region can be copied between the two and mean
; the same thing.
CW_PointIn(r, x, y) {
    return (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
}

; ── raising and dropping it ───────────────────────────────────────────────────
;  Both are installed on hotkeys.ahk's send hooks by mass\engine.ahk, so the wall
;  goes up on the same edge the anti-fumble guards use — the instant a message key
;  starts running — and comes down in the `finally` that always runs.
CW_Arm(*) {
    global CW_ARMED, CW_HELD, CW_NO_REGION_SAID, CW_WATCHDOG_MS
    if CW_ARMED
        return
    if !FEAT("clickWall")
        return
    ; RegionRaw, not Region: the question here is "is one CONFIGURED", which must
    ; be answerable without a window in front. Whether it resolves to a screen
    ; rectangle right now is CW_InZone's problem, once per click, when there is an
    ; active window to resolve it against.
    if !CW_RegionRaw() {
        if !CW_NO_REGION_SAID {
            CW_NO_REGION_SAID := true
            LOG_Bail("clickwall", "the click wall is on but there is no region to"
                                . " wall — set [ClickWall] Region to 'x,y,w,h' in"
                                . " mass_gui.cfg, or calibrate the reply-timer"
                                . " list, which the wall reuses. Clicks are NOT"
                                . " being held.")
        }
        return
    }
    CW_HELD  := 0
    CW_ARMED := true
    HotIf CW_InZone
    Hotkey "*LButton", CW_Swallow, "On"
    HotIf
    ; Insurance, not the mechanism. CW_Release on the send's `finally` is what
    ; takes the wall down; this only matters if that never runs, and an invisible
    ; wall nobody can lower is the one outcome worth spending a timer on.
    SetTimer(CW_Watchdog, -CW_WATCHDOG_MS)
}

CW_Release(*) {
    global CW_ARMED, CW_HELD
    if !CW_ARMED
        return
    SetTimer(CW_Watchdog, 0)
    HotIf CW_InZone
    Hotkey "*LButton", "Off"
    HotIf
    CW_ARMED := false
    held := CW_HELD
    CW_HELD := 0
    if !held
        return
    CW_Replay(held)
}

CW_Watchdog() {
    global CW_ARMED, CW_HELD, CW_WATCHDOG_MS
    if !CW_ARMED
        return
    ; WARN, and it names the consequence rather than the state: while this was
    ; true the left mouse button did nothing over the conversation list, and the
    ; person at the desk had no way to find out why.
    LOGW("clickwall", "the wall was still up " CW_WATCHDOG_MS "ms after it went"
                    . " up — a send never finished. Dropping it, so the mouse"
                    . " works again; any held click is discarded rather than"
                    . " played back into a list that has had this long to move.")
    CW_HELD := 0
    CW_Release()
}

; ── swallowing ────────────────────────────────────────────────────────────────
CW_Swallow(*) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    global CW_HELD
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    ; The LAST click, not the first. Click one conversation, change your mind and
    ; click another, and the one you meant is the one you ended on — holding the
    ; first would open a chat you had already decided against.
    again := CW_HELD ? true : false
    CW_HELD := {x: mx, y: my, at: A_TickCount, patch: CW_Patch(mx, my)}
    LOGI("clickwall", "held a click at " mx "," my " — a send is still going out."
                    . (again ? " Replaces the click held a moment ago." : "")
                    . " It plays back when the send finishes.")
    CW_Toast("Hold on — still sending.`nThis click goes through in a moment.", mx, my)
}

; ── playing it back ───────────────────────────────────────────────────────────
CW_Replay(held) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    c   := CW_Cfg()
    age := A_TickCount - held.at
    if (c.holdMax > 0 && age > c.holdMax) {
        LOG_Bail("clickwall", "the held click is " age "ms old (limit "
                            . c.holdMax "ms) — that send did not go the way it"
                            . " should have, and the list has had long enough to"
                            . " reorder. Not played back; click again.")
        SoundBeep(300, 200)
        CW_Toast("That send took too long — click again.", held.x, held.y)
        return
    }
    if (c.verify && !CW_PatchSame(held.patch, CW_Patch(held.x, held.y))) {
        LOG_Bail("clickwall", "what is under " held.x "," held.y " changed while"
                            . " the click was held — the list reordered, so this"
                            . " point is a DIFFERENT conversation now. Not played"
                            . " back; click the one you want.")
        SoundBeep(300, 200)
        CW_Toast("The list moved while that sent.`nClick again — this spot isn't"
               . " the same chat.", held.x, held.y)
        return
    }
    LOGI("clickwall", "send finished — playing the held click back at "
                    . held.x "," held.y " (" age "ms held)")
    CoordMode "Mouse", "Screen"
    MouseGetPos(&ox, &oy)
    ; Speed 0: jump straight there. A glide would be a mouse visibly moving on its
    ; own across the screen, which is alarming, and every pixel of it is a hover
    ; event on a row nobody asked to hover.
    MouseClick("Left", held.x, held.y, 1, 0)
    ; Put the pointer back. The click was the user's; the trip to make it was not,
    ; and leaving the cursor parked where MMA sent it means their next click
    ; starts from somewhere they did not put it.
    MouseMove(ox, oy, 0)
}

; ── did the list move? ────────────────────────────────────────────────────────
; A small bitmap from under the pointer, or 0 when verification is off or the grab
; failed. Deliberately WIDE and SHORT: a conversation row is a wide band, so a
; landscape patch stays inside one row while sampling enough of its text to tell
; it from the row that might replace it.
CW_Patch(x, y) {
    ; Per-monitor DPI for the length of this call — see core/dpi.ahk. Without
    ; it every coordinate below is virtualised on any monitor whose scaling
    ; differs from the primary's, and the wrong numbers stay self-consistent
    ; while disagreeing with the screen.
    _dpi := DpiScope()
    c := CW_Cfg()
    if !c.verify
        return 0
    w := Max(8, c.patchW), h := Max(4, c.patchH)
    return PILL_Grab(x - w // 2, y - h // 2, w, h)
}

; True when `b` still looks like `a`, i.e. the click is safe to play back.
;
; Fails OPEN — no patch, a failed grab, a size mismatch all return true and the
; click goes through. The check is a second opinion on a click the user made
; deliberately; when it cannot form one, the user's intent is the better guess.
CW_PatchSame(a, b) {
    if (!a || !b || a.w != b.w || a.h != b.h) {
        LOGV("clickwall", "no usable before/after patch — playing the click back"
                        . " without the moved-list check")
        return true
    }
    c := CW_Cfg()
    n := 0, same := 0
    x := a.x
    while (x < a.x + a.w) {
        y := a.y
        while (y < a.y + a.h) {
            n++
            if (PILL_ColorDist(PILL_Px(a, x, y), PILL_Px(b, x, y)) <= c.patchTol)
                same++
            y += 2
        }
        x += 2
    }
    if !n
        return true
    pct := (same * 100) // n
    LOGV("clickwall", "moved-list check: " pct "% of " n " sampled pixels unchanged"
                    . " (needs " c.patchMin "%)")
    return pct >= c.patchMin
}

; Its own tooltip slot. _MassToast in mass\runtime.ahk uses the default one, and a
; follow-up toast ("Last seen: f1 → sending f2") fires in the same second as a held
; click — one slot means whichever landed second wiped the other, and the one that
; loses is the only explanation on screen for a mouse that stopped working.
CW_Toast(text, x := "", y := "") {
    CoordMode "ToolTip", "Screen"
    if (x = "")
        ToolTip(text, , , 5)
    else
        ToolTip(text, x + 16, y + 20, 5)
    SetTimer(() => ToolTip(, , , 5), -1600)
}
