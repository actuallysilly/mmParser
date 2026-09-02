#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  shortcuts.ahk — type a trigger, run an MMA action.
; ───────────────────────────────────────────────────────────────────────────────
;  Every other hotstring in MMA types a MESSAGE. These run an ACTION: the same
;  things the Actions menu lists and the same things hotkeys.ini binds keys to,
;  reached by typing instead of by a chord.
;
;  The point is that your hands are already on the keys and already in a chat box.
;  A chord has to be memorable, unused by Windows, unused by Infloww and unused by
;  the other ~90 bindings in hotkeys.ini, which is why so many actions have no key
;  at all and live only in the Actions menu — two clicks and a search box away
;  from the thing you wanted. `..overlay` has none of those constraints.
;
;  ─── ONE LIST, NOT TWO ───────────────────────────────────────────────────────
;  The right-hand side is an id out of the SAME registry the Actions menu and the
;  Hotkeys window read (HK_ORDER / HK_META in core\hotkeys.ahk). Nothing here
;  declares what MMA can do, so this file cannot drift from what MMA can do — an
;  action added anywhere becomes typeable the moment you name it, and one renamed
;  fails loudly at load instead of quietly doing nothing.
;
;  Firing is the Actions menu's own route: broadcast the action's INDEX and let
;  whichever process bound it answer (HK_Broadcast / _HK_OnFire). So a trigger
;  registered here in main_window can run the engine's follow-up key, and the
;  context gate (`when`) is still enforced by the receiver — a Discord-only action
;  typed into Infloww does nothing, exactly as the key would.
;
;  ─── WHY main_window OWNS THESE ──────────────────────────────────────────────
;  It is the one process that is always up, and it is where actions_menu.ahk
;  already lives. Registering them in more than one process would fire the action
;  once per process; hotstrings are a system-wide input hook, so one is enough
;  wherever you are typing.
;
;  ─── THE ONE THING TO WATCH: PREFIXES ────────────────────────────────────────
;  Triggers register with `*`, meaning they fire the instant they are typed with
;  no ending character — the same option __mm uses, and for the same reason: an
;  ending character would be typed into a fan's chat. The cost is that a shorter
;  trigger swallows a longer one. Define `..in` and your `..intro` message will
;  never be reached, because `..in` fired two characters earlier.
;
;  That is why the seeded file uses a prefix of its own (`..do`) rather than bare
;  words: it keeps the action triggers in a corner of the namespace the message
;  library does not use. Nothing enforces it — it is your file — but the load line
;  in the log names every trigger it registered, which is where to look when a
;  message stops expanding.
; ═══════════════════════════════════════════════════════════════════════════════

; What a line's right-hand side can say, and nothing else:
;
;   <action id>        an id from HK_ORDER — anything the Actions menu lists
;   run:<path>         launch a script or program; relative paths are from the
;                      MMA folder, so `run:tools\fansly_probe.ahk` works
;
; `run:` exists because not everything MMA can start IS an action. The probes in
; tools\ are separate processes with no registry id — launching one is exactly the
; "I need this now, mid-shift" job this file is for, and the alternative was
; opening Settings ▸ Debug to press a button.
global SC_RUN_PREFIX := "run:"

; Read the file, register every trigger. Called once at startup.
;
; Returns the number registered, for the caller's log line and for the test.
SHORTCUTS_Start() {
    global MMA_SHORTCUTS

    if !FEAT("shortcuts") {
        LOGV("shortcut.boot", "hotstring shortcuts are switched off in Settings"
                            . " ▸ Features — no triggers registered")
        return 0
    }

    SHORTCUTS_Seed()

    n := 0, names := ""
    for line in SHORTCUTS_Lines() {
        if !SHORTCUTS_Register(line.trigger, line.target)
            continue
        n++
        names .= (names = "" ? "" : " ") line.trigger
    }
    if n
        LOGI("shortcut.boot", n " hotstring shortcut(s) registered from "
                            . _LOG_BaseName(MMA_SHORTCUTS) ": " names)
    else
        LOGV("shortcut.boot", "no hotstring shortcuts defined in "
                            . _LOG_BaseName(MMA_SHORTCUTS))
    return n
}

