#Requires AutoHotkey v2.0
; THEME_ChooseColour logs when the system colour dialog refuses to open, so this
; file now NAMES LOGW and LOG_Err and therefore includes the file that defines
; them — the same rule settings_window.ahk states at its own top. It is not
; bookkeeping: without it, parsing theme.ahk on its own stops on a #Warn dialog
; that no /ErrorStdOut ever reaches, so the check HANGS rather than failing, and
; the file quietly stops being one you can validate by itself.
;
; log.ahk includes paths.ahk, which includes log.ahk. That cycle already exists
; and resolves, because AHK loads any given file once.
#Include "log.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  theme.ahk — what colour everything is, in one place.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA's windows live in different PROCESSES. The main window and Settings are one
;  script; the follow-up picker is drawn by the mass engine; the overlays are their
;  own scripts again. Nothing is shared between them at runtime except the cfg
;  file, so "the theme" cannot be a variable somebody sets — it has to be a name in
;  mass_gui.cfg that each process reads for itself.
;
;  That is what this file is: the name, and the colours each name stands for. It is
;  included by the main window, by settings_window.ahk, and by core/utils.ahk
;  (which the engine and every message script load), so every side answers the same
;  question the same way.
;
;  ─── READ PER USE, NOT CACHED ────────────────────────────────────────────────
;  Every function here does an IniRead on the spot. That is deliberate and it is
;  cheap: it means switching theme in Settings reaches the picker on the very next
;  follow-up key, with no restart of the engine and no message to broadcast. The
;  same trade sndFu makes for FuSingle, and AltStageUseGui for its own toggle.
;
;  ─── WHY A DARK THEME IS MORE THAN A BACKGROUND ──────────────────────────────
;  Light themes need one colour: the window. Static controls inherit it and the
;  default black text still reads. Dark needs four, because nothing inherits a
;  foreground — set only the background and you get black text on a black window.
;  Hence THEME_Set() returning the whole set, and THEME_ApplyTo() to put it on a
;  window that has already been built.
; ═══════════════════════════════════════════════════════════════════════════════

; The theme in force. Unknown or missing → "pink", which is the default look.
;
; Validated rather than trusted: a hand-edited cfg saying `Theme=blue` should get
; the default, not a half-coloured window built from a lookup that threw.
;
; The MMA_THEME environment variable wins when it is set. That exists for tools —
; `settings_build_test.ahk hold 6 dark` previews a theme without writing one into
; your cfg, and a tool that leaves your settings changed is a tool that has broken
; something (see the notes on tests mutating live config).
THEME_Name() {
    t := Trim(EnvGet("MMA_THEME"))
    if (t = "")
        t := IniRead(MMA_CFG, "Settings", "Theme", "pink")
    t := StrLower(Trim(t))
    return (t = "classic" || t = "dark") ? t : "pink"
}

THEME_Is(name) {
    return THEME_Name() = name
}

; ── the whole palette for one theme ───────────────────────────────────────────
;  win      window background, or "" for "leave the system default alone"
;  text     foreground for labels, checkboxes, group boxes
;  dim      secondary text — the grey explanatory lines
;  inputBg  Edit / ListView / dropdown interiors, or "" to leave them alone
;  inputTx  text inside those
;  dark     is this a dark theme? decides whether ApplyTo has anything to do
;
;  Returned whole rather than read key by key so a window is always built from ONE
;  theme — read them individually and a save landing mid-build gives you a light
;  window with light text in it.
THEME_Set() {
    switch THEME_Name() {
        case "classic":
            ; Nothing set at all: the system decides, which is the point. It
            ; follows the user's Windows theme, including a high-contrast scheme
            ; somebody may actually need in order to read the screen.
            return {win: "", text: "", dim: "", inputBg: "", inputTx: "",
                    dark: false}
        case "dark":
            return {win:     "1E1D26",   ; the panel
                    text:    "FFFFFF",   ; labels — white, not a grey approximation
                    dim:     "FFFFFF",
                    inputBg: "2A2833",   ; a step up from the panel, so fields read
                    inputTx: "FFFFFF",   ;   as fields without needing a border
                    dark:    true}
    }
    ; Pink. Only the window is tinted, and that is deliberate: MMA's windows are
    ; mostly TEXT, and a real pink behind black text is tiring across a whole
    ; shift. At this lightness it reads as warm white, with the contrast plain
    ; white gave. Inputs keep their own white — that is what separates "somewhere
    ; you type" from the panel around it.
    return {win: "FEF7F9", text: "", dim: "", inputBg: "", inputTx: "",
            dark: false}
}

