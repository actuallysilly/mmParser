#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "theme.ahk"
#Include "hotkeys.ahk"
#Include "../hotstrings/overloads.ahk"
; HSI_Files / HSI_ParseFile, for the hotstring keys at the bottom of this file.
; A file that names a function includes the file that defines it, and AHK loads
; any given file once — so this costs nothing where index.ahk is already in the
; tree, and it is what stops "a key bound to a hotstring" being a load-time
; 'nonexistent function' in every message script.
#Include "../hotstrings/index.ahk"
; Model identity moved to its own file so the GUI can use it too — main_window
; must not include utils.ahk (hotstrings, send helpers), and calling these from
; there was a load-time error until they lived somewhere both could reach.
#Include "active_model.ahk"

SetKeyDelay(-1, -1)

; config
WaitTime     := 400
WaitTimeLong := 1500

; Which model the key that is currently firing belongs to. Declared HERE, not in
; mass/runtime.ahk, because sndFu below reads it and utils.ahk is also included by
; scripts that never load the mass engine (content\general.ahk, the account
; files) — an unset global would throw the moment one of them touched it.
;
; runtime.ahk's _SetCurModel is the only writer. This replaced `modelFileNo`,
; which MassInit(n) used to set once per process back when each model WAS a
; process; with one engine there is no per-process answer, only a per-keypress one.
global MASS_CUR_MODEL := 1


Afk := false
ClearInterval := 1000*30 ; 60s

global topChat := 300
; # Win
; ^ CTRL
; ! ALT
; + shift

; ── the one function that actually puts a message in the chat ─────────────────
;  Everything else in MMA is a decision about WHICH message; this is the send.
;
;  ClipWait is the reason it is instrumented so heavily. If the clipboard does not
;  take the text — another app owns it, a clipboard manager is holding it, the
;  text is enormous — ClipWait returns false and the very next line presses Ctrl+V
;  anyway. That does not send nothing. It sends WHATEVER WAS ON THE CLIPBOARD
;  BEFORE, into a real fan's chat, and then presses Enter. There is no way to see
;  that from the outside except by reading the sent message.
;
;  It is a FAIL rather than a warning for that reason: it is the one failure in
;  this file with a consequence you cannot take back.
Snd(arg){
    if (arg = "") {
        LOG_Bail("send.snd", "empty message — nothing sent")
        return
    }
    A_Clipboard := ""
    A_Clipboard := arg
    if !ClipWait(1) {
        LOGE("send.snd", "the clipboard never accepted the message — Ctrl+V is"
                       . " about to paste WHATEVER WAS ON THE CLIPBOARD BEFORE"
                       . " and press Enter",
                       "wanted to send: " SubStr(arg, 1, 120))
    }
    LOGI("send.snd", "sending " StrLen(arg) " chars: " SubStr(arg, 1, 90))
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

; you can also provide a time in milliseconds
Sendt(arg,time){
    if (arg = "") {
        LOG_Bail("send.sendt", "empty message — nothing sent")
        return
    }
    A_Clipboard := arg
    if !ClipWait(0.1)
        LOGE("send.sendt", "the clipboard never accepted the message in 100ms —"
                         . " about to paste the PREVIOUS clipboard and press Enter",
                         "wanted to send: " SubStr(arg, 1, 120))
    LOGI("send.sendt", "sending " StrLen(arg) " chars (wait " time "ms): "
                    . SubStr(arg, 1, 90))
    Send("^v")
    Send("{Enter}")
    Sleep(time)
}



; ── Alt follow-ups ────────────────────────────────────────────────────────────
; A follow-up may carry alternative wordings of itself. The base variant is
; fu<N>/fu<N>_5/fu<N>_7; each alt is one more complete variant, its parts joined
; by a literal `n in a single field (see main_window.ahk's MassBlockProps).
;
; Whichever variant is chosen is sent through sndFu(), so alts obey the existing
; per-group rules (FuSingle, editable) exactly like the base does.

; The counts come from store.ahk (reached via active_model.ahk above), which owns
; the record shape. They used to be ALT_MAX_RT / BRANCH_MAX_RT here, under a
; comment reading "must match ALT_MAX in main_window.ahk" — one number written
; down three times, with nothing but that comment keeping them in step.
_activeBranch := Map()   ; massNo -> chosen branch index, per model process

_altStaged  := 0         ; index of the variant currently staged
_altVariants := []       ; [{parts, label, branch}, ...] while staging; [] when idle
_altGroup   := 0         ; 1/2/3, or 0 for the PPV (which pastes, never sends)
_altEditable := false
_altWin     := 0         ; window staging began in; the hotkeys are scoped to it
_altHotkeysOn := false
_altGui     := 0         ; the picker window while staging; 0 in chat-box mode / idle
_altGuiRows := []        ; one row of controls per variant, repainted on TAB
_altGuiShown := false    ; is it on screen? false while you are in another app
_altPal     := 0         ; the theme colours this picker was built with
; Whether THIS staging pasted its preview into the chat box. Read at commit and at
; cancel to decide whether the box has to be cleared — and captured when staging
; BEGINS rather than re-read from the setting, or flipping the toggle mid-pick
; would leave the preview sitting in the composer with nothing left to remove it.
_altInBox   := false

; Called with the chosen variant's branch number the moment a staged choice is
; committed. mass/runtime.ahk installs the real one; anything that includes
; utils.ahk without the engine (content\general.ahk, the account files) leaves it
; blank and the commit simply skips it. See AltStageCommit.
global ALT_ON_PICK := ""

; Splitting a stored alt field back into its parts is MASS_SplitParts() in
; store.ahk now — it is the record format, not a send-path detail.

; ── One list of ways to answer this follow-up ─────────────────────────────────
;  Alts and branches were two features with two keys and two pickers. They are one
;  question — "which wording goes out for f<N>?" — so they are one list and one
;  key now, and TAB walks the whole thing.
;
;  The merge finished in the DATA, not just here: there are no alt fields any
;  more. Everything that is not the trunk is a named branch, and "alt" is simply
;  the name you give one when the wording has no better name — see the record
;  shape in mass/store.ahk and the `::name` marker in mass/parser.ahk. This
;  function used to concatenate two lists (alts, then branches); it now reads one,
;  and the picker looks exactly the same.
;
;  What a branch carries that a loose wording did not is the IMPLICATION: pick a
;  branch variant at f1 and f2/f3/ppv start on that same branch. That is what
;  `branch` on each variant is for, and it is now true of every alternative there
;  is — which is the point. An "alt" that answered f1 and then left you back on
;  the trunk at f2 was never a different thing, only a branch nobody had named.
;
;  Each variant is { parts, label, branch }:
;      parts   the messages to send, in order
;      label   what the staged list calls it ("main", or the branch's name)
;      branch  0 for the trunk, else which branch it commits you to
AltVariants(m, group) {
    out := []
    base := []
    for _, sfx in ["", "_5", "_7"] {
        key := "fu" group sfx
        if m.HasOwnProp(key) && Trim(m.%key%) != ""
            base.Push(Trim(m.%key%))
    }
    if base.Length
        out.Push({ parts: base, label: "main", branch: 0 })
    ; The branches, as the other ways to answer the same question. A branch with
    ; nothing in THIS group is skipped rather than shown empty — branches are
    ; commonly f1-only, and an empty row you can TAB onto and send is a way to
    ; send silence.
    for bi, b in BranchList(m) {
        if !b.fu[group].Length
            continue
        out.Push({ parts: b.fu[group], label: b.name, branch: bi })
    }
    return out
}

; The same question for the PPV: the trunk's ppv, then each branch's.
AltPpvVariants(m) {
    out := []
    if m.HasOwnProp("ppv_base") && Trim(m.ppv_base) != ""
        out.Push({ parts: [Trim(m.ppv_base)], label: "main", branch: 0 })
    for bi, b in BranchList(m) {
        if Trim(b.ppv) = ""
            continue
        out.Push({ parts: [Trim(b.ppv)], label: b.name, branch: bi })
    }
    return out
}

; ── Named branches (`::name`) ─────────────────────────────────────────────────
; A branch is a named alternative to the trunk: its own fu1/fu2/fu3/ppv, any of
; which may be empty. Picking one at f1 continues on it at f2/f3/ppv. Since the
; alt fields went, this is the ONLY kind of alternative there is — "alt" is just
; the name people give a branch that has no better one.
;
; These helpers are pure (take the mass object) so utils.ahk stays free of any
; CurMass/massNo dependency — the model files own the hotkey handlers.

; Non-empty branches on a mass: [{name, fu:[[p..],[p..],[p..]], ppv}].
BranchList(m) {
    global MASS_BRANCH_MAX
    out := []
    ; No branches means every branch key and window finds nothing to do, which is
    ; the pre-branch behaviour. Gating here rather than at each of the six call
    ; sites keeps the mass data itself untouched — switch branches back on and the
    ; `::name` wordings are still there.
    if !FEAT("altFollowups")
        return out
    Loop MASS_BRANCH_MAX {
        k  := A_Index
        f1 := "br" k "_fu1", f2 := "br" k "_fu2", f3 := "br" k "_fu3", pk := "br" k "_ppv"
        got := false
        for _, key in [f1, f2, f3, pk]
            if m.HasOwnProp(key) && Trim(m.%key%) != ""
                got := true
        if !got
            continue
        nk := "br" k "_name"
        nm := (m.HasOwnProp(nk) && Trim(m.%nk%) != "") ? Trim(m.%nk%) : "branch " k
        out.Push({ name: nm,
                   fu:   [BranchParts(m, f1), BranchParts(m, f2), BranchParts(m, f3)],
                   ppv:  (m.HasOwnProp(pk) ? Trim(m.%pk%) : "") })
    }
    return out
}
BranchParts(m, key) {
    return m.HasOwnProp(key) ? MASS_SplitParts(m.%key%) : []
}

; BranchSendGroup() and BranchSendPpv() stood here — the send half of the four
; branch keys. A branch variant goes out through SendAltVariant() like every other
; variant now, which is the point of the merge: one list, one picker, one path to
; the chatbox, so FuSingle and the editable toggles apply to a branch exactly as
; they always did to an alt.

; Send one already-chosen variant. Routed through the same two paths the base
; variant uses, so FuSingle / editable apply to alts identically.
;
; group 0 is the PPV, which has never had an Enter pressed for it — DoPpv pasted
; and left it to you. So 0 takes the paste path regardless of `editable`, or a
; staged PPV choice would send itself the moment you picked it.
SendAltVariant(group, parts, editable := false) {
    if (!editable && group > 0) {
        sndFu(group, parts*)
        return
    }
    combined := ""
    for _, p in parts
        if Trim(p) != ""
            combined .= (combined != "" ? "`n" : "") Trim(p)
    if (combined = "") {
        LOG_Bail("alt.send", "the chosen variant has no non-empty parts —"
                           . " nothing pasted")
        return
    }
    LOGI("alt.send", "pasting the chosen variant (" StrLen(combined) " chars,"
                  . " no Enter — " (group = 0 ? "PPV always pastes"
                                              : "this group is set to editable") ")")
    A_Clipboard := ""
    A_Clipboard := combined
    if !ClipWait(1)
        LOGE("alt.send", "the clipboard never accepted the chosen variant — Ctrl+V"
                       . " is about to paste the PREVIOUS clipboard",
                       "wanted to paste: " SubStr(combined, 1, 120))
    Send "^v"                      ; paste only — editable means you review first
}