; The file, as {trigger, target} records. Malformed lines are skipped with a
; reason rather than silently — this is a hand-edited file, and "I added a line
; and nothing happened" is the failure it will actually have.
;
; The whole SECTION is read and split here rather than asking IniRead for each
; key, because the KEY is the trigger: text you chose, containing dots, and there
; is no list of them to ask for. Same idiom as HK_HotstringTriggers and
; [ModelAliases] — see the note in HK_HotstringTriggers about why an `=` inside a
; trigger is the one thing that cannot be made to work.
SHORTCUTS_Lines() {
    global MMA_SHORTCUTS
    out := []
    if !FileExist(MMA_SHORTCUTS)
        return out
    raw := ""
    try raw := IniRead(MMA_SHORTCUTS, "Shortcuts", , "")
    catch as e {
        LOGE("shortcut.read", "could not read " MMA_SHORTCUTS " — no shortcuts are"
                            . " registered", LOG_Err(e))
        return out
    }
    for line in StrSplit(raw, "`n", "`r") {
        line := Trim(line)
        if (line = "")
            continue
        eq := InStr(line, "=")
        if !eq {
            LOGW("shortcut.read", "ignoring '" line "' — a shortcut line is"
                                . " trigger=action, and this one has no '='")
            continue
        }
        trg := Trim(SubStr(line, 1, eq - 1))
        tgt := Trim(SubStr(line, eq + 1))
        if (trg = "" || tgt = "") {
            LOGW("shortcut.read", "ignoring '" line "' — one side of the '=' is"
                                . " empty")
            continue
        }
        out.Push({trigger: trg, target: tgt})
    }
    return out
}

; Register one trigger. False when it could not be, having said why.
;
; The action id is checked HERE, at load, against the registry. An id that no
; longer exists is the predictable failure of a file that names actions by name —
; you rename an action, this file still says the old one — and the alternative to
; catching it now is a trigger that swallows your keystrokes and does nothing.
SHORTCUTS_Register(trigger, target) {
    global SC_RUN_PREFIX

    if (SubStr(target, 1, StrLen(SC_RUN_PREFIX)) != SC_RUN_PREFIX) {
        if !HK_META.Has(target) {
            LOGE("shortcut.read", "'" trigger "' names the action '" target "',"
                                . " which is not in the registry — nothing is"
                                . " registered for it. Open the Actions menu ("
                                . HK_Key("gui.actions") ") to see the real ids,"
                                . " or write run:<path> to launch a file.")
            return false
        }
    }

    ; `*X`, matching __mm in mass\runtime.ahk: fires with no ending character, so
    ; nothing extra lands in the chat box, and erases the trigger it fired on.
    ;
    ; SHORTCUTS_Fire(target), NOT `() => _SC_Run(target)`. A fat-arrow written in
    ; a loop body captures the loop's variable BY REFERENCE, so all of them would
    ; end up running whichever target the loop saw last — the trap
    ; _MassRegisterNumbered spells out and mass_bind_test pins down. A function
    ; parameter is a fresh binding every call.
    try
        Hotstring(":*X:" trigger, SHORTCUTS_Fire(target))
    catch as e {
        LOGE("shortcut.read", "could not register the trigger '" trigger "' — "
                            . LOG_Err(e))
        return false
    }
    return true
}

; The callback for one trigger, with its target baked in.
SHORTCUTS_Fire(target) {
    return (*) => _SC_Run(target)
}

_SC_Run(target) {
    global SC_RUN_PREFIX, MMA_ROOT
    if (SubStr(target, 1, StrLen(SC_RUN_PREFIX)) = SC_RUN_PREFIX) {
        _SC_Launch(Trim(SubStr(target, StrLen(SC_RUN_PREFIX) + 1)))
        return
    }

    ; The Actions menu's own route — see its ActionsDispatch and _HK_OnFire in
    ; core\hotkeys.ahk. Deliberately WITHOUT the window-activation dance that
    ; function does: the menu has to give focus back to whatever it covered, and
    ; a hotstring has taken focus from nobody. The window the action wants is the
    ; one you just typed into.
    idx := HK_IndexOf(target)
    if !idx {
        LOGE("shortcut.fire", "'" target "' is no longer in the registry — nothing"
                            . " ran. It was there when MMA started, so something"
                            . " reloaded a different version of hotkeys.ahk.")
        return
    }
    LOGI("shortcut.fire", "trigger → action '" target "' (index " idx ")")
    HK_Broadcast(HK_MSG_FIRE, idx)
}

