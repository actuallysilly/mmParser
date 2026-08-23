#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  click_wall_probe.ahk — where would the wall actually go, on THIS machine?
;
;  Read-only apart from the [ClickWall] seed that click_wall.ahk writes on load
;  (which the engine writes anyway on its next start). It binds no hotkeys, arms
;  nothing, and never clicks.
;
;  The question it answers is the one the unit test cannot: the test proves the
;  rectangle is CHOSEN and CONVERTED correctly, and this proves the numbers that
;  come out of that land on your conversation list rather than beside it. Run it
;  with Infloww in front.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../src/screen/click_wall.ahk"

Out(s) => FileAppend(s "`n", "*")

c := CW_Cfg()
Out("WinMatch      : '" c.win "'")
Out("window in front: '" WinGetTitle("A") "'")
Out("Infloww active : " (c.win = "" ? "n/a" : (WinActive(c.win) ? "yes" : "NO")))

raw := CW_RegionRaw()
if !raw {
    Out("region        : NONE — the wall would be inert")
    ExitApp(1)
}
Out("region source : [" raw.src "]  " raw.x "," raw.y " " raw.w "x" raw.h
  . "  (" (raw.client ? "client" : "screen") " coordinates)")

; Both readings, so a wrong one is visible rather than merely absent.
scr := CW_Region(c.win = "" ? "" : "A")
if !scr {
    Out("on screen     : could not resolve — is Infloww in front?")
    ExitApp(1)
}
Out("on screen     : x " scr.x " to " (scr.x + scr.w)
  . " , y " scr.y " to " (scr.y + scr.h))

ccx := 0, ccy := 0, ccw := 0, cch := 0
try WinGetClientPos(&ccx, &ccy, &ccw, &cch, "A")
Out("client area   : origin " ccx "," ccy "  size " ccw "x" cch)
Out("desktop       : " A_ScreenWidth "x" A_ScreenHeight)

; Does the wall sit clear of the pane the follow-up walker reads? If they overlap,
; the wall is over the conversation, not the list.
nfx := LOG_IniInt(MMA_CFG, "NextFu", "RegionX", 401)
Out("NextFu pane   : starts at x " nfx
  . (scr.x + scr.w <= nfx ? "  — the wall ends before it, good"
                          : "  — the wall OVERLAPS the conversation pane"))

CoordMode "Mouse", "Screen"
MouseGetPos(&mx, &my)
Out("pointer now   : " mx "," my "  → " (CW_PointIn(scr, mx, my)
                                         ? "INSIDE the wall" : "outside the wall"))
ExitApp(0)
