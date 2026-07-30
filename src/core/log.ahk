#Requires AutoHotkey v2.0
#Include "paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  log.ahk — one log, every process, and a switch that turns failures into dialogs.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA is not one program. It is up to eight processes — the GUI, the mass engine,
;  sequences.ahk, general.ahk, the account files, the detector, the stats overlay,
;  two Python children — that talk to each other through ini files and
;  PostMessage. Nothing in that arrangement produces a stack trace when it goes
;  wrong. It produces NOTHING, which is the actual complaint: "it silently failed
;  to do something on my friend's machine".
;
;  Every failure this repo has fixed has the same shape, and the comments through
;  the tree read like a list of them:
;
;    • a folder missing from MMA_ScriptPath's list, so a startup script never runs
;      — "no error, no dialog, nothing in the log"
;    • an IniRead with a default, so a setting silently reverts
;    • a key absent from hotkeys.ini, so an action is simply unbound
;    • a feature switched off, so its hotkey never registers
;    • the engine dropped out of StartupScripts, so every mass key went dead
;
;  Not one of those throws. Every one of them is a branch that returned early, and
;  the ONLY way to see a branch that returned early is to have written it down on
;  the way past. That is what this file is for, and it is why there is a BAIL level
;  next to FAIL: "nothing happened, on purpose, here is which purpose" is the line
;  that actually ends these hunts.
;
;  ─── HOW IT REACHES EVERYTHING ───────────────────────────────────────────────
;  paths.ahk includes this file at its end, and paths.ahk is the one file every
;  script in the tree already includes. So every process gets the logger, a boot
;  line, an exit line and an uncaught-error hook with no per-script wiring — and
;  cannot get them out of step. (The include is circular and that is fine: AHK
;  loads a given file once no matter how many times it is named.)
;
;  ─── THE THREE SWITCHES ──────────────────────────────────────────────────────
;  mass_gui.cfg [Debug], owned by Settings ▸ Debug and written nowhere else:
;
;    Logging=1     write to debuglogs\mma.log at all.        Default ON.
;    Popups=0      a failure also raises a dialog.           Default OFF.
;    MaxLogging=0  also write the VERB firehose.             Default OFF.
;
;  Logging defaults ON because a log nobody switched on is a log that is empty on
;  the morning you need it. It costs one FileAppend per event.
;
;  Popups is the "debug on someone else's machine" switch. Off, a failure is a
;  line in a file they would have to find, open and send you. On, it is a dialog
;  in front of them carrying the last 20 log lines, which they can screenshot.
;  Same information, and only one of those two actually arrives.
;
;  MaxLogging is the firehose: every gate, every resolved setting, every branch.
;  Off by default because it writes megabytes an hour, and because at that volume
;  the interesting line is harder to find, not easier.
;
;  MMA_DEBUG in the ENVIRONMENT overrides all three (max / popups / off). That is
;  for the machine you cannot open Settings on: set it, launch MMA, reproduce.
;
;  ─── RULES THIS FILE OBEYS ───────────────────────────────────────────────────
;  1. A logger must never crash the thing it is logging for. Every path here is
;     inside a try, including the ones that look incapable of throwing.
;  2. A logger must never lose the last line before a crash, so nothing is
;     buffered — the tail of the file is what you are reading it for.
;  3. Reading three ini keys per event would put a file read in the send path, so
;     the switches are cached for LOG_SETTINGS_TTL and re-read after that. The
;     cost of a toggle taking a second and a half to apply is nothing; the cost of
;     an IniRead per keystroke is "MMA feels laggy".
; ═══════════════════════════════════════════════════════════════════════════════

; ─── switches, cached ─────────────────────────────────────────────────────────
global LOG_SETTINGS_TTL := 1500      ; ms before the [Debug] keys are re-read
global _LOG_T   := 0                 ; when we last read them (0 = never)
global _LOG_ON  := true              ; Logging
global _LOG_POP := false             ; Popups
global _LOG_MAX := false             ; MaxLogging
; NOT _LOG_FORCED. A variable and a function whose names differ only by case are
; the same name to AHK, and the script fails to LOAD — silently, exit code 0. The
; reader below is _LOG_Forced(), so the cache it fills cannot be called that.
global _LOG_FORCE_CACHE := ""        ; what MMA_DEBUG pinned them to, if anything