; Just the window background. The common case, and the only thing a light theme
; needs, so it stays a one-liner at the call sites.
THEME_WindowBg() {
    return THEME_Set().win
}

; The one accent colour: the SELECTED model's label in the main window's tab strip.
; It answers "which model am I typing into", so it deliberately is not the ink
; everything else is drawn in — a tab strip's own highlight is a few pixels of
; shading, and on the dark theme that is not enough to notice while working.
;
; One violet for both coloured themes, and a deeper one than the Variants window's
; B89CFF, because of WHERE it lands: the tab shapes are drawn by the visual style
; and stay light whatever the theme is (see THEME_ApplyTo on what the system
; draws), so this has to read against a pale tab, not against the panel.
;
; "" on classic, where the system owns every colour: a hard-coded hue could land
; unreadably on somebody's high-contrast scheme. The caller falls back to the
; system's own text colour and marks the selection with bold alone.
THEME_Accent() {
    return THEME_Is("classic") ? "" : "6D28D9"
}

; The colour part of a SetFont option string, to be appended to a window's font
; BEFORE its controls are added:
;
;     g.SetFont("s9" THEME_FontOpt(), "Segoe UI")
;
; This is how labels get their colour, and it has to happen at creation — see the
; note in THEME_ApplyTo about what colouring a static after the fact does to it.
; Empty on the light themes, where the default black is already right; empty on
; classic, where nothing is themed at all.
;
; AHK inherits unspecified font attributes from the previous font, so a later
; SetFont("s8") or SetFont("s9 Bold") keeps this colour. Only an explicit c<…>
; overrides it, which is what the deliberately grey explanatory lines want.
THEME_FontOpt() {
    pal := THEME_Set()
    return (pal.text = "") ? "" : " c" pal.text
}

; ── bold button labels ────────────────────────────────────────────────────────
;  Applied AFTER the controls exist, and only to buttons, which is what makes it
;  safe: a button is drawn by the system and takes a font change without argument.
;  The statics are the ones that must never be touched after creation — see the
;  long note in THEME_ApplyTo — so this deliberately skips everything else.
;
;  Not part of THEME_ApplyTo, and not gated on the theme: that function returns
;  early on classic (where the system owns the colours), and a classic window
;  should still have readable buttons. Bold is about weight, not palette.
;
;  "Bold" alone keeps the size and the typeface each control already has, so a
;  window whose buttons are s8 stays s8.
THEME_BoldButtons(gui) {
    for _hwnd, ctrl in gui {
        if (ctrl.Type = "Button")
            try ctrl.SetFont("Bold")
    }
}