; ── TAB staging ───────────────────────────────────────────────────────────────
; Show every variant with a marker on the current one, so they can be read and
; compared before one goes out. TAB moves the marker, Enter sends the marked
; variant (through sndFu, so a multi-part variant still sends as separate
; messages), Esc cancels.
;
; ─── WHERE THE PREVIEW GOES, AND WHY THAT IS THE WHOLE BUG ───────────────────
;  It went INTO THE CHAT BOX. That read beautifully — the variants in the font and
;  width they would actually send at, no window taking focus off the chat — and it
;  had one failure that costs a real message to a real person:
;
;    Enter → clear the box (Ctrl+A, Delete) → paste the chosen variant → Enter.
;
;  The clear is not reliable. Infloww's composer is a web editor, and Ctrl+A in one
;  of those does not always mean "select what is in this box" — it can be swallowed
;  outright, or select the page instead. When it misses, Delete removes nothing,
;  the preview is STILL THERE, and the chosen variant is pasted onto the end of it.
;  Then Enter sends the lot: every variant, the markers, the labels, as one message
;  to the fan. That is the "it sent the whole sequence" report.
;
;  No amount of settling delay fixes that, because the failure is not a race — it
;  is the composer refusing the keystroke. So the preview does not go in the box
;  any more. It goes in a small always-on-top window that never takes focus, and
;  the chat box is never written to and never cleared. The variants cannot be sent
;  because they were never in the thing that sends.
;
;  The chat-box preview is still here, one checkbox away (Settings → Sending,
;  "Don't use a GUI for alt FUs"), because a picker that does not draw on the
;  machine it is running on is worse than one that occasionally over-sends, and
;  that box is the way back if this window misbehaves on your setup.
;
;  What GUI mode deliberately does NOT do is clear the composer. Anything in it is
;  yours — you typed it — and it stays, which does mean a chosen variant lands
;  after text you left there. That is visible while you pick (the window sits above
;  the composer, not over it), and it is the trade that keeps the send path free of
;  the one keystroke that cannot be trusted.

; Staging separators live in mass_gui.cfg [Settings], not here:
;   AltStageVariantSep   between variants               default \n\n (a blank line)
;   AltStagePartSep      between parts of one variant   default \s\s|\s\s
;   AltStageMarker       marks the staged variant       default a filled triangle
;
; Escapes: \n newline, \t tab, \s SPACE. \s is not decoration — Windows strips
; leading and trailing whitespace when reading an ini, so a literal "  |  " comes
; back as "|" and the separator silently loses its padding.
;
; ─── WHY THE PART SEPARATOR IS "|" AND MUST NOT BE "/" ───────────────────────
;  It was "/", and that is not a cosmetic choice — it is a broken one. This text
;  is PASTED INTO THE INFLOWW COMPOSER, and "/" is Infloww's command trigger: the
;  moment the preview lands, Infloww opens its slash-command menu over the box.
;  That menu then eats the TAB and ENTER the staging depends on, so the picker
;  appears to hang and the wrong thing goes out when you finally escape it.
;
;  Any separator used here has to be inert in a chat composer. "|" is.
;
; Read per call — like sndFu reads FuSingle — so an edit applies without a restart.
ALT_SEP_UNSET := Chr(1) "«unset»"

