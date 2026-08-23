#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  click_wall_test.ahk — screen/click_wall.ahk, without a screen or a mouse.
;
;  Runs against a TEMP cfg, never userdata\mass_gui.cfg. Exit 1 on any failure.
;
;  The wall's job is a decision, and the decision is the part that can be wrong in
;  a way you would only discover by losing half a follow-up into a stranger's
;  chat. So what is tested here is the deciding:
;
;      which rectangle is being walled, out of three possible sources
;      is this point inside it
;      does the before/after patch notice the list moving
;      does arm/release actually claim and release the mouse button
;
;  What is NOT tested is the click itself. Playing one back needs a real
;  conversation list to play it into, and a test that clicked the screen would be
;  clicking whatever the person at this desk had open. See the note on the arm
;  case for how the claim is proved without pressing anything.
; ═══════════════════════════════════════════════════════════════════════════════

; The cfg must be pointed at scratch BEFORE click_wall.ahk loads, because its
; seeding block runs at load and would otherwise write [ClickWall] into the real
; mass_gui.cfg — which is exactly the kind of test that breaks the app it tests.
#Include "../../src/core/paths.ahk"
global MMA_CFG := A_Temp "\mma_clickwall_test_" A_TickCount ".cfg"
#Include "../../src/screen/click_wall.ahk"

pass := 0, fail := 0
Out(s) => FileAppend(s "`n", "*")

Check(name, got, want) {
    global pass, fail
    if (got == want) {
        pass++
        return
    }
    fail++
    Out("FAIL  " name)
    Out("      want: " String(want))
    Out("      got:  " String(got))
}

; The seed wrote defaults on load; clear the two keys the region tests own so each
; case states its own starting point rather than inheriting one.
IniWrite("", MMA_CFG, "ClickWall", "Region")
IniDelete(MMA_CFG, "ReplyBox", "Region")

Rect(r) => r ? (r.x "," r.y "," r.w "," r.h) : "none"
Raw(r)  => r ? (r.x "," r.y "," r.w "," r.h " " r.src (r.client ? " client" : " screen"))
             : "none"

; ── the region falls back three deep ─────────────────────────────────────────
;  This is the case that decides whether a fresh install is protected at all. If
;  the last fallback were dropped, the wall would be silently inert on every
;  machine that has never calibrated reply timers — on by default, doing nothing.
;
;  CW_RegionRaw is what is checked, because it is the whole of the decision AND it
;  answers without a window in front, which is what lets this run headless.
IniWrite("401", MMA_CFG, "NextFu", "RegionX")
IniWrite("135", MMA_CFG, "NextFu", "RegionY")
IniWrite("727", MMA_CFG, "NextFu", "RegionH")
Check("derived from NextFu", Raw(CW_RegionRaw()), "0,135,401,727 NextFu screen")

IniWrite("10,20,300,800", MMA_CFG, "ReplyBox", "Region")
Check("ReplyBox beats derived", Raw(CW_RegionRaw()), "10,20,300,800 ReplyBox client")

IniWrite("5,6,700,900", MMA_CFG, "ClickWall", "Region")
Check("ClickWall beats both", Raw(CW_RegionRaw()), "5,6,700,900 ClickWall client")

; A malformed region is IGNORED, not obeyed. Obeyed, it would wall a
; two-pixel rectangle somewhere near the origin and read as the feature being off.
IniWrite("garbage", MMA_CFG, "ClickWall", "Region")
Check("malformed falls through", Raw(CW_RegionRaw()), "10,20,300,800 ReplyBox client")
IniWrite("1,2,3", MMA_CFG, "ClickWall", "Region")
Check("too few fields falls through", Raw(CW_RegionRaw()), "10,20,300,800 ReplyBox client")
IniWrite("0,0,4,4", MMA_CFG, "ClickWall", "Region")
Check("too small falls through", Raw(CW_RegionRaw()), "10,20,300,800 ReplyBox client")