; ─── the in-memory tail ───────────────────────────────────────────────────────
;  The last few lines THIS process wrote, kept so a failure dialog can show what
;  led up to it. A popup saying "clipboard never arrived" is a fact; the same
;  popup with the twelve lines before it is a diagnosis.
global LOG_RING_MAX := 40
global _LOG_RING := []

; ─── rotation ─────────────────────────────────────────────────────────────────
;  Checked every LOG_ROTATE_EVERY writes rather than every write: FileGetSize is a
;  file system call and this is on the send path. Eight processes race to rotate;
;  the loser's FileMove throws and is swallowed, which is the correct outcome.
global LOG_MAX_BYTES    := 8 * 1024 * 1024
global LOG_ROTATE_EVERY := 250
global _LOG_WRITES := 0

; When THIS process started. A_TickCount is milliseconds since the machine booted,
; not since the script started, so the exit line's uptime has to be measured from
; a mark taken here — otherwise every script reports the same number and it is the
; machine's, which reads as plausible and is useless.
global _LOG_START_TICK := A_TickCount

; ─── popup budget ─────────────────────────────────────────────────────────────
;  Two limits, because a failure inside a timer or a loop is not one failure, it
;  is one every 500ms — and 200 modal dialogs is not a debugging aid, it is a
;  machine you have to reboot.
;    • the same tag+message pops ONCE per process, ever
;    • no more than LOG_POP_MAX dialogs per process, ever
;  Both are per-process, so restarting MMA arms them again. Everything suppressed
;  is still in the file, and the suppression itself is logged.
global LOG_POP_MAX := 15
global _LOG_POPPED := Map()
global _LOG_POPS   := 0

; ═══════════════════════════════════════════════════════════════════════════════
;  Reading the switches
; ═══════════════════════════════════════════════════════════════════════════════

; MMA_DEBUG=max|popups|off in the environment beats the cfg, and is read once.
;
; This exists for the machine you are debugging over a chat window. Telling
; somebody "open Settings, Debug tab, tick two boxes, reproduce it" is three
; chances to tick the wrong thing; "close MMA, run this one line, launch MMA" is
; none. It also covers the case the cfg cannot: a failure during startup, before
; anything has read mass_gui.cfg.
_LOG_Forced() {
    global _LOG_FORCE_CACHE
    if (_LOG_FORCE_CACHE != "")
        return _LOG_FORCE_CACHE
    v := ""
    try v := StrLower(Trim(EnvGet("MMA_DEBUG")))
    _LOG_FORCE_CACHE := (v = "") ? "-" : v
    return _LOG_FORCE_CACHE
}

_LOG_Settings() {
    global _LOG_T, _LOG_ON, _LOG_POP, _LOG_MAX, LOG_SETTINGS_TTL
    f := _LOG_Forced()
    if (f = "max") {
        _LOG_ON := true, _LOG_MAX := true, _LOG_POP := true
        return
    }
    if (f = "popups") {
        _LOG_ON := true, _LOG_POP := true
        return
    }
    if (f = "off") {
        _LOG_ON := false, _LOG_MAX := false, _LOG_POP := false
        return
    }
    now := A_TickCount
    if (_LOG_T && now - _LOG_T < LOG_SETTINGS_TTL)
        return
    _LOG_T := now
    ; Swallowed deliberately: an unreadable cfg leaves the previous values in
    ; place, and the initial values are "log to file, no popups". A logger that
    ; switches itself off because it could not read its own settings is the exact
    ; silent failure this file exists to stop.
    try {
        _LOG_ON  := Trim(IniRead(MMA_CFG, "Debug", "Logging",    "1")) = "1"
        _LOG_POP := Trim(IniRead(MMA_CFG, "Debug", "Popups",     "0")) = "1"
        _LOG_MAX := Trim(IniRead(MMA_CFG, "Debug", "MaxLogging", "0")) = "1"
    }
}

