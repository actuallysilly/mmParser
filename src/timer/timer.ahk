#Requires AutoHotkey v2.0
#Include "../core/paths.ahk"
#SingleInstance Force
#Include "../core/hotkeys.ahk"

; ═══════════════════════════════════════════════════════════════════════════════
;  timer.ahk — a countdown timer, with or without a window.
; ───────────────────────────────────────────────────────────────────────────────
;  Two keys, both in hotkeys.ini [gui]:
;    timer        opens the window: minutes, seconds, Repeat, Beep, Start/Stop.
;    timerToggle  starts or stops the timer with NO window — the "nogui" key.
;                 It uses whatever the window last saved, and says "started" /
;                 "stopped" in a tooltip that is gone in a second.
;
;  Repeat: when it runs out it starts again from the top, until you stop it.
;  Beep:   it beeps Beeps times when it runs out. With Beep off a tooltip says
;          "Timer done" instead, so a finished timer is never silent AND invisible.
;
;  Settings live in mass_gui.cfg [Timer] and are read on every start, so the
;  Tools window can change them without a restart. Closing the window does not
;  stop the timer — only Stop, the toggle key, or switching the tool off does.
; ═══════════════════════════════════════════════════════════════════════════════

; Nothing else guarantees the script stays alive: both keys may be unbound and
; the window starts hidden. See the note in screen/stats_overlay.ahk.
Persistent

CFG := MMA_CFG

_running := false
_endTick := 0
_periodMs := 0

; ── window ────────────────────────────────────────────────────────────────────
tw := Gui("+AlwaysOnTop +ToolWindow", "MMA timer")
tw.SetFont("s9", "Segoe UI")
tw.Add("Text", "x12 y14", "Minutes")
edMin := tw.Add("Edit", "x62 y11 w44 Number")
tw.Add("Text", "x116 y14", "Seconds")
edSec := tw.Add("Edit", "x168 y11 w44 Number")
cbRepeat := tw.Add("CheckBox", "x12 y42", "Repeat")
cbBeep   := tw.Add("CheckBox", "x90 y42", "Beep")
tw.SetFont("s22 Bold")
txtLeft := tw.Add("Text", "x12 y66 w200 Center", "0:00")
tw.SetFont("s9 Norm")
btnGo := tw.Add("Button", "x12 y110 w200 h28 Default", "Start")
btnGo.OnEvent("Click", StartStopClicked)
tw.OnEvent("Close", HideWindow)
tw.OnEvent("Escape", HideWindow)

HK_Bind("gui.timer",       OpenWindow)
HK_Bind("gui.timerToggle", ToggleNoGui)

; ── settings ──────────────────────────────────────────────────────────────────
ReadSettings() {
    global CFG
    return {min:    LOG_IniInt(CFG, "Timer", "Minutes", 5),
            sec:    LOG_IniInt(CFG, "Timer", "Seconds", 0),
            repeat: LOG_IniInt(CFG, "Timer", "Repeat", 0),
            beep:   LOG_IniInt(CFG, "Timer", "Beep", 1),
            beeps:  LOG_IniInt(CFG, "Timer", "Beeps", 3)}
}

; What the window shows goes back to the cfg, so the no-window key uses it next.
SaveWindowSettings() {
    global CFG, edMin, edSec, cbRepeat, cbBeep
    try IniWrite(edMin.Value = "" ? 0 : edMin.Value, CFG, "Timer", "Minutes")
    try IniWrite(edSec.Value = "" ? 0 : edSec.Value, CFG, "Timer", "Seconds")
    try IniWrite(cbRepeat.Value, CFG, "Timer", "Repeat")
    try IniWrite(cbBeep.Value, CFG, "Timer", "Beep")
}

; ── window ────────────────────────────────────────────────────────────────────
OpenWindow(*) {
    global tw, edMin, edSec, cbRepeat, cbBeep, _running
    s := ReadSettings()
    edMin.Value := s.min
    edSec.Value := s.sec
    cbRepeat.Value := s.repeat
    cbBeep.Value := s.beep
    Paint()
    tw.Show("w224 h150")
}

HideWindow(*) {
    global tw
    tw.Hide()
}

StartStopClicked(*) {
    global _running
    if _running {
        StopTimer()
        return
    }
    SaveWindowSettings()
    StartTimer()
}

; ── the no-window key ─────────────────────────────────────────────────────────
ToggleNoGui(*) {
    global _running
    if _running {
        StopTimer()
        Flash("Timer stopped")
    } else if StartTimer() {
        Flash("Timer started — " FormatLeft(_periodMs))
    }
}

; ── the countdown ─────────────────────────────────────────────────────────────
StartTimer() {
    global _running, _endTick, _periodMs
    s := ReadSettings()
    _periodMs := (s.min * 60 + s.sec) * 1000
    if (_periodMs <= 0) {
        Flash("Timer is set to 0:00")
        return false
    }
    _endTick := A_TickCount + _periodMs
    _running := true
    LOGI("timer", "started " FormatLeft(_periodMs) (s.repeat ? ", repeating" : ""))
    SetTimer(Tick, 250)
    Paint()
    return true
}

StopTimer() {
    global _running
    _running := false
    SetTimer(Tick, 0)
    LOGI("timer", "stopped")
    Paint()
}

Tick() {
    global _endTick, _periodMs
    if (A_TickCount >= _endTick) {
        s := ReadSettings()
        if s.repeat
            _endTick += _periodMs
        else
            StopTimer()
        Ring(s)
    }
    Paint()
}

; Beeping blocks this thread for a second or so; the countdown is measured
; against _endTick, not counted in ticks, so it loses nothing.
Ring(s) {
    if !s.beep {
        Flash("Timer done", 3000)
        return
    }
    Loop Max(1, s.beeps) {
        SoundBeep(1000, 180)
        Sleep(120)
    }
}

Paint() {
    global txtLeft, btnGo, _running, _endTick, _periodMs
    left := _running ? Max(0, _endTick - A_TickCount) : 0
    txtLeft.Value := _running ? FormatLeft(left) : "0:00"
    btnGo.Text := _running ? "Stop" : "Start"
    A_IconTip := _running ? "MMA timer — " FormatLeft(left) : "MMA timer"
}

; 90000 -> "1:30", 3723000 -> "1:02:03". Rounds UP, so it never shows 0:00
; while there is still time left.
FormatLeft(ms) {
    t := Ceil(ms / 1000)
    h := t // 3600, m := Mod(t, 3600) // 60, s := Mod(t, 60)
    return h ? Format("{}:{:02}:{:02}", h, m, s) : Format("{}:{:02}", m, s)
}

Flash(text, ms := 1200) {
    ToolTip(text)
    SetTimer(ClearFlash, -ms)
}

ClearFlash() {
    ToolTip()
}