; ── painting a window that already exists ─────────────────────────────────────
;  Walks the controls and colours them by type. Called AFTER everything has been
;  added, so a window does not have to thread colours through a few hundred Add()
;  calls — which is the only reason a dark theme is affordable here at all.
;
;  ─── THE TAB CONTROL IS NOT OPTIONAL, ON ANY THEME ──────────────────────────
;  A tab control paints its own page interior, and that page covers nearly the
;  whole window. Worse, the LABELS sitting on it are painted against the TAB's
;  background rather than the window's. Skip it and you do not merely miss the
;  panel — every label ends up on a pale box while the window around it is dark,
;  which is precisely how the main window looked when only Settings had its tab
;  coloured. So the tab pass runs for every theme that sets a colour at all.
;
;  ─── WHAT THIS CANNOT FIX ────────────────────────────────────────────────────
;  Buttons and the ListView header are drawn by the system and ignore a colour
;  unless the whole control is owner-drawn, which is not worth it here. On the
;  dark theme they stay light. That is a real limitation, not an oversight — it is
;  written on the tin in Settings so it is not a surprise.
THEME_ApplyTo(gui) {
    pal := THEME_Set()
    ; Classic sets nothing anywhere: the system decides, which is the point of it.
    if (pal.win = "")
        return pal
    gui.BackColor := pal.win
    ; The title bar belongs to DWM, not to us, and a dark window with a white
    ; title bar looks like a mistake. Attribute 20 is DWMWA_USE_IMMERSIVE_DARK_MODE
    ; on Windows 10 2004 and later; older builds used 19 and simply ignore this.
    ; Cosmetic either way, so a failure is swallowed rather than allowed to take
    ; the window down with it.
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", gui.Hwnd, "int", 20,
                "int*", pal.dark ? 1 : 0, "int", 4)
    ; `_hwnd`, not `hwnd` — there is a global by that name, and shadowing it here
    ; is the kind of thing #Warn exists to point at even when it is harmless.
    for _hwnd, ctrl in gui {
        if (ctrl.Type = "Tab" || ctrl.Type = "Tab2" || ctrl.Type = "Tab3") {
            try ctrl.Opt("+Background" pal.win)
            try ctrl.Redraw()
            continue
        }
        ; Everything below is ink, and a light theme needs none of it — the
        ; default black already reads on every one of these backgrounds.
        if !pal.dark
            continue
        switch ctrl.Type {
            ; Where you type or pick. Both halves have to be set together — a dark
            ; background with default black text is the same bug as the reverse.
            case "Edit", "ListView", "ComboBox", "DDL", "ListBox", "TreeView":
                try ctrl.Opt("+Background" pal.inputBg)
                try ctrl.SetFont("c" pal.inputTx)
                ; Setting the option is not the same as repainting with it —
                ; without this the control keeps the colours it was created with,
                ; which is exactly how the picker's highlight bar failed too.
                try ctrl.Redraw()
            ; System-drawn. Left alone on purpose — see above.
            case "Button":
                continue
            ; ─── LABELS ARE NOT TOUCHED HERE. THIS IS THE IMPORTANT PART. ─────
            ; Text, Checkbox, Radio, GroupBox — they take their colour from the
            ; window's font and background, which THEME_FontOpt() puts in place
            ; BEFORE they are created. Reaching for them afterwards is what made
            ; the main window look broken, twice, and the two failures look
            ; nothing alike:
            ;
            ;   SetFont after creation   → a static ON A TAB PAGE loses the
            ;                              inherited background and repaints with
            ;                              the system colour. Pale boxes behind
            ;                              every label on a dark window.
            ;   +Background after that   → the same static renders #000000, a
            ;                              shade that is in no palette here.
            ;
            ; Measured: a label OUTSIDE the tab takes an explicit background
            ; correctly (#1E1D26 as asked); the identical label on a tab page comes
            ; back #000000. Tab children are painted through a different path and
            ; will not be told what to do after the fact. So they are told before,
            ; once, through the font — and this loop leaves them alone.
            default:
                continue
        }
    }
    return pal
}

; ── the follow-up picker ──────────────────────────────────────────────────────
; Its own palette, because it is not a form: it is a list of messages where ONE is
; about to be sent. Whatever the theme, the marked row carries three signals at
; once — a deeper band, darker or brighter text, and the marker character — so it
; survives a bad monitor and it survives someone who does not separate these hues
; well. That gap is the thing standing between a picker and the wrong message
; going to a real person, so it is never toned down with the decoration.
THEME_Picker() {
    switch THEME_Name() {
        case "classic", "dark":
            return {bg:      "1B1A24",
                    row:     "24222F",
                    sel:     "2F2A4C",
                    head:    "8E89A6",
                    body:    "BFBBCE",
                    selHead: "C3B4FF",
                    selBody: "F4F2FB",
                    hint:    "6F6A85"}
    }
    ; Pink, and LIGHT — which is the point of it. This window appears over Infloww,
    ; which is near-black, so a light panel reads as "this is MMA asking you
    ; something" at a glance and cannot blend into the conversation underneath.
    ; The three backgrounds are one family scaled toward white; the marked row is
    ; held deeper than that scaling would give, because its job is not decoration.
    return {bg:      "FEF7F9",   ; barely tinted — the same as the main window
            row:     "FAEEF4",   ; a variant you have not marked
            sel:     "F4D6E4",   ; the marked one — this is what Enter sends
            head:    "A3778A",   ; its label line, muted so the text leads
            body:    "5E4450",
            selHead: "8A2B57",   ; deep rose — the label of the one going out
            selBody: "3A1F2B",   ; nearly black, the highest contrast in the window
            hint:    "9C7186"}
}