; The original "/" separator, kept only so the migration below can recognise it.
ALT_PSEP_STALE := "\s\s/\s\s"
ALT_PSEP_DEFAULT := "\s\s|\s\s"

AltDecodeEscapes(s) {
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, "\s", " ")
    return s
}

; Seeded into the cfg on first read so the keys are discoverable by opening the
; file, rather than being invisible defaults buried in code.
AltStageSetting(key, fallback) {
    global ALT_SEP_UNSET
    cfg := MMA_CFG
    v := IniRead(cfg, "Settings", key, ALT_SEP_UNSET)
    if (v == ALT_SEP_UNSET) {
        try IniWrite(fallback, cfg, "Settings", key)
        v := fallback
    }
    return AltDecodeEscapes(v)
}

; Replace the ORIGINAL "/" part separator with "|", once.
;
; Changing the fallback above does nothing on its own. AltStageSetting SEEDS the
; cfg the first time it reads a key, so every machine where a choice has ever been
; staged already has `AltStagePartSep=\s\s/\s\s` written to disk — and a stored
; value always wins over the fallback. Without this, the fix would only reach
; brand-new installs, and the machines with the bug would keep it forever.
;
; ONLY the untouched original is replaced. A value somebody deliberately set is
; left exactly as it is, slash or not — if they want it, that is their call, and
; silently overwriting a customised setting is its own kind of bug.
AltStageMigrateSep() {
    global ALT_SEP_UNSET, ALT_PSEP_STALE, ALT_PSEP_DEFAULT
    static done := false
    if done
        return
    done := true
    try {
        v := IniRead(MMA_CFG, "Settings", "AltStagePartSep", ALT_SEP_UNSET)
        if (v == ALT_SEP_UNSET)
            return                      ; never seeded — the fallback is correct already
        if (Trim(v) != ALT_PSEP_STALE)
            return                      ; customised — hands off
        IniWrite(ALT_PSEP_DEFAULT, MMA_CFG, "Settings", "AltStagePartSep")
        LOGI("alt.stage", "migrated AltStagePartSep from '" ALT_PSEP_STALE "' to '"
                        . ALT_PSEP_DEFAULT "' — a '/' in the staged preview opens"
                        . " Infloww's slash-command menu and swallows TAB/ENTER")
    }
}

AltStageText() {
    global _altVariants, _altStaged, ALT_PSEP_DEFAULT
    AltStageMigrateSep()
    vsep := AltStageSetting("AltStageVariantSep", "\n\n")
    psep := AltStageSetting("AltStagePartSep",    ALT_PSEP_DEFAULT)
    mk   := AltStageSetting("AltStageMarker",     Chr(0x25B8))
    pad  := ""
    Loop StrLen(mk) + 1
        pad .= " "
    out := ""
    for i, v in _altVariants {
        mark := (i = _altStaged) ? mk " " : pad
        body := ""
        for _, p in v.parts
            body .= (body != "" ? psep : "") p
        ; The label earns its place: "main" is obvious from position, but which
        ; BRANCH you are about to commit to is not, and committing to the wrong one
        ; silently redirects the next two follow-ups.
        out .= (out != "" ? vsep : "") mark (v.branch ? "[" v.label "] " : "") body
    }
    return out
}

AltPaintChatbox() {
    A_Clipboard := ""
    A_Clipboard := AltStageText()
    ; Ctrl+A then Ctrl+V follows, so a clipboard that did not take the preview
    ; SELECTS THE WHOLE CHAT BOX AND REPLACES IT with the previous clipboard.
    ; Nothing has been sent at this point, but the box now contains something the
    ; user did not put there and did not ask for.
    if !ClipWait(1)
        LOGE("alt.stage", "the clipboard never accepted the staged preview — the"
                        . " chat box is about to be overwritten with the PREVIOUS"
                        . " clipboard instead")
    Send "^a"
    Sleep 20
    Send "^v"
}

; Draw the current state, whichever way this staging is showing itself.
AltPaintStage() {
    global _altInBox
    if _altInBox
        AltPaintChatbox()
    else
        AltGuiPaint()
}

; ── the picker window ─────────────────────────────────────────────────────────
;  Small, always on top, and WS_EX_NOACTIVATE so it NEVER takes focus: the chat
;  window has to stay active or the Tab/Enter/Escape hotkeys — which are scoped to
;  it — stop firing, and you would be left with a window you cannot dismiss.
;  Same reason the stats overlay and the OCR region sheets carry that style.
;
;  ─── THE PALETTE ────────────────────────────────────────────────────────────
;  Not here — core/theme.ahk, because the main window needs the same answer and it
;  is a different process. THEME_Picker() returns all eight colours at once; see
;  that file for why they are what they are.
;
;  Fetched ONCE per window, into _altPal, rather than per control. Reading the
;  theme again on each repaint would mean a theme switched mid-pick redraws half
;  the rows in the new palette and half in the old.

; No more of a variant than fits a glance. A follow-up is a chat message, so this
; is generous — but a mass field with a whole script pasted into it would push the
; window off the screen, and the marked row is what matters, not the last 400
; characters of the one below it.
ALT_GUI_MAXCHARS := 320

; Build the window, or repaint it if it is already up. Called on every TAB.
AltGuiPaint() {
    global _altGui
    if _altGui
        AltGuiRepaint()
    else
        AltGuiBuild()
}