LOG_On()     => (_LOG_Settings(), _LOG_ON)
LOG_Popups() => (_LOG_Settings(), _LOG_POP)

; True when the firehose is on. Call sites use this to skip building a message
; they are about to throw away — LOGV checks it too, but AHK evaluates the
; argument before the call, so `LOGV(t, Expensive())` pays for Expensive() either
; way. `if LOG_Max()` in front of that is the difference.
LOG_Max()    => (_LOG_Settings(), _LOG_MAX)

; Write the three keys into the cfg the first time we look, so they are
; discoverable by opening the file rather than being invisible defaults buried
; here. Same trick AltStageSetting plays in utils.ahk.
LOG_Seed() {
    static done := false
    if done
        return
    done := true
    try {
        for k, dflt in Map("Logging", "1", "Popups", "0", "MaxLogging", "0")
            if (Trim(IniRead(MMA_CFG, "Debug", k, "«unset»")) = "«unset»")
                IniWrite(dflt, MMA_CFG, "Debug", k)
    }
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Writing
; ═══════════════════════════════════════════════════════════════════════════════

; Pad/truncate to a fixed width by hand rather than through Format's "{:-18}".
; The columns are the whole point of the format — you read this file by scanning
; down the tag column — and a helper that cannot throw is worth four lines.
_LOG_Pad(s, n) {
    s := String(s)
    if (StrLen(s) > n)
        return SubStr(s, 1, n)
    while (StrLen(s) < n)
        s .= " "
    return s
}

; One event is one line, always. A message carrying a newline would otherwise
; split into two records and break every grep in this file's own docs.
_LOG_Flat(s, limit := 700) {
    s := String(s)
    s := StrReplace(s, "`r`n", " ¶ ")
    s := StrReplace(s, "`n", " ¶ ")
    s := StrReplace(s, "`r", " ¶ ")
    s := StrReplace(s, "`t", "  ")
    if (StrLen(s) > limit)
        s := SubStr(s, 1, limit) " …[+" (StrLen(s) - limit) " chars]"
    return s
}

_LOG_Stamp() {
    return FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "." _LOG_Pad(A_MSec, 3)
}

; Eight processes append to one file. FileAppend opens, writes and closes, so a
; collision is a sharing violation rather than corruption — it throws, and the
; retry catches the overwhelming majority. A line lost after three attempts is
; preferable to a logger that blocks the send path.
_LOG_Append(line) {
    loop 3 {
        try {
            FileAppend(line "`n", MMA_LOGFILE, "UTF-8")
            return true
        }
        Sleep 8
    }
    return false
}

_LOG_Rotate() {
    global _LOG_WRITES, LOG_ROTATE_EVERY, LOG_MAX_BYTES
    if (Mod(++_LOG_WRITES, LOG_ROTATE_EVERY) != 0)
        return
    try {
        if (FileExist(MMA_LOGFILE) && FileGetSize(MMA_LOGFILE) > LOG_MAX_BYTES) {
            try FileDelete(MMA_LOGFILE ".1")
            FileMove(MMA_LOGFILE, MMA_LOGFILE ".1", true)
        }
    }
}

; The one place a line is built. Everything public routes through here.
_LOG_Write(level, tag, msg) {
    global _LOG_RING, LOG_RING_MAX
    try {
        line := _LOG_Stamp()
             . "  " _LOG_Pad(level, 4)
             . "  " _LOG_Pad(A_ScriptName, 20)
             . " " _LOG_Pad(ProcessExist(), 6)
             . "  " _LOG_Pad(tag, 22)
             . "  " _LOG_Flat(msg)

        _LOG_RING.Push(line)
        while (_LOG_RING.Length > LOG_RING_MAX)
            _LOG_RING.RemoveAt(1)

        _LOG_Rotate()
        _LOG_Append(line)
    }
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The public API
; ───────────────────────────────────────────────────────────────────────────────
;  Six levels, and which one you reach for is the whole skill of reading this
;  file back:
;
;    LOGI     INFO  something happened that you would want in a timeline
;    LOGV     VERB  something happened, and there are thousands of them
;    LOGW     WARN  wrong, but survivable, and nobody is going to notice
;    LOGE     FAIL  it did not work — the only level that can raise a dialog
;    LOG_Bail BAIL  it deliberately did nothing, and here is why
;    LOG_Ok   DONE  a thing that can fail finished — pairs with the FAIL above it
;
;  `tag` is a dotted scope: "mass.fu2", "hk.bind", "proc.engine". Keep it short
;  and keep it stable; it is the column you grep.
;
;  ─── WHY LOGI AND NOT LOG ────────────────────────────────────────────────────
;  Because `Log()` IS AN AUTOHOTKEY BUILT-IN — the base-10 logarithm — and this
;  is the nastiest possible collision. A user-defined LOG() shadows it, so every
;  file that includes this one works perfectly; every file that does NOT silently
;  binds to the built-in instead, and `LOG("tag", "msg")` fails at LOAD with "Too
;  many parameters passed to function". The failure lands in a file that never
;  mentioned the logger, blaming a function nobody wrote, and it only appears once
;  some unrelated include order changes.
;
;  Naming the info level LOGI removes the collision outright rather than relying
;  on every future file remembering to include paths.ahk first, and it makes the
;  four levels symmetrical to read: LOGI / LOGV / LOGW / LOGE.
; ═══════════════════════════════════════════════════════════════════════════════

LOGI(tag, msg) {
    if LOG_On()
        _LOG_Write("INFO", tag, msg)
}

LOGV(tag, msg) {
    if (LOG_On() && LOG_Max())
        _LOG_Write("VERB", tag, msg)
}

LOGW(tag, msg) {
    if LOG_On()
        _LOG_Write("WARN", tag, msg)
}

LOG_Ok(tag, msg) {
    if LOG_On()
        _LOG_Write("DONE", tag, msg)
}

; ── devlog: proof that a thing FIRED ─────────────────────────────────────────
;  Every other level in this file describes an outcome. This one describes an
;  ARRIVAL: "control reached here". That is a different question and it is the
;  first one you actually ask, because the two candidate explanations for
;  "nothing happened" are:
;
;      the code ran and decided to do nothing   → there is a BAIL line
;      the code never ran at all                → there is no line at all
;
;  Without an arrival marker those are indistinguishable, and you cannot tell
;  which half of the app to go and look at. A `devlog:` line at the top of a
;  handler settles it in one grep.
;
;  Written at the NORMAL level, not gated behind max logging, because a
;  breadcrumb nobody can see by default is not a breadcrumb. They are kept
;  deliberately terse and are placed at meaningful checkpoints — a handler being
;  entered, a service tick, a multi-step operation finishing — never inside a
;  loop body, which is what max logging is for.
;
;  Greppable two ways: the DEVL level column, or the "devlog:" prefix.
LOGD(tag, msg) {
    if LOG_On()
        _LOG_Write("DEVL", tag, "devlog: " msg)
}

; A devlog for something that fires on a TIMER — writes at most once per
; `everyMs`, per tag.
;
; The background services poll every 500ms. A devlog per tick would be 7,000 lines
; an hour each and would bury everything else, but "is the detector still alive?"
; is a real question with no other answer: it has no window, no tray icon and no
; output, so a dead one and an idle one look identical. A heartbeat every minute
; costs 60 lines an hour and answers it — and its ABSENCE from a stretch of the
; log is what tells you when the service died.
LOG_Heartbeat(tag, msg, everyMs := 60000) {
    static last := Map()
    if !LOG_On()
        return
    now := A_TickCount
    if (last.Has(tag) && now - last[tag] < everyMs)
        return
    last[tag] := now
    _LOG_Write("DEVL", tag, "devlog: heartbeat — " msg)
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Throw-proof readers
; ───────────────────────────────────────────────────────────────────────────────
;  `Integer(IniRead(file, sec, key, "0"))` appears all over this tree and every
;  instance is a latent crash. IniRead hands back whatever is in the file, and
;  Integer() THROWS on anything that is not a number — so ONE hand-edited or
;  half-written value takes down whatever script read it.
;
;  Where those reads sit at the top level of a script, that is not a degraded
;  setting, it is a script that DOES NOT LOAD:
;
;    • mass/runtime.ahk reads nine of them → the engine dies → every mass hotkey
;      in MMA is dead, silently
;    • core/hotkeys.ahk reads one → every script that binds a key dies
;    • screen/model_detector.ahk reads ten → the detector dies, and it has no
;      window, so there is nothing at all to notice
;
;  active_model.ahk's `_IniInt` was written for exactly this and says so in its
;  comment. It lives in a file not everything includes, so the canonical version
;  is here — reachable from anywhere, and able to say when it fired.
; ═══════════════════════════════════════════════════════════════════════════════

; An ini value as a number, or the default when it is not one. Never throws.
LOG_IniInt(file, section, key, default, tag := "cfg") {
    v := default
    try v := Trim(IniRead(file, section, key, default))
    if IsInteger(v)
        return Integer(v)
    LOGW(tag, "[" section "] " key " = '" v "' is not a number in "
            . _LOG_BaseName(file) " — using " default " instead."
            . " (Left unguarded this would have thrown.)")
    return default
}

; The same guard for a value that did not come from an ini — a ListView cell, a
; regex capture, a GUI field. `what` is for the log line only.
LOG_Int(v, default, what := "value") {
    v := Trim(String(v))
    if IsInteger(v)
        return Integer(v)
    LOGW("cfg.int", what " = '" v "' is not a number — using " default " instead")
    return default
}

; A FRACTIONAL ini value, for the settings that are genuinely not integers — the
; stats overlay's 0.30 / 0.40 / 0.50 ratio thresholds.
;
; Number() throws on non-numeric exactly like Integer() does, and IsNumber() is
; the test that accepts "0.30" where IsInteger() would reject it and silently
; force the default. Using LOG_IniInt for these would therefore "work" and be
; wrong: every threshold would quietly snap to its fallback.
LOG_IniNum(file, section, key, default, tag := "cfg") {
    v := default
    try v := Trim(IniRead(file, section, key, default))
    if IsNumber(v)
        return Number(v)
    LOGW(tag, "[" section "] " key " = '" v "' is not a number in "
            . _LOG_BaseName(file) " — using " default " instead")
    return default
}

; "This returned early, and here is the condition that made it."
;
; The most valuable level in the file and the one with no equivalent anywhere
; else. A feature that is off, a key that is unbound, a mass slot that is empty,
; a window that is not in front — all of them are correct behaviour, all of them
; look identical to the user (nothing happened), and all of them are what the
; question "why did it silently do nothing?" is actually asking about.
LOG_Bail(tag, why) {
    if LOG_On()
        _LOG_Write("BAIL", tag, why)
}

; It did not work.
;
; Written even when Logging is switched off. A failure is never noise, and a user
; who turned logging off to keep the file small still wants the file to contain
; the reason MMA stopped working. Also mirrored into error_log.txt, which stays
; small enough to open and read top to bottom — mma.log is a timeline, this is a
; list of everything that went wrong.
LOGE(tag, msg, detail := "") {
    full := msg (detail != "" ? "   ← " detail : "")
    _LOG_Write("FAIL", tag, full)
    try FileAppend(_LOG_Stamp() "  [" A_ScriptName "]  " tag ": " _LOG_Flat(full) "`n",
                   MMA_ERRLOG, "UTF-8")
    if LOG_Popups()
        _LOG_Popup(tag, msg, detail)
}

; ─── helpers that make instrumenting a call site one line ─────────────────────

; An Error object as a single readable string.
LOG_Err(e) {
    if !IsObject(e)
        return String(e)
    s := ""
    try s := (e.HasProp("Message") ? e.Message : Type(e))
    try if (e.HasProp("What") && e.What != "")
        s .= " in " e.What
    try if (e.HasProp("File") && e.File != "")
        s .= " (" _LOG_BaseName(e.File) ":" (e.HasProp("Line") ? e.Line : "?") ")"
    try if (e.HasProp("Extra") && e.Extra != "")
        s .= " extra=" e.Extra
    return s
}

_LOG_BaseName(p) {
    cut := InStr(p, "\", , -1)
    return cut ? SubStr(p, cut + 1) : p
}

; Run something that might throw, and turn the throw into a FAIL line instead of
; a dialog nobody reads or a `try` that swallows it whole.
;
;     LOG_Try("proc.engine", "start engine", () => Run(path))
;
; Returns what fn returned, or "" if it threw. `ok` is out-param style for the
; callers that need to branch on it — declared `&ok?`, which is how v2 spells an
; OPTIONAL ByRef parameter (`&ok := unset` is not valid syntax).
LOG_Try(tag, what, fn, &ok?) {
    ok := false
    try {
        r := fn()
        ok := true
        return r
    } catch as e {
        LOGE(tag, what " failed", LOG_Err(e))
    }
    return ""
}

; An IniRead that says so when it falls back to the default.
;
; This is the single most common silent failure in the tree — paths.ahk's own
; header is about it ("IniRead with a default just returns the default, so
; settings quietly revert and nothing says why"). At VERB level every defaulted
; read is written down, so "the setting did nothing" stops being a theory.
; The sentinel is NOT called UNSET: `unset` is a reserved word in AHK v2 (the
; value IsSet tests for), so a static of that name will not load.
LOG_IniRead(file, section, key, default, tag := "cfg") {
    static NOKEY := Chr(1) "«unset»"
    v := NOKEY
    try v := IniRead(file, section, key, NOKEY)
    if (v == NOKEY) {
        LOGV(tag, "[" section "] " key " absent in " _LOG_BaseName(file)
                . " → default '" default "'")
        return default
    }
    LOGV(tag, "[" section "] " key " = '" Trim(v) "'")
    return v
}

; Dump a block of related values as one line — what a script resolved at boot,
; what a scan measured, what a record holds.
;
;     LOG_Kv("mass.load", Map("models", 3, "masses", 12, "file", MMA_MASSES))
LOG_Kv(tag, pairs, level := "INFO") {
    if !LOG_On()
        return
    if (level = "VERB" && !LOG_Max())
        return
    s := ""
    try {
        for k, v in pairs
            s .= (s = "" ? "" : "  ") k "=" (IsObject(v) ? Type(v) : String(v))
    }
    _LOG_Write(level, tag, s)
}

; A line you can find again. The Debug tab's "Mark log" button writes one, so a
; user can bracket a reproduction: press, do the broken thing, press.
LOG_Marker(text := "") {
    _LOG_Write("MARK", "marker",
               "──────── " (text = "" ? "MARK" : text) " ────────")
}

; ═══════════════════════════════════════════════════════════════════════════════
;  The popup
; ═══════════════════════════════════════════════════════════════════════════════

; A dialog carrying its own context. The ring buffer is the reason this is worth
; showing at all: "OCR returned nothing" is a fact you cannot act on, while the
; same message under the twelve lines that preceded it usually names the cause.
_LOG_Popup(tag, msg, detail) {
    global _LOG_POPPED, _LOG_POPS, LOG_POP_MAX, _LOG_RING
    try {
        sig := tag "|" msg
        if _LOG_POPPED.Has(sig)
            return                      ; already shown once in this process
        _LOG_POPPED[sig] := true
        if (_LOG_POPS >= LOG_POP_MAX) {
            if (_LOG_POPS = LOG_POP_MAX) {
                _LOG_POPS++
                _LOG_Write("WARN", "log.popup",
                           "popup budget spent (" LOG_POP_MAX ") — further failures are"
                         . " logged only, until this script restarts")
            }
            return
        }
        _LOG_POPS++

        tail := ""
        start := Max(1, _LOG_RING.Length - 20)
        loop (_LOG_RING.Length - start + 1)
            tail .= _LOG_RING[start + A_Index - 1] "`n"

        body := "MMA hit a problem and kept going.`n`n"
              . "WHAT   " msg "`n"
              . "WHERE  " tag "   in " A_ScriptName "  (pid " ProcessExist() ")`n"
              . (detail != "" ? "DETAIL " detail "`n" : "")
              . "`n──── the last " (_LOG_RING.Length - start + 1)
              . " log lines from this script ────`n" tail
              . "`nAll of this is in " MMA_LOGFILE "`n"
              . "You are seeing this because Settings ▸ Debug ▸ "
              . "'Report errors with a pop-up' is on. Turn it off there to log silently."

        ; System-modal so it is visible over Infloww, and timed so a failure that
        ; fires while nobody is at the machine cannot wedge a hotkey thread
        ; forever — a hotkey handler blocked in MsgBox is a hotkey that never
        ; clears _HK_SENDING, which would take every other key down with it.
        MsgBox(body, "MMA — something failed", "Icon! 4096 T60")
    }
}

; ═══════════════════════════════════════════════════════════════════════════════
;  Lifecycle — installed automatically in every process that includes paths.ahk
; ═══════════════════════════════════════════════════════════════════════════════

; Uncaught errors.
;
; Returns 0, which keeps AHK's own dialog exactly as it was. That is deliberate:
; AHK's dialog already carries the stack and already interrupts you, so replacing
; it with ours would trade information for consistency. What was missing was the
; WRITTEN record, and that is what this adds — with the stack, which the old
; crashlog.ahk did not capture.
_LOG_OnError(err, mode) {
    try {
        _LOG_Write("CRSH", "uncaught", LOG_Err(err) "   mode=" mode)
        try FileAppend(_LOG_Stamp() "  [" A_ScriptName "]  UNCAUGHT: "
                     . _LOG_Flat(LOG_Err(err)) "`n", MMA_ERRLOG, "UTF-8")
        ; `frame`, not `ln` — some script in the tree has a global by that name,
        ; and a local shadowing a global is a #Warn warning in every file that
        ; includes both. A logger that adds warnings to the build is not a good
        ; look for the file whose whole job is noticing problems.
        if (IsObject(err) && err.HasProp("Stack") && err.Stack != "")
            for frame in StrSplit(err.Stack, "`n", "`r")
                if (Trim(frame) != "")
                    _LOG_Write("CRSH", "uncaught.stack", Trim(frame))
    }
    return 0
}
OnError(_LOG_OnError)

; Exit. Catches the ones you cannot see coming: a ProcessClose from the watchdog,
; a #SingleInstance replacement, a KillAllScripts. "engine.ahk exited, reason
; Close" three seconds before the keys went dead is the whole answer to a class
; of bug that currently reads as "the hotkeys just stopped".
;
; Verified not to make a script persistent, so the launcher and the tools\ test
; files still exit on their own exactly as before.
_LOG_OnExit(reason, code) {
    global _LOG_START_TICK
    try _LOG_Write("EXIT", "lifecycle", "reason=" reason "  code=" code
                 . "  uptime=" Round((A_TickCount - _LOG_START_TICK) / 1000) "s")
    return 0
}
OnExit(_LOG_OnExit)

; Boot. One line per process, at include time, before that script's own code has
; had a chance to fail — so a script that dies during load still leaves proof it
; started, which is the difference between "it crashed" and "it never ran".
_LOG_Boot() {
    try {
        LOG_Seed()
        _LOG_Settings()
        f := _LOG_Forced()
        _LOG_Write("BOOT", "lifecycle",
                   "start  ahk=" A_AhkVersion
                 . "  admin=" (A_IsAdmin ? "y" : "n")
                 . "  log=" (_LOG_ON ? "on" : "off")
                 . "  popups=" (_LOG_POP ? "on" : "off")
                 . "  max=" (_LOG_MAX ? "on" : "off")
                 . ((f != "-") ? "  MMA_DEBUG=" f : "")
                 . "  file=" A_ScriptFullPath)
    }
}
_LOG_Boot()

; ═══════════════════════════════════════════════════════════════════════════════
;  The diagnostic report
; ───────────────────────────────────────────────────────────────────────────────
;  One file to ask somebody for. Environment, both config files in full, and the
;  tail of the log — because "send me your log" produces a log with no idea what
;  version, what mode or what settings produced it, and then a second round trip.
; ═══════════════════════════════════════════════════════════════════════════════

; `rep`, not `out`: `out` is a global somewhere in the tree, and a local of the
; same name is a #Warn warning in every script that includes both.
LOG_Report(tailLines := 400) {
    rep := "MMA diagnostic report`n"
         . "generated  " _LOG_Stamp() "`n"
    try rep .= "version    " Trim(FileRead(MMA_VERSION, "UTF-8")) "`n"
    rep .= "autohotkey " A_AhkVersion "`n"
         . "windows    " A_OSVersion "  " (A_Is64bitOS ? "64-bit" : "32-bit") "`n"
         . "computer   " A_ComputerName "`n"
         . "admin      " (A_IsAdmin ? "yes" : "no") "`n"
         . "root       " MMA_ROOT "`n"
         . "screen     " A_ScreenWidth "x" A_ScreenHeight "`n"
    ; The mode is read from the cfg, NOT through MODE_Current(). modes.ahk is not
    ; included here and must not be: AHK resolves function calls at LOAD time, so
    ; a call to a function this process never included is a load-time error in
    ; every script that includes paths.ahk — i.e. all of them. A `try` cannot
    ; save you from that; only not writing the call can.
    try rep .= "mode       " Trim(IniRead(MMA_CFG, "Settings", "Mode", "advanced")) "`n"

    ; Both config files IN FULL. They are small, they are the thing that differs
    ; between the machine where it works and the machine where it does not, and
    ; asking for them separately is the round trip this file exists to avoid.
    ; Message text and masses are deliberately NOT included — this gets sent to
    ; somebody, and the masses are the user's work, not diagnostic data.
    for label, path in Map("mass_gui.cfg", MMA_CFG, "hotkeys.ini", MMA_HK_INI) {
        rep .= "`n══════ " label " ══════`n"
        try {
            rep .= FileExist(path) ? FileRead(path, "UTF-8") : "(missing: " path ")"
        } catch as e
            rep .= "(unreadable: " LOG_Err(e) ")"
        rep .= "`n"
    }

    ; Names and sizes only, for the same reason: masses.json's SIZE answers "did
    ; his masses save?" without shipping anybody's messages anywhere.
    rep .= "`n══════ userdata (names and sizes only) ══════`n"
    try {
        Loop Files, MMA_USERDATA "\*.*"
            rep .= _LOG_Pad(A_LoopFileName, 34) " " _LOG_Pad(A_LoopFileSize, 10)
                 . " " A_LoopFileTimeModified "`n"
    }

    rep .= "`n══════ last " tailLines " log lines ══════`n"
    try {
        if FileExist(MMA_LOGFILE) {
            lines := StrSplit(FileRead(MMA_LOGFILE, "UTF-8"), "`n", "`r")
            start := Max(1, lines.Length - tailLines)
            loop (lines.Length - start + 1)
                rep .= lines[start + A_Index - 1] "`n"
        } else
            rep .= "(no log file yet — is Settings ▸ Debug ▸ logging on?)`n"
    } catch as e
        rep .= "(unreadable: " LOG_Err(e) ")`n"

    path := MMA_DEBUGLOGS "\diagnostic_report.txt"
    try {
        try FileDelete(path)
        FileAppend(rep, path, "UTF-8")
    } catch as e {
        LOGE("log.report", "could not write the report", LOG_Err(e))
        return ""
    }
    LOGI("log.report", "wrote " path " (" StrLen(rep) " chars)")
    return path
}