; Launch a file. Relative paths are from the MMA folder, so a shortcuts file that
; says `run:tools\fansly_probe.ahk` keeps working on another machine.
_SC_Launch(path) {
    global MMA_ROOT
    full := path
    ; Anything without a drive letter or a leading slash is ours to resolve. A
    ; bare `notepad` is neither and stays as it is, so Run finds it on the PATH.
    if (!RegExMatch(path, "^[A-Za-z]:") && SubStr(path, 1, 1) != "\"
        && InStr(path, "\"))
        full := MMA_ROOT "\" path

    if (InStr(full, "\") && !FileExist(full)) {
        LOGE("shortcut.fire", "run:" path " — there is no file at " full
                            . ". Nothing was started.")
        return
    }
    LOGI("shortcut.fire", "trigger → run " full)
    try Run(full, MMA_ROOT)
    catch as e
        LOGE("shortcut.fire", "could not start " full, LOG_Err(e))
}

; ── the file itself ───────────────────────────────────────────────────────────
;  Written once, if it is not there, with every line commented out. A feature
;  whose config file does not exist is a feature you have to be told about; one
;  that ships a file full of worked examples is one you can find by opening it.
;
;  NOT a .default that gets copied like hotkeys.default.ini, because there is
;  nothing to seed FROM — an empty shortcuts file is a valid one, and the
;  examples are documentation rather than settings.
;
;  Never rewritten. If the file exists, whatever is in it is yours, including an
;  empty [Shortcuts] section meaning "I do not want any".
;
;  ─── PURE ASCII, UNLIKE EVERY OTHER FILE IN THIS TREE ────────────────────────
;  No box-drawing, no arrows. The .ahk sources are read by AHK, which knows they
;  are UTF-8; an ini is read by the Windows profile API, which does not, and
;  hotkeys.ini gets away with a BOM and 18 non-ASCII bytes only because they all
;  sit inside comments. This file is generated rather than hand-written, so it
;  costs nothing to be a file that cannot have an encoding problem at all.
SHORTCUTS_Seed() {
    global MMA_SHORTCUTS
    if FileExist(MMA_SHORTCUTS)
        return
    body := "
(
; =======================================================================
;  shortcuts.ini - type the trigger, MMA runs the action.
; -----------------------------------------------------------------------
;  One per line:      trigger = action
;
;  ACTION is an id from MMA's registry - the same ids the Actions menu
;  lists and hotkeys.ini binds keys to. Open the Actions menu to see them
;  all; the id is what the Hotkeys tab shows beside each row.
;
;  Or  run:<path>  to launch a file. Relative paths are from the MMA
;  folder, so the probes in tools\ work as written.
;
;  Triggers fire the INSTANT they are typed, with no space or Enter after
;  - so nothing extra lands in a fan's chat, and so a SHORT trigger will
;  swallow a longer one. The '..do' in front of each keeps them out of
;  the way of the message library. Rename them to whatever you will
;  actually type; nothing depends on the names below.
;
;  Changes need MMA restarted. Lines starting with ; are ignored.
; =======================================================================

[Shortcuts]

; -- overlays -----------------------------------------------------------
..dorail   = gui.toggleRailBadge
..dostats  = gui.toggleStats
; ..dotimers = gui.toggleReplyBox

; -- windows ------------------------------------------------------------
; ..doacts   = gui.actions
; ..doquick  = gui.quickActions
; ..dohs     = gui.hotstringMenu

; -- launch a probe, without going to Settings > Debug -------------------
; ..dodetect = run:tools\detection_overlay_debug.ahk
; ..dofansly = run:tools\fansly_probe.ahk
)"
    try {
        FileAppend(body, MMA_SHORTCUTS, "UTF-8-RAW")
        LOGI("shortcut.boot", "wrote a starter " MMA_SHORTCUTS " — two triggers are"
                            . " live, the rest are commented out")
    } catch as e
        LOGE("shortcut.boot", "could not write " MMA_SHORTCUTS, LOG_Err(e))
}