; Everything that can go wrong here is cosmetic except one thing: if the window
; fails to appear, the keys are still claimed and there is nothing on screen
; saying so — a picker you cannot see, eating Enter in the chat. So a failure to
; build falls back to the chat-box preview rather than leaving that state.
AltGuiBuild() {
    global _altGui, _altGuiRows, _altVariants, _altStaged, _altGroup, _altInBox
    global _altPal
    try {
        _altPal := THEME_Picker()
        pal := _altPal
        w := _IniInt(MMA_CFG, "Settings", "AltGuiWidth", 560)
        if (w < 260)
            w := 260
        ; -DPIScale below means w is real pixels, and the FONT is still sized by
        ; the display — so a fixed 560 on a 150% screen is two thirds the window
        ; with the same size text crammed into it. Scaling the width the way the
        ; text scales keeps the shape of the thing the same everywhere. The ini
        ; value is therefore "how wide at 100%".
        w := w * A_ScreenDPI // 96
        tw := w - 24                      ; text width inside the margins
        ; -DPIScale is load-bearing, not tidiness. With scaling ON, AHK reports
        ; control positions in LOGICAL units while the window is created in
        ; PHYSICAL pixels, so on a 125% display the rows render 1.25× further down
        ; than the measurements say and the window comes out a quarter too short —
        ; the bottom variant and the key hints are simply cut off the end of it.
        ; (Measured: rows 67 apart by GetPos, 86 apart on screen.) Off, every number
        ; here — GetPos, Show's w/h, and WinGetPos on the chat window — is in the
        ; same physical pixels, and the box fits what is in it on any display.
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000",
                 "MMA pick")
        g.BackColor := pal.bg
        g.MarginX := 12, g.MarginY := 10
        g.SetFont("s9", "Segoe UI")

        g.SetFont("s9 Bold c" pal.hint)
        g.Add("Text", "xm ym w" tw,
              (_altGroup = 0 ? "PPV" : "Follow-up " _altGroup)
            . "  —  " _altVariants.Length " ways to answer this")
        g.SetFont("s9 Norm")

        _altGuiRows := []
        for i, v in _altVariants {
            bg := (i = _altStaged) ? pal.sel : pal.row
            ; A row is four controls, not one, so the marked one reads as a band:
            ; a pad, the label, the text, a pad — each carrying the row's colour.
            ; Gaps BETWEEN rows are the window background, which is what separates
            ; them; that is why only the label has a y offset.
            padT := g.Add("Text", "xm y+8 w" tw " h5 Background" bg, "")
            g.SetFont("s8 Bold")
            head := g.Add("Text", "xm y+0 w" tw " Background" bg, AltGuiHead(i, v))
            g.SetFont("s9 Norm")
            body := g.Add("Text", "xm y+2 w" tw " Background" bg, AltGuiBody(v))
            padB := g.Add("Text", "xm y+0 w" tw " h6 Background" bg, "")
            _altGuiRows.Push({head: head, body: body, ctrls: [padT, head, body, padB]})
        }

        g.SetFont("s8 c" pal.hint)
        hint := g.Add("Text", "xm y+10 w" tw,
                      "TAB next     SHIFT+TAB back     ENTER send     ESC cancel")

        _altGui := g
        AltGuiRepaint()                   ; sets the marked row's text colours
        ; The height is measured off the last control rather than left to AutoSize,
        ; which came up short: the bottom row's text and the hint line above were
        ; clipped clean off the window. Clipping the LAST ROW is not cosmetic — TAB
        ; wraps onto a variant you cannot see, and Enter sends it.
        ;
        ; The controls exist as soon as they are added, so this measures for real
        ; rather than predicting; -Caption means there is no title bar or border, so
        ; the client height IS the window height.
        hint.GetPos(, &hy, , &hh)
        gh := hy + hh + g.MarginY
        LOGD("alt.stage", "picker window " w "x" gh " for " _altVariants.Length
                       . " variants, marker on " _altStaged)
        AltGuiShowPlaced(g, w, gh)
    } catch as e {
        LOGE("alt.stage", "the picker window would not build — falling back to the"
                        . " chat-box preview for this pick",
                        "error: " e.Message " @ " e.File ":" e.Line
                      . (e.HasProp("What") && e.What != "" ? " in " e.What : ""))
        _altGui := 0
        _altGuiRows := []
        _altInBox := true
        AltPaintChatbox()
    }
}

; The label line: the marker, the number, what it is called, and — only when it
; matters — that picking it commits the next follow-ups to a branch.
AltGuiHead(i, v) {
    global _altStaged
    return ((i = _altStaged) ? Chr(0x25B8) : " ") "  " i ".  " v.label
         . (v.branch ? "      (branch — f2 and f3 will open here)" : "")
}

; One part per line. The chat-box preview has to squeeze them onto one line with a
; separator; a window has room to show them the way they will actually arrive,
; which is as separate messages.
AltGuiBody(v) {
    global ALT_GUI_MAXCHARS
    out := ""
    for _, p in v.parts {
        p := Trim(p)
        if (p = "")
            continue
        out .= (out != "" ? "`n" : "") p
    }
    if (StrLen(out) > ALT_GUI_MAXCHARS)
        out := SubStr(out, 1, ALT_GUI_MAXCHARS) " …"
    return out = "" ? "(empty)" : out
}

; Move the marker without rebuilding: the variants have not changed, only which
; one is lit, and destroying the window on every TAB flickers it across the chat.
AltGuiRepaint() {
    global _altGui, _altGuiRows, _altVariants, _altStaged, _altPal
    if !_altGui
        return
    ; The palette this window was BUILT with, not whatever the cfg says now — a
    ; theme saved mid-pick would otherwise repaint the marked row in the new
    ; colours and leave every other row in the old ones.
    pal := _altPal ? _altPal : THEME_Picker()
    for i, row in _altGuiRows {
        sel := (i = _altStaged)
        for _, c in row.ctrls
            c.Opt("+Background" (sel ? pal.sel : pal.row))
        row.head.SetFont("c" (sel ? pal.selHead : pal.head))
        row.body.SetFont("c" (sel ? pal.selBody : pal.body))
        row.head.Text := AltGuiHead(i, _altVariants[i])
        for _, c in row.ctrls
            c.Redraw()
    }
}

; Show it over the chat it belongs to, above the composer rather than on it.
;
; One Show, with the size passed in. NoActivate is not optional: a Show without it
; hands focus over, the chat window stops being active, and the Tab/Enter/Escape
; hotkeys — scoped to that window — go dead with the picker still up.
AltGuiShowPlaced(g, gw, gh) {
    global _altWin, _altGuiShown
    ; Anchor to the window staging began in. Falls back to the primary screen when
    ; that window has gone away, which beats drawing at 0,0.
    ax := 0, ay := 0, aw := A_ScreenWidth, ah := A_ScreenHeight
    try WinGetPos(&ax, &ay, &aw, &ah, "ahk_id " _altWin)
    lift := _IniInt(MMA_CFG, "Settings", "AltGuiLift", 150)
    x := ax + (aw - gw) // 2
    y := ay + ah - gh - lift
    AltGuiClamp(x + gw // 2, y + gh // 2, gw, gh, &x, &y)
    g.Show("NoActivate x" x " y" y " w" gw " h" gh)
    _altGuiShown := true
}

; Keep the whole window on the monitor it landed on. A tall list lifted off the
; bottom of a maximised window can run off the top of the screen, and the row you
; cannot see is the one Enter is about to send.
AltGuiClamp(cx, cy, gw, gh, &x, &y) {
    ml := 0, mt := 0, mr := A_ScreenWidth, mb := A_ScreenHeight
    try {
        found := false
        Loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            if (cx >= l && cx < r && cy >= t && cy < b) {
                ml := l, mt := t, mr := r, mb := b
                found := true
                break
            }
        }
        if !found
            MonitorGetWorkArea(MonitorGetPrimary(), &ml, &mt, &mr, &mb)
    }
    if (x + gw > mr)
        x := mr - gw
    if (x < ml)
        x := ml
    if (y + gh > mb)
        y := mb - gh
    if (y < mt)
        y := mt
}

AltGuiClose() {
    global _altGui, _altGuiRows, _altGuiShown, _altPal
    if _altGui {
        try _altGui.Destroy()
        _altGui := 0
    }
    _altGuiRows := []
    _altGuiShown := false
    ; Dropped with the window, so the NEXT pick reads the theme fresh — that is
    ; what makes switching theme in Settings apply without restarting the engine.
    _altPal := 0
}

; ── the picker must never outlive the chat it belongs to ──────────────────────
;  Tab, Enter and Escape are scoped to the window staging began in. That is the
;  right scope — they must not be hijacked machine-wide — but it has a hole, and
;  it is nasty: switch away from the chat and ESCAPE STOPS REACHING THE PICKER.
;  You are then looking at an always-on-top window, over another application, with
;  no title bar, no close button, and a key that does nothing. The 45-second
;  timeout eventually clears it, which is a long time to sit there wondering.
;
;  So while a choice is staged, this runs four times a second and:
;
;    the chat window is GONE      → end the staging. There is nothing left to send
;                                   into, so the picker has no subject.
;    the chat window is not ACTIVE → hide the picker, keep the staging. You alt-
;                                   tabbed; come back and it is where you left it,
;                                   marker and all. Meanwhile it is not floating
;                                   over whatever you switched to.
;    active again                 → show it again, same position.
ALT_STAGE_WATCH_MS := 250