; ── picking a colour that is NOT part of a theme ──────────────────────────────
;  The system colour dialog, for the places where the colour is the user's own
;  choice rather than something the theme decides: a tab-strip divider, a reply
;  timer tier. Worth the DllCall rather than a longer palette — "change the
;  colour" means the colour you want, and a fixed list is only ever an
;  approximation of it.
;
;  It lives HERE, in the file that owns every colour in MMA, because two callers
;  in two processes need it: screen/tab_marks.ahk runs inside the mass engine and
;  ui/settings_window.ahk inside the main window. Both reach theme.ahk already —
;  the engine through mass/runtime.ahk → core/utils.ahk — so neither pays an
;  include for it, and there is one dialog to fix rather than a copy per caller.
;
;  Returns "RRGGBB", or "" if the user cancelled.
;
;  COLORREF is BGR and hex colours are RGB, so both ends are byte-swapped — see
;  THEME_SwapRB. The struct is laid out for x64: DWORD, pad, two pointers, DWORD,
;  pad, pointer, DWORD, pad, then three more pointers. 72 bytes.
THEME_ChooseColour(startHex, fallback := "FF6B7A") {
    static custom := Buffer(64, 0)      ; the dialog's 16 custom slots, kept per run
    cc := Buffer(72, 0)
    NumPut("uint", 72, cc, 0)                                        ; lStructSize
    NumPut("uint", THEME_SwapRB(THEME_HexVal(startHex, fallback)), cc, 24) ; rgbResult
    NumPut("ptr",  custom.Ptr, cc, 32)                               ; lpCustColors
    NumPut("uint", 0x03, cc, 40)        ; CC_RGBINIT | CC_FULLOPEN
    ok := 0
    try ok := DllCall("comdlg32\ChooseColorW", "ptr", cc, "int")
    catch as e {
        LOGW("theme", "the system colour dialog could not be opened — " LOG_Err(e))
        return ""
    }
    if !ok
        return ""
    return Format("{:06X}", THEME_SwapRB(NumGet(cc, 24, "uint")))
}

; RGB ↔ BGR. The same swap both ways, which is why there is one function.
THEME_SwapRB(v) {
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; "RRGGBB" → 0xRRGGBB, or the caller's fallback for anything that is not six hex
; digits. Never 0: black is a real colour and would look like a deliberate choice
; rather than like the parse having failed.
THEME_HexVal(hex, fallback := "FF6B7A") {
    h := Trim(hex)
    if (SubStr(h, 1, 1) = "#")
        h := SubStr(h, 2)
    if !RegExMatch(h, "^[0-9A-Fa-f]{6}$")
        h := fallback
    try return Integer("0x" h)
    return 0xFF6B7A
}

; Name → what the radio button says. Kept here rather than in the Settings window
; so adding a theme is one file, not two.
THEME_List() {
    return [{id: "pink",    label: "Pink",
             note: "Off-white pink windows, and a light follow-up picker."},
            {id: "dark",    label: "Dark",
             note: "Dark windows and a dark picker. Buttons and list headers stay"
                 . " light — Windows draws those and will not be told otherwise."},
            {id: "classic", label: "Classic",
             note: "The original: system-default windows, dark follow-up picker."}]
}