; ── the two coordinate spaces ────────────────────────────────────────────────
;  The bug this guards against leaves no trace. A client rectangle read as a screen
;  one is still a perfectly plausible rectangle, so the wall goes up, holds clicks
;  and plays them back — a few hundred pixels away from the list, on every machine,
;  looking exactly like the feature simply not working.
IniWrite("", MMA_CFG, "ClickWall", "Region")
IniDelete(MMA_CFG, "ReplyBox", "Region")
; A screen-space region needs no window and comes back unchanged.
Check("NextFu resolves as screen", Rect(CW_Region()), "0,135,401,727")
; A client-space one with no window to measure against REFUSES, rather than
; passing the numbers through as if they were screen coordinates.
IniWrite("10,20,300,800", MMA_CFG, "ReplyBox", "Region")
IniWrite("no such window exists 4b8f2", MMA_CFG, "ClickWall", "WinMatch")
Check("client region, no window", Rect(CW_Region()), "none")
; Same again with WinMatch blank: there is nothing it could be relative TO.
IniWrite("", MMA_CFG, "ClickWall", "WinMatch")
Check("client region, no WinMatch", Rect(CW_Region()), "none")
IniWrite("Infloww Messages", MMA_CFG, "ClickWall", "WinMatch")

; ── the zone test ────────────────────────────────────────────────────────────
;  CW_InZone reads the LIVE pointer, which a test must not move — this desk has a
;  browser on it. So the arithmetic lives in CW_PointIn and that is what is checked
;  here; CW_InZone is the two lines around it that read the mouse and the window.
IniWrite("100,200,300,400", MMA_CFG, "ClickWall", "Region")
z := CW_RegionRaw()   ; the rectangle itself; the space it is in is settled above
Check("inside",        CW_PointIn(z, 250, 400), true)
Check("top-left edge", CW_PointIn(z, 100, 200), true)   ; inclusive
Check("bottom-right",  CW_PointIn(z, 400, 600), false)  ; exclusive — x+w is outside
Check("left of it",    CW_PointIn(z,  99, 400), false)
Check("above it",      CW_PointIn(z, 250, 199), false)

; ── the moved-list check ─────────────────────────────────────────────────────
;  Two synthetic patches, in the shape PILL_Grab returns, so the comparison is
;  tested without a screen. The stakes: a false SAME plays a held click into a row
;  that now belongs to a different fan, which is the failure the whole file exists
;  to prevent.
Patch(w, h, fill) {
    buf := Buffer(w * h * 4, 0)
    Loop w * h
        NumPut("uint", fill, buf, (A_Index - 1) * 4)
    return {data: buf, w: w, h: h, x: 0, y: 0}
}
; The top `rows` rows differ, the rest are identical — a contiguous band, which is
; what a list actually does when it reorders under the pointer. A speckle would be
; the wrong shape AND untestable: CW_PatchSame samples every second pixel on both
; axes, so anything that only touches odd columns is invisible to it and the check
; would be measuring the test's arithmetic rather than the code's.
PatchRows(w, h, fill, other, rows) {
    p := Patch(w, h, fill)
    Loop rows * w
        NumPut("uint", other, p.data, (A_Index - 1) * 4)
    return p
}
IniWrite("1",  MMA_CFG, "ClickWall", "Verify")
IniWrite("28", MMA_CFG, "ClickWall", "PatchTol")
IniWrite("88", MMA_CFG, "ClickWall", "PatchMinPct")

same := Patch(40, 20, 0x202020)
Check("identical patches match", CW_PatchSame(same, Patch(40, 20, 0x202020)), true)
; Inside PatchTol: a hover highlight fading out under the pointer must not read as
; the list having reordered, or every click made while hovering gets thrown away.
Check("small shift still matches", CW_PatchSame(same, Patch(40, 20, 0x2A2A2A)), true)
Check("different row does not",    CW_PatchSame(same, Patch(40, 20, 0xE0E0E0)), false)
; Fails OPEN: no patch, or two that cannot be compared, must let the click through.
; The check is a second opinion on something the user did on purpose.
Check("no patch fails open",   CW_PatchSame(0, same), true)
Check("size mismatch fails open", CW_PatchSame(same, Patch(41, 20, 0x202020)), true)
; The percentage threshold itself. Sampling is every second row of 20, so ten rows
; are looked at: a two-row band is one of them (90% unchanged, over 88, passes) and
; a six-row band is three (70%, under 88, fails).
Check("90% unchanged passes",
      CW_PatchSame(same, PatchRows(40, 20, 0x202020, 0xE0E0E0, 2)), true)