AltStageWatch() {
    global _altVariants, _altWin, _altGui, _altGuiShown
    if !_altVariants.Length
        return
    if (!_altWin || !WinExist("ahk_id " _altWin)) {
        LOGI("alt.stage", "the window this pick belongs to has closed — ending the"
                        . " staging rather than leaving a picker on top of nothing")
        AltStageEnd()
        return
    }
    if !_altGui
        return
    want := WinActive("ahk_id " _altWin) ? true : false
    if (want = _altGuiShown)
        return
    _altGuiShown := want
    ; NoActivate on the way back too, or returning to the chat would hand focus to
    ; the picker and kill the very hotkeys it is waiting for.
    try (want ? _altGui.Show("NoActivate") : _altGui.Hide())
}

; Chat-box preview, or the window? Read per press like every other staging
; setting, so the checkbox in Settings applies to the very next follow-up key
; without restarting anything.
AltStageUseGui() {
    return Trim(IniRead(MMA_CFG, "Settings", "AltStageNoGui", "0")) != "1"
}

; Tab/Enter/Escape are hijacked while a choice is staged, so they must be scoped
; hard. Two guards: HotIf restricts them to the window staging began in AND to
; the staged state, and a timeout cancels a forgotten staging. Without these a
; stray Enter hook would swallow Enter in every application on the machine.
ALT_STAGE_TIMEOUT_MS := 45000

; The (*) is required, not stylistic: HotIf calls its criterion with the hotkey
; name, and a zero-parameter function is rejected with "Invalid callback function."
; That is why hotkeys.ahk declares every context as (*) => ... too.
;
; The picker window is in the criterion too, and that is a safety net rather than
; a feature: it is WS_EX_NOACTIVATE and should never be the active window, but if
; anything ever does activate it, without this line Escape stops working and the
; only way out of a window with no title bar is the timeout below.
AltStageActive(*) {
    global _altVariants, _altWin, _altGui
    if !_altVariants.Length
        return false
    if (_altWin && WinActive("ahk_id " _altWin))
        return true
    return _altGui && WinActive("ahk_id " _altGui.Hwnd)
}

; `startAt` is which variant the marker opens on. Not always 1: once you have
; picked a branch at f1, f2 opens on THAT branch, so walking a branch is press-
; Enter, press-Enter, press-Enter rather than TAB-hunting for the same name three
; times. TAB still reaches every other variant, so nothing is locked in.
AltStageBegin(group, variants, editable := false, startAt := 1) {
    global _altVariants, _altStaged, _altGroup, _altEditable, _altHotkeysOn
    global _altWin, _altInBox, ALT_STAGE_TIMEOUT_MS, ALT_STAGE_WATCH_MS
    _altVariants := variants
    _altStaged   := (startAt >= 1 && startAt <= variants.Length) ? startAt : 1
    _altGroup    := group
    _altEditable := editable
    ; Before the window exists, so this is the CHAT window and not the picker.
    _altWin      := WinExist("A")
    _altInBox    := !AltStageUseGui()
    AltPaintStage()
    if !_altHotkeysOn {
        HotIf AltStageActive
        ; *Tab fires on Shift+Tab too — the wildcard ignores extra modifiers — so
        ; walking backwards needs its own binding. An exact modifier match wins
        ; over a wildcard one, so +Tab reaches AltStagePrev and plain Tab does not.
        Hotkey "*Tab",    AltStageNext,   "On"
        Hotkey "*+Tab",   AltStagePrev,   "On"
        Hotkey "*Enter",  AltStageCommit, "On"
        Hotkey "*Escape", AltStageCancel, "On"
        HotIf
        _altHotkeysOn := true
    }
    SetTimer(AltStageTimeout, -ALT_STAGE_TIMEOUT_MS)
    SetTimer(AltStageWatch, ALT_STAGE_WATCH_MS)
}

; Give up rather than leave the keys claimed. In chat-box mode the staged text is
; left in the box — it is the user's chat window, so silently wiping it would be
; worse. The picker window closes, because a window with no title bar that has
; stopped responding to Escape is not something to leave lying on top of the chat.
;
; A forgotten staging gives the keys back on its own. Worth a WARN: while staged,
; Tab, Enter and Escape are hijacked in the staging window, so a user who walked
; away mid-pick and came back to "Enter does not work in my chat" is looking at
; this, and the timeout is what fixed it before they finished typing the message.
AltStageTimeout() {
    global _altVariants, _altInBox, ALT_STAGE_TIMEOUT_MS
    if _altVariants.Length {
        LOGW("alt.stage", "timed out after " ALT_STAGE_TIMEOUT_MS "ms with a choice"
                        . " still staged — releasing Tab/Enter/Escape."
                        . (_altInBox ? " The staged text is left in the chat box on"
                                     . " purpose." : " The picker window is closed."))
        AltStageEnd()
    }
}

AltStageEnd() {
    global _altVariants, _altStaged, _altGroup, _altWin, _altHotkeysOn, _altInBox
    SetTimer(AltStageTimeout, 0)
    SetTimer(AltStageWatch, 0)
    if _altHotkeysOn {
        HotIf AltStageActive
        Hotkey "*Tab",    "Off"
        Hotkey "*+Tab",   "Off"
        Hotkey "*Enter",  "Off"
        Hotkey "*Escape", "Off"
        HotIf
        _altHotkeysOn := false
    }
    ; After the hotkeys are released, so the window cannot outlive them: a picker
    ; still on screen with Tab and Enter handed back is a window that ignores you.
    AltGuiClose()
    _altVariants := []
    _altStaged := 0
    _altGroup := 0
    _altWin := 0
    _altInBox := false
}

AltStageNext(*) {
    global _altVariants, _altStaged
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    _altStaged := Mod(_altStaged, _altVariants.Length) + 1
    AltPaintStage()
}

; Shift+Tab. Wraps the other way, so the list has no ends to get stuck against.
AltStagePrev(*) {
    global _altVariants, _altStaged
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    _altStaged := Mod(_altStaged - 2 + _altVariants.Length, _altVariants.Length) + 1
    AltPaintStage()
}

AltStageCommit(*) {
    global _altVariants, _altStaged, _altGroup, _altEditable, _altInBox, ALT_ON_PICK
    if !_altVariants.Length {
        AltStageEnd()
        return
    }
    v     := _altVariants[_altStaged]
    grp   := _altGroup
    edit  := _altEditable
    LOGI("alt.stage", "committed variant " _altStaged " of " _altVariants.Length
                   . " — '" v.label "'"
                   . (v.branch ? "  (this commits the conversation to branch "
                               . v.branch ", so f2/f3 will open on it)" : "")
                   . "  group=" (grp = 0 ? "ppv" : grp)
                   . "  parts=" v.parts.Length
                   . "  shown=" (_altInBox ? "chat box" : "picker window"))
    ; Only the chat-box preview needs clearing, and only because it is sitting in
    ; the thing that is about to send. This is the unreliable step the picker
    ; window exists to avoid — see the section header — so it runs on exactly the
    ; mode that cannot do without it, and never on the one that can.
    if _altInBox {
        Send "^a"
        Sleep 20
        Send "{Delete}"
    }
    AltStageEnd()
    ; Tell the engine which branch this commits to, BEFORE sending — so if the send
    ; throws, the next follow-up still knows where the conversation went.
    ;
    ; A callback rather than a direct call: remembering a branch needs the mass
    ; document and the active model, which live in mass/runtime.ahk, and utils.ahk
    ; is also included by content\general.ahk and the account files, which never
    ; load the engine. Calling _BranchKey() from here would throw in those.
    if ALT_ON_PICK
        try ALT_ON_PICK.Call(v.branch)
    ; The send edges, by hand, because THIS send does not come through _HK_Fire.
    ; Enter is a hotkey AltStageBegin registered directly, so nothing in
    ; hotkeys.ahk knows a message is about to go out — and a staged variant is a
    ; multi-part follow-up like any other, with the same second of exposure to a
    ; click on the next conversation. Missing it here would leave the one send
    ; path that involves a deliberate pause as the only unguarded one.
    HK_SendBegin()
    try
        SendAltVariant(grp, v.parts, edit)
    finally
        HK_SendEnd()
}

AltStageCancel(*) {
    global _altInBox
    ; Escape means "put it back how it was". In the window there is nothing to put
    ; back — the chat box was never written to — so clearing it would DELETE
    ; whatever the user had typed there, which Escape has no business doing.
    LOGI("alt.stage", "cancelled with Escape — nothing sent"
                   . (_altInBox ? ", chat box cleared"
                                : "; the chat box was never touched"))
    if _altInBox {
        Send "^a"
        Sleep 20
        Send "{Delete}"
    }
    AltStageEnd()
}

; AltChooseGui() stood here — a modal window listing the variants, opened when a
; mass had "alt: gui" ticked, plus ArchiveDarkThemeRT() to theme it and
; AltChooserActive()/_altChooserHwnd to scope its 1-9 keys. It was the second way
; to answer the same question, and TAB staging is the one that got used: you read
; the variants in the chatbox, in the font and width they will actually send at,
; without a window taking focus off the chat. All of it is gone.
;
; The `altGui` field survives in the record (store.ahk) and its checkbox survives
; in the alt window; both are now inert. Left rather than migrated away because
; dropping a field rewrites every mass on next save, and this is not worth that.

; ── entry point used by the mass scripts ──────────────────────────────────────
; Returns true if the staging took over the send, false to fall through to the
; plain send.
;
; ONE KEY. There is no ctrl-variant to press and no "prompt using ctrl+hotkey"
; setting any more: if this follow-up can be answered more than one way, the key
; stages the choices and TAB walks them. If it cannot — no alts, no branches —
; the key sends, exactly as it always did, and the staging never appears.
;
; `activeBranch` is which branch an earlier follow-up in this conversation
; committed to, or 0. It only picks where the marker STARTS.
AltIntercept(m, group, editable := false, activeBranch := 0) {
    ; One gate for every caller. Returning false means "nothing intercepted", so
    ; the plain send runs exactly as it did before alts existed — which is what
    ; Easy mode is: a follow-up key that sends the follow-up, full stop.
    if !FEAT("altFollowups") {
        LOG_Bail("alt.intercept", "feature 'altFollowups' is off — follow-up "
                                . group " sends its main wording, no picker")
        return false
    }
    variants := AltVariants(m, group)
    if (variants.Length <= 1) {
        ; The commonest confused report about this feature: "the alt picker did
        ; not come up". With one variant there is nothing to pick BETWEEN, so it
        ; correctly sends straight away — which is indistinguishable from the
        ; feature being broken unless something says so.
        LOG_Bail("alt.intercept", "follow-up " group " has " variants.Length
                                . " variant(s) — nothing to choose between, so it"
                                . " sends directly with no picker")
        return false
    }
    names := ""
    for _, v in variants
        names .= (names = "" ? "" : ", ") v.label (v.branch ? "*" : "")
    LOGI("alt.intercept", "follow-up " group ": staging " variants.Length
                       . " variants [" names "] — TAB to walk, Enter to send,"
                       . " Esc to cancel")
    AltStageBegin(group, variants, editable, AltStartIndex(variants, activeBranch))
    return true
}

; The same, for the PPV. Separate entry point only because the PPV has no group
; number and pastes rather than sends; the list and the walk are identical.
AltInterceptPpv(m, editable := true, activeBranch := 0) {
    if !FEAT("altFollowups") {
        LOG_Bail("alt.ppv", "feature 'altFollowups' is off — PPV pastes its main"
                          . " wording, no picker")
        return false
    }
    variants := AltPpvVariants(m)
    if (variants.Length <= 1) {
        LOG_Bail("alt.ppv", "PPV has " variants.Length " variant(s) — nothing to"
                          . " choose between, pasting directly")
        return false
    }
    LOGI("alt.ppv", "staging " variants.Length " PPV variants")
    AltStageBegin(0, variants, editable, AltStartIndex(variants, activeBranch))
    return true
}

; Which variant to open on: the one belonging to the branch already in play, or
; the first. Falls back to 1 when that branch has nothing in this group, which is
; the normal case for an f1-only branch reaching f2.
AltStartIndex(variants, activeBranch) {
    if !activeBranch
        return 1
    for i, v in variants
        if (v.branch = activeBranch)
            return i
    return 1
}

sndFu(group, parts*) {
    global waitTime, MASS_CUR_MODEL
    nonEmpty := []
    for p in parts
        if Trim(p) != ""
            nonEmpty.Push(p)
    ; THE most reported "the key did nothing": the mass has no text in this slot.
    ; Masses are legitimately sparse — f1-only and f1+f3 are both normal — so this
    ; is correct behaviour and not a fault. It is still the answer to the question,
    ; so it says which model and which follow-up was empty.
    if !nonEmpty.Length {
        LOG_Bail("send.fu", "model " MASS_CUR_MODEL " follow-up " group " is EMPTY"
                          . " in the selected mass — nothing to send. (Sparse masses"
                          . " are normal; check the mass in the GUI if you expected text.)")
        return
    }
    ; FuSingle_<model>_<group>. The model number must be the one whose key was
    ; pressed — read from the wrong one and IniRead just returns its default, so
    ; the setting appears to do nothing and nothing says why.
    fuSingle := IniRead(MMA_CFG, "Settings",
                        "FuSingle_" MASS_CUR_MODEL "_" group, "0") = "1"
    LOGI("send.fu", "model " MASS_CUR_MODEL " follow-up " group ": " nonEmpty.Length
                 . " part(s), " (fuSingle ? "joined into ONE message (FuSingle_"
                                          . MASS_CUR_MODEL "_" group "=1)"
                                          : "sent as separate messages"))
    if !fuSingle {
        for p in nonEmpty
            snd(p)
        return
    }
    combined := ""
    for p in nonEmpty
        combined .= (combined != "" ? "`n" : "") p
    A_Clipboard := ""
    A_Clipboard := combined
    if !ClipWait(1)
        LOGE("send.fu", "the clipboard never accepted follow-up " group " — about to"
                      . " paste the PREVIOUS clipboard and press Enter",
                      "wanted to send: " SubStr(combined, 1, 120))
    Send("^v")
    Send("{Enter}")
    Sleep(waitTime)
}