Check("70% unchanged fails",
      CW_PatchSame(same, PatchRows(40, 20, 0x202020, 0xE0E0E0, 6)), false)
; Verify=0 means CW_Patch hands back 0, which fails open by the rule above — i.e.
; switching the check off plays every held click back blind, as documented.
IniWrite("0", MMA_CFG, "ClickWall", "Verify")
Check("Verify=0 grabs nothing", CW_Patch(500, 500), 0)
IniWrite("1", MMA_CFG, "ClickWall", "Verify")

; ── arming claims the button, releasing gives it back ────────────────────────
;  Proved WITHOUT pressing anything. A hotkey that is registered and On has a
;  ThisHotkey entry; asking Hotkey() to turn off a variant that was never
;  registered throws. So the claim is observable by inspection alone, and nothing
;  on this desk gets clicked to find out.
;
;  FEAT("clickWall") has to be true for CW_Arm to do anything, and it reads the
;  scratch cfg like everything else here — so Mode must be advanced too, or the
;  registry answers false for every feature regardless of its own key.
IniWrite("advanced", MMA_CFG, "Settings", "Mode")
IniWrite("1", MMA_CFG, "Settings", "ClickWall")
Check("feature reads on", FEAT("clickWall"), true)

Claimed() {
    try {
        HotIf CW_InZone
        Hotkey "*LButton", "Off"        ; throws if this variant does not exist
        Hotkey "*LButton", "On"         ; put it back the way it was found
        HotIf
        return true
    } catch {
        HotIf
        return false
    }
}
Check("idle: button not claimed", Claimed(), false)
CW_Arm()
Check("armed flag",     CW_ARMED,  true)
Check("armed: claimed", Claimed(), true)
CW_Release()
Check("released flag",  CW_ARMED,  false)

; A second arm after a release must work — the wall goes up and down dozens of
; times an hour, and an On/Off pair that only survives one round would protect the
; first follow-up of a shift and nothing after it.
CW_Arm()
Check("re-armed", CW_ARMED, true)
CW_Release()
Check("re-released", CW_ARMED, false)

; With the feature off, arming is a no-op. The checkbox is read per send rather
; than at startup, so unticking it takes hold on the very next follow-up.
IniWrite("0", MMA_CFG, "Settings", "ClickWall")
CW_Arm()
Check("feature off does not arm", CW_ARMED, false)
IniWrite("1", MMA_CFG, "Settings", "ClickWall")

; No region, no wall — and no exception either. A machine with a broken [NextFu]
; must lose the guard, not the engine.
IniWrite("0,0,0,0", MMA_CFG, "ClickWall", "Region")
IniDelete(MMA_CFG, "ReplyBox", "Region")
IniWrite("0", MMA_CFG, "NextFu", "RegionX")
Check("no region at all", Rect(CW_RegionRaw()), "none")
CW_Arm()
Check("no region does not arm", CW_ARMED, false)

; ── the watchdog ─────────────────────────────────────────────────────────────
;  The one failure that is worse than the bug: a wall left up by a send that never
;  finished, over a list nobody can click, with nothing on screen to say why.
IniWrite("100,200,300,400", MMA_CFG, "ClickWall", "Region")
IniWrite("401", MMA_CFG, "NextFu", "RegionX")
CW_Arm()
Check("armed before watchdog", CW_ARMED, true)
CW_HELD := {x: 1, y: 2, at: A_TickCount, patch: 0}
CW_Watchdog()
Check("watchdog dropped the wall", CW_ARMED, false)
; And it discards the held click rather than playing back into a list that has had
; eight seconds to reorder. If this were kept, the watchdog would fire the exact
; mis-click it exists to prevent.
Check("watchdog discarded the click", CW_HELD, 0)

; ── done ─────────────────────────────────────────────────────────────────────
try FileDelete(MMA_CFG)
Out("")
Out(fail ? ("FAILED  " fail " of " (pass + fail)) : ("ok  " pass " checks"))
ExitApp(fail ? 1 : 0)