; ── message overloading ───────────────────────────────────────────────────────
; A few hotstrings send ONE OF several variants instead of a fixed message. The
; owning script hands its variants to Overload_Run; this layer only decides WHICH
; one goes out and sends it:
;     "random" → pick one at random, no prompt
;     "ask"    → a small chooser pops up (click a row, or press 1-9; Esc cancels)
; Mode lives in mass_gui.cfg [Hotstrings] OverloadMode (default "ask"), editable
; from the Hotstrings manager. A "variant" is an array of steps, each {fn, text}
; — the same shape the manager reads from source (fn "snd" = sends + Enter,
; "SendText" = pastes only). See the hotstring-manager notes.

; MMA_CFG, not `HK_DIR "\mass_gui.cfg"`. HK_DIR is the REPO ROOT (hotkeys.ahk
; sets it there so HK_Broadcast can recognise our scripts by title), and no cfg
; has ever lived in the root — so this read every setting out of a file that does
; not exist and returned the default "ask" forever, exactly the silent revert
; paths.ahk was written to stop.
Overload_Mode() {
    return StrLower(Trim(IniRead(MMA_CFG, "Hotstrings", "OverloadMode", "ask")))
}

; Entry point an overloaded hotstring calls. `mode` is that trigger's own "ask" or
; "random" (each overload carries its own); blank falls back to the global default.
Overload_Run(variants, mode := "") {
    if !variants.Length {
        LOG_Bail("overload", "an overloaded hotstring fired with NO variants —"
                           . " nothing to send. Its entry in hotstring_overloads.ini"
                           . " is probably empty or malformed.")
        return
    }
    labels := []
    for v in variants
        labels.Push(Overload_Label(v))
    idx := Overload_Pick(labels, mode)
    if (idx >= 1 && idx <= variants.Length) {
        LOGI("overload", "chose variant " idx " of " variants.Length
                      . " (mode " (mode = "" ? Overload_Mode() : mode) ")")
        Overload_Send(variants[idx])
        return
    }
    ; Esc in the chooser lands here, and so does an out-of-range pick. Both mean
    ; the hotstring's trigger text has already been swallowed and nothing replaced
    ; it — which reads as the hotstring being broken.
    LOG_Bail("overload", "no variant chosen (cancelled, or index " idx " is out of"
                       . " range 1-" variants.Length ") — nothing sent")
}

; Which variant (1-based)? 0 = none/cancelled. `mode` blank → read the setting;
; passed explicitly only so it's testable without touching the cfg.
Overload_Pick(labels, mode := "") {
    n := labels.Length
    if (n <= 1)
        return n
    if (mode = "")
        mode := Overload_Mode()
    if (mode = "random")
        return Random(1, n)
    return Overload_Choose(labels)
}

Overload_Send(steps) {
    for st in steps {
        if (StrLower(st.fn) = "sendtext")
            SendText(st.text)
        else
            snd(st.text)
    }
}

; One-line preview of a variant, for the chooser rows.
Overload_Label(steps) {
    s := ""
    for st in steps
        s .= (s = "" ? "" : "   /   ") st.text
    return SubStr(StrReplace(StrReplace(s, "`r", " "), "`n", " "), 1, 72)
}

; Re-point THIS script's overloaded triggers at the engine. Runs once at load (see
; the call below), so no message file ever needs a registration line added: each
; script picks up only the overloads whose owning file matches its own name, and a
; runtime Hotstring() replaces the statically defined trigger.
Overload_Register() {
    n := 0, skipped := 0
    for trg, e in OL_Load() {
        if (StrLower(OL_BaseName(e.file)) != StrLower(A_ScriptName)) {
            skipped++
            continue
        }
        ; A trigger that fails to register here keeps its STATIC definition, so it
        ; still fires — it just sends the one fixed message instead of offering
        ; the variants. "My overload stopped asking" with no error is exactly that.
        ;
        ; ent/name are NOT redundant. A fat-arrow closure does not capture a FOR
        ; LOOP's variables: read `e` or `trg` from inside the lambda and it throws
        ; "This local variable has not been assigned a value" at call time, so
        ; every overload fails to register and the picker silently stops
        ; appearing. Ordinary locals capture correctly, so copy them out first.
        ; (Renaming the loop variable does not help — it is the for-loop binding,
        ; not the name.)
        ent := e, name := trg
        LOG_Try("overload.register", "register " name,
                () => Hotstring(":" ent.options ":" name, Overload_Handler.Bind(ent)), &ok)
        if ok
            n++
    }
    if n
        LOGI("overload.register", n " overloaded hotstring(s) re-pointed at the"
                              . " picker (" skipped " belong to other scripts)")
    else
        LOGV("overload.register", "no overloads own this script (" skipped
                                . " belong to others)")
}

Overload_Handler(entry, *) {
    Overload_Run(entry.variants, entry.mode)
}

; Blocking chooser. Returns the picked index (1-based) or 0 if cancelled.
Overload_Choose(labels) {
    picked := 0
    cg := Gui("+AlwaysOnTop +ToolWindow +Owner", "Pick a variant")
    cg.BackColor := "1B1A24"
    cg.SetFont("s10 cE6E4EE", "Segoe UI")
    cg.MarginX := 14, cg.MarginY := 12
    for i, lab in labels {
        opt := (i = 1) ? "w560 h34" : "w560 h34 y+8"
        btn := cg.Add("Button", opt, i "     " lab)
        btn.OnEvent("Click", PickThis.Bind(i))
    }
    cg.OnEvent("Escape", PickNone)
    cg.OnEvent("Close",  PickNone)
    cg.Show()
    WinWaitClose("ahk_id " cg.Hwnd)
    return picked

    PickThis(i, *) {
        picked := i
        cg.Destroy()
    }
    PickNone(*) {
        picked := 0
        cg.Destroy()
    }
}

; Wire up whatever overloads this script owns (a no-op for scripts that own none).
Overload_Register()

; ═══════════════════════════════════════════════════════════════════════════════
;  A KEY FOR A HOTSTRING
; ───────────────────────────────────────────────────────────────────────────────
;  Some messages go out so often that typing the trigger is the slow part. This
;  binds a key to one, optionally, per hotstring — the trigger keeps working
;  exactly as it did, and the key is a second way to fire the same thing.
;
;  It is also the sanctioned version of something that was already happening.
;  content\accounts\TEMP.ahk has had bare `!9::` and `!8::` blocks written
;  straight into it, each sending one message: a hotkey that is neither data nor
;  declared in hotkeys.ini, invisible to the Hotkeys tab, invisible to the
;  conflict report, and lost the moment that file is tidied. TEMP.ahk's own
;  header comment says as much about the `!1::` that came before them. Same
;  capability, in the ini, where every other key in MMA lives.
;
;  ─── THE MESSAGE IS NEVER COPIED ─────────────────────────────────────────────
;  The binding stores a TRIGGER and a KEY. Nothing else. What gets sent is read
;  from the .ahk source at load, through the same index the Hotstrings window
;  uses, so editing a message updates the key's message too — there is one copy
;  of your words and it is the one you wrote. Storing the text alongside the
;  binding would have been less code and would drift the first time you reworded
;  something.
;
;  ─── AND NEITHER IS THE SENDING ──────────────────────────────────────────────
;  The handler goes through Overload_Run, the same path the trigger takes. So an
;  overloaded hotstring bound to a key still asks (or still picks at random) —
;  the key does what the trigger does, rather than what the trigger did before it
;  was overloaded. A plain hotstring is one variant, which Overload_Pick sends
;  without asking.
;
;  ─── SCOPE: GLOBAL, LIKE THE HOTSTRING ───────────────────────────────────────
;  No window context. A hotstring fires wherever you type, so a key that stands
;  in for one fires wherever you press it — the alternative is a key that works
;  in Infloww and mysteriously does nothing in Discord. The cost is real and is
;  worth stating: `!9` bound to a message will send that message in whatever
;  window has focus. Pick chords you would not otherwise press.
HotstringKeys_Register() {
    binds := HK_HotstringTriggers()
    if !binds.Length
        return

    ; Only THIS script's own hotstrings, and only its own file is read. Each
    ; message script is a separate process that owns its own triggers, exactly as
    ; Overload_Register works — and a script that binds a key for a trigger it
    ; does not define would send nothing while quietly claiming the key from the
    ; script that does.
    rel := ""
    for f in HSI_Files()
        if (StrLower(OL_BaseName(f)) = StrLower(A_ScriptName)) {
            rel := f
            break
        }
    if (rel = "") {
        LOGV("hotstring.key", A_ScriptName " is not one of the message files, so it"
                            . " owns no hotstring keys")
        return
    }

    mine := Map()
    recs := []
    HSI_ParseFile(rel, MMA_CONTENT "\" rel, recs)
    for r in recs
        mine[StrLower(r.trigger)] := r

    n := 0, notMine := 0
    for trg in binds {
        if !mine.Has(StrLower(trg)) {
            notMine++
            continue
        }
        ; HK_Bind, not a bare Hotkey(): it reads the key from the ini, honours a
        ; blank as "disabled", answers the reload broadcast, and puts the binding
        ; where the conflict report can see it.
        HK_Bind(HK_HotstringId(trg), HotstringKey_Handler.Bind(trg, mine[StrLower(trg)]))
        n++
    }
    if n
        LOGI("hotstring.key", n " hotstring(s) in " rel " have a key bound ("
                            . notMine " belong to other message files)")
}

; What the key sends. Resolved at PRESS time, not at bind time, for the overload:
; you can overload a trigger while MMA is running, and the key must follow it the
; same moment the trigger does.
;
; `rec` is this trigger's parsed source, captured at load. That is the one thing
; read ahead of time, because re-parsing the file on every keypress to send one
; message would be a disk read in the typing path.
HotstringKey_Handler(trigger, rec, *) {
    e := OL_LoadOne(trigger)
    if IsObject(e) && e.variants.Length {
        LOGV("hotstring.key", trigger " is overloaded — the key offers the same"
                            . " variants the trigger does")
        Overload_Run(e.variants, e.mode)
        return
    }
    if !rec.steps.Length {
        LOG_Bail("hotstring.key", trigger " has a key bound but its block sends"
                                . " nothing — nothing was sent. Has the hotstring"
                                . " been emptied or deleted since MMA started?")
        return
    }
    LOGI("hotstring.key", "sending " trigger " (" rec.steps.Length " step(s)) from"
                        . " its key rather than its trigger")
    Overload_Send(rec.steps)
}

HotstringKeys_Register()

Unread() {
    MouseGetPos &cx, &cy
    CoordMode "Mouse", "Screen"
    MouseClickDrag "Left", cx, cy, cx - 300, cy, 5
    MouseMove cx - 50, cy + 60, 0
}



; AFK

CoordMode "Mouse", "Window"

; Bound once, by 1_mass.ahk. It used to be a bare ^p:: here in utils.ahk, which
; every including script re-registered — so one press fired it once per running
; script.
AfkClick() {
    MouseMove 347, 208, 0
    Click
    Sleep(200)
    MouseMove 231, 352, 0
    Sleep(50)
    Click
}

GoAfk(){
    
    while(afk){
        MouseMove 347, 208, 0
        Click
        Sleep(200)
        MouseMove 231, 352, 0
        Sleep(50)
        Click
        Sleep(50)
        MouseMove 711, 481, 0
        Sleep(clearInterval)
    }
}

::_afk::{

   global afk
   afk := true
   goAfk()
}

::_offafk::{
    global afk
    afk := false
}

SetTimer(CheckAFK, 1000) ; cheque every 1 second

CheckAFK() {
    static afkTriggered := false  ; persistent state (like a private field)

    if (A_TimeIdle > 60000) {      ; 60,000 ms = 1 minute
        if (!afkTriggered) {
            afkTriggered := true
            goAfk()
        }
    } else {
        afkTriggered := false      ; reset when user becomes active again
    }
}

; Finds the nth occurrence of a color in a screen area.
; Returns [x, y] or false if fewer than n matches found.
; groupSkip: pixels to advance after each match — set > icon width to treat each icon as one hit
FindNthColor(n, color, x1, y1, x2, y2, variation := 10, groupSkip := 1) {
    CoordMode "Pixel", "Screen"
    sx := x1, sy := y1
    loop n {
        if !PixelSearch(&px, &py, sx, sy, x2, y2, color, variation)
            return false
        sx := px + groupSkip
        sy := py
        if sx > x2 {
            sx := x1
            sy := py + 1
            if sy > y2
                return false
        }
    }
    return [px, py]
}

clickOn(coord){
    MouseMove coord[1], coord[2]
    Click
}

; Like clickOn, but INSTANT (speed 0 — no drag animation) and it snaps the cursor
; back where it started afterwards. For side-effect clicks on a fixed-coord button
; (e.g. "open in new tab") that shouldn't yank your mouse away from what you're
; doing. Save/restore use the thread's current CoordMode, which is consistent here
; because the click keeps the same window active.
clickReturn(coord){
    MouseGetPos &sx, &sy
    MouseMove coord[1], coord[2], 0
    Click
    MouseMove sx, sy, 0
}

_lastTyped := ""

RecoverLastMsg() {
    global _lastTyped
    if _lastTyped = ""
        return
    focusTextbox()
    Sleep 80
    A_Clipboard := _lastTyped
    Send "^v"
}

focusTextbox(){
    MouseMove 800, 950
    Click
}

focusTop(){
    MouseMove 220,315
    Click
}

_savedChatX := 220
_savedChatY := 315

focusAuto(){
    global _savedChatX, _savedChatY, topChat
    MouseGetPos &mx, &my
    if (mx < 400) {
        _savedChatX := mx
        _savedChatY := my
        focusTextbox()
    } else {
        clickOn(topChat)
        if (_savedChatY > 900)
            Send "{WheelDown 4}"
    }
}

nextChat(){
   MouseGetPos &cx, &cy
   MouseMove cx, cy + 100
   MouseClick
}

; ─── Crash logging ────────────────────────────────────────────────────────────
; Moved to crashlog.ahk so main_window.ahk can have it too without pulling in this
; file's hotstrings and send helpers.
#Include "crashlog.ahk"
