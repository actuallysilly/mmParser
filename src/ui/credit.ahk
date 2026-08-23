#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  credit.ahk — the picture in the main window's empty corner, and her animation.
; ───────────────────────────────────────────────────────────────────────────────
;  She is whatever you drop in assets\: an animated GIF if there is one, otherwise
;  a PNG. Nothing else in MMA depends on the file existing, and an install without
;  one is simply an install with a plain text credit.
;
;  ─── WHY THIS IS NOT SIX PICTURE CONTROLS ANY MORE ──────────────────────────
;  It was. A Gui Picture control scales its bitmap when it is CREATED and never
;  again, and AHK v2 cannot destroy one control — only the whole window. So
;  "resize her to the space" used to mean building one hidden copy per height at
;  startup (90, 130, 180 … 540 px) and showing whichever fitted. That cost eight
;  GDI+ scales of an 826KB PNG on every launch, capped her at the tallest rung
;  anyone had thought to add, and could not have animated anything.
;
;  A static control will however accept a NEW bitmap at any time — STM_SETIMAGE —
;  which is the same message that makes the animation possible. So there is one
;  control, MMA scales the frames itself with GDI+ when the fitting size changes,
;  and a timer walks the frames. One code path covers both: a PNG is a GIF with
;  one frame and no timer.
;
;  ─── WHAT "SIZE" MEANS HERE ─────────────────────────────────────────────────
;  Still a ladder of discrete heights, but of SIZES rather than of controls: the
;  main window asks CREDIT_Sizes() which heights exist, tests each rectangle
;  against its own controls, and calls CREDIT_Place() with the biggest that fits.
;  Discrete, because rescaling every frame is real work and a window being dragged
;  by its edge would otherwise ask for it sixty times a second. The rungs are
;  denser and taller than the old ladder — they cost nothing until one is used.
;
;  Heights, not widths: a height-first fit is what stops a portrait image becoming
;  a sliver, and the corner is taller than it is wide on a maximised window.
; ═══════════════════════════════════════════════════════════════════════════════

; The rungs, in px at 100% zoom, smallest first. The top of the ladder is well past
; what a maximised window on a 1440p screen reaches — an unused rung is a number in
; an array, not a scaled bitmap.
global CREDIT_HEIGHTS := [90, 130, 180, 240, 300, 360, 440, 540, 660, 800]

global CRED_pic     := 0     ; the one Picture control
global CRED_img     := 0     ; GDI+ image handle for the source file
global CRED_frames  := []    ; HBITMAPs for the CURRENT size, in order
global CRED_delays  := []    ; ms per frame, same order
global CRED_nFrames := 0
global CRED_sizes   := []    ; [{w,h}] one per rung, smallest first
global CRED_at      := 0     ; index into CRED_sizes the frames are built for
global CRED_frame   := 1     ; which frame is on screen
global CRED_token   := 0     ; GDI+ token, non-zero once started
global CRED_bg      := 0     ; ARGB the frames are flattened onto
global CRED_path    := ""
global CRED_gui     := 0     ; the window she belongs to, kept for CREDIT_Refresh
global CRED_x       := 0     ; where CREDIT_Load was told to put the control; the
global CRED_y       := 0     ;   layout pass moves it, this is only the start point

; FrameDimensionTime — {6AEDBD6D-3FB5-418A-83A6-7F45229DC872}. The dimension a GIF
; counts its frames along; a multi-PAGE TIFF uses a different one, which is why
; this is a parameter to the GDI+ calls rather than assumed.
CRED_TimeGuid() {
    static g := 0
    if g
        return g
    g := Buffer(16, 0)
    NumPut("UInt",   0x6AEDBD6D, g, 0)
    NumPut("UShort", 0x3FB5,     g, 4)
    NumPut("UShort", 0x418A,     g, 6)
    for i, b in [0x83, 0xA6, 0x7F, 0x45, 0x22, 0x9D, 0xC8, 0x72]
        NumPut("UChar", b, g, 7 + i)
    return g
}

CRED_StartGdip() {
    global CRED_token
    if CRED_token
        return true
    ; LoadLibrary first: without it the very first gdiplus\ call can fail to
    ; resolve, and the failure looks like "no picture" rather than like a missing
    ; DLL.
    if !DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
        return false
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)              ; GdiplusVersion
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &tok := 0, "Ptr", si, "Ptr", 0)
    CRED_token := tok
    return CRED_token != 0
}

; "RRGGBB" (or "" for the classic theme's system colours) → the opaque ARGB the
; frames are drawn onto. A GIF frame has transparent pixels; GDI+ hands back a
; plain HBITMAP with no alpha, so whatever we flatten onto is what shows through.
; Get it wrong and she stands in a black box.
CRED_BgColor() {
    hex := THEME_WindowBg()
    if (hex != "")
        return 0xFF000000 | Integer("0x" hex)
    ; Classic: the window is whatever the user's scheme says. COLOR_BTNFACE comes
    ; back as BGR, so the two ends swap.
    v := DllCall("GetSysColor", "Int", 15, "UInt")
    return 0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; Is she switched on at all? Settings ▸ GUI ▸ Corner picture. Read from the ini on
; every call rather than cached, because the setting applies live — see
; CREDIT_Refresh.
CREDIT_On() {
    return LOG_IniInt(MMA_CFG, "Settings", "CreditPicture", 1) != 0
}

; What Settings ▸ GUI has picked, as a usable path — or "" for "choose one
; yourself". Three forms are stored, and the difference matters:
;
;   ""                  automatic: whatever is in assets\decoration\ (see below)
;   "anime_girl1.gif"   a bare name, meaning a file in assets\decoration\. Stored
;                       WITHOUT the folder so the install can move without
;                       breaking the choice
;   "D:\pics\her.gif"   anything with a separator is taken as an absolute path, so
;                       she can live outside the repo
;
; A bare name still resolves against assets\ itself if decoration\ does not have
; it, because that is where these files used to live and a settings value written
; before the move names a file, not a folder.
CREDIT_PickedPath() {
    v := Trim(IniRead(MMA_CFG, "Settings", "CreditImage", ""))
    if (v = "")
        return ""
    if InStr(v, "\") || InStr(v, ":")
        return v
    return FileExist(MMA_DECOR "\" v) ? MMA_DECOR "\" v : MMA_ASSETS "\" v
}

; The file she comes from. The picked one if it is set and still there, otherwise
; any decoration\anime_girl*.gif, then the PNG — a glob rather than one fixed name so
; dropping "anime_girl2.gif" in beside the old one is all it takes to change her,
; and so an animated file always wins over a still one, which is the answer
; anybody who put a GIF there is looking for.
;
; A picked file that has been deleted or renamed falls back rather than showing
; nothing: an empty corner is indistinguishable from the feature being broken.
CRED_FindFile() {
    picked := CREDIT_PickedPath()
    if (picked != "") {
        if FileExist(picked)
            return picked
        LOGW("gui.credit", "the picture chosen in Settings is gone — falling back to"
                         . " whatever is in assets\decoration\.  " picked)
    }
    for pat in ["anime_girl*.gif", "anime_girl*.png"] {
        best := ""
        Loop Files, MMA_DECOR "\" pat
            if (best = "" || StrCompare(A_LoopFileName, best) < 0)
                best := A_LoopFileName
        if (best != "")
            return MMA_DECOR "\" best
    }
    return ""
}

; Every image assets\decoration\ has to offer, as bare file names. Settings lists
; these; the window itself never calls it.
CREDIT_AssetList() {
    names := []
    for pat in ["*.gif", "*.png"]
        Loop Files, MMA_DECOR "\" pat
            names.Push(A_LoopFileName)
    return names
}

; Per-frame delays, in ms, from the GIF's PropertyTagFrameDelay (0x5100) — an
; array of one UINT per frame in HUNDREDTHS of a second. A frame that says 0 means
; "as fast as possible", which every browser reads as 100ms; so do we, because
; honouring a literal 0 would spin the timer flat out for no visible gain.
CRED_ReadDelays(pImg, n) {
    ms := []
    try {
        if (DllCall("gdiplus\GdipGetPropertyItemSize", "Ptr", pImg, "UInt", 0x5100,
                    "UInt*", &sz := 0) = 0 && sz > 0) {
            buf := Buffer(sz, 0)
            if (DllCall("gdiplus\GdipGetPropertyItem", "Ptr", pImg, "UInt", 0x5100,
                        "UInt", sz, "Ptr", buf) = 0) {
                ; PropertyItem: PROPID id; ULONG length; WORD type; VOID* value.
                ; The value pointer is at offset 16 on x64 — the struct is padded
                ; to the pointer's alignment, so 16 is not 10.
                pVal := NumGet(buf, 16, "Ptr")
                len  := NumGet(buf, 4, "UInt")
                Loop Min(n, len // 4)
                    ms.Push(NumGet(pVal, (A_Index - 1) * 4, "UInt"))
            }
        }
    }
    ; Short, empty or unreadable — one sane delay per frame beats a frame list that
    ; does not line up with the frames.
    while (ms.Length < n)
        ms.Push(10)
    for i, v in ms
        ms[i] := (v <= 0 ? 100 : v * 10)
    return ms
}

; Build the control and work out the rungs. Returns false when there is no picture
; to show, and every caller treats that as "the credit is a line of text" — which
; it already is, drawn by the window itself.
CREDIT_Load(guiObj, x, y) {
    global CRED_pic, CRED_img, CRED_nFrames, CRED_delays, CRED_sizes, CRED_bg, CRED_path
    global CRED_gui, CRED_x, CRED_y
    CRED_gui := guiObj, CRED_x := x, CRED_y := y
    if !CREDIT_On()
        return false
    CRED_path := CRED_FindFile()
    if (CRED_path = "")
        return false
    if !CRED_StartGdip() {
        LOGW("gui.credit", "GDI+ would not start — " CRED_path " will not be shown."
                         . " The text credit is unaffected.")
        return false
    }
    if (DllCall("gdiplus\GdipCreateBitmapFromFile", "Str", CRED_path,
                "Ptr*", &pImg := 0) != 0 || !pImg) {
        LOGW("gui.credit", "could not decode " CRED_path " — is it really an image?"
                         . " The credit line will be text only.")
        return false
    }
    CRED_img := pImg
    DllCall("gdiplus\GdipGetImageWidth",  "Ptr", pImg, "UInt*", &srcW := 0)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", pImg, "UInt*", &srcH := 0)
    if (srcW = 0 || srcH = 0) {
        LOGW("gui.credit", CRED_path " measured 0px — ignoring it")
        return false
    }
    DllCall("gdiplus\GdipImageGetFrameCount", "Ptr", pImg, "Ptr", CRED_TimeGuid(),
            "UInt*", &nf := 0)
    CRED_nFrames := Max(nf, 1)
    CRED_delays  := CRED_nFrames > 1 ? CRED_ReadDelays(pImg, CRED_nFrames) : [0]
    CRED_bg      := CRED_BgColor()

    ; Width follows the height off the source's own aspect ratio, so the artwork can
    ; be any shape — a height-first fit is what stops a portrait image becoming a
    ; sliver.
    ;
    ; The rungs are in AHK's logical units; the source is in device pixels. A rung
    ; is dropped when it would blow the source up past 2x IN DEVICE PIXELS, which
    ; is where the fit test would otherwise happily pick a blurry smear — and that
    ; comparison has to be made after the DPI factor, or a 125% display quietly
    ; upscales a quarter more than a 100% one for the same rung.
    CRED_sizes := []
    for _rh in CREDIT_HEIGHTS {
        if (_rh * A_ScreenDPI / 96 > srcH * 2)
            continue
        CRED_sizes.Push({w: Max(1, Round(srcW * _rh / srcH)), h: _rh})
    }
    if !CRED_sizes.Length
        CRED_sizes.Push({w: srcW, h: srcH})

    ; Created FROM THE FILE, at the smallest rung, so the static ends up with
    ; SS_BITMAP — the style STM_SETIMAGE needs. An empty Picture control has no
    ; style to speak of and silently ignores the message.
    ;
    ; Once only. Picking a different picture in Settings comes back through here,
    ; and AHK v2 cannot destroy a single control — so a second Add would leave the
    ; first one on the window forever, showing the picture you just replaced.
    ; The control is a frame; which bitmap is in it is CREDIT_Place's business.
    if !CRED_pic {
        try {
            CRED_pic := guiObj.Add("Picture", "x" x " y" y " w" CRED_sizes[1].w
                                            . " h" CRED_sizes[1].h, CRED_path)
        } catch as err {
            LOGW("gui.credit", "could not create the picture control.  " LOG_Err(err))
            return false
        }
        CRED_pic.Visible := false
        ; Bottom of the z-order: she is background. Controls paint in creation
        ; order, so a picture added after them would sit ON TOP of anything she
        ; overlaps — and the whole point of putting her in dead space is that she
        ; never costs a control its pixels. HWND_BOTTOM = 1, with
        ; NOSIZE|NOMOVE|NOACTIVATE = 0x13. Re-applied on a later Add too: a control
        ; created after the window is up goes to the TOP of the z-order.
        try DllCall("SetWindowPos", "Ptr", CRED_pic.Hwnd, "Ptr", 1,
                    "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
    }
    LOGI("gui.credit", CRED_path " — " srcW "x" srcH ", " CRED_nFrames " frame(s)")
    return true
}

; The rung sizes, smallest first, and EMPTY when there is nothing to show — which
; is how "switched off in Settings" reaches the layout without the layout knowing
; anything about the setting. Called fresh on every layout pass rather than held
; in a variable, precisely so CREDIT_Refresh can swap the array underneath it.
CREDIT_Sizes() {
    global CRED_sizes
    return CRED_sizes
}

; Re-read Settings ▸ GUI ▸ Corner picture and act on it: switched off, switched
; back on, or pointed at a different file. Applies live — the caller follows it
; with a layout pass, which is what puts her (or nothing) on screen.
;
; No reload, unlike the theme and the model count: nothing here changes which
; controls the window BUILDS. The one control is created on first use and then
; reused for every picture after it.
CREDIT_Refresh() {
    global CRED_pic, CRED_img, CRED_at, CRED_frame, CRED_sizes, CRED_nFrames
    global CRED_gui, CRED_x, CRED_y
    SetTimer(CREDIT_Tick, 0)
    if CRED_pic
        CRED_pic.Visible := false
    CRED_FreeFrames()
    CRED_at     := 0            ; forces a rebuild at whatever rung is picked next
    CRED_frame  := 1
    CRED_nFrames := 0
    CRED_sizes  := []
    if CRED_img {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", CRED_img)
        CRED_img := 0
    }
    if !CRED_gui                ; CREDIT_Load was never called — nothing to refresh
        return false
    return CREDIT_Load(CRED_gui, CRED_x, CRED_y)
}

; Scale every frame to rung `idx`. The expensive call, which is why CREDIT_Place
; only reaches it when the rung actually changed.
CRED_BuildFrames(idx) {
    global CRED_img, CRED_frames, CRED_nFrames, CRED_sizes, CRED_at, CRED_bg, CRED_frame
    if (CRED_at = idx)
        return true
    ; ─── THE TWO UNITS, AND WHY THIS LINE EXISTS ─────────────────────────────
    ;  A rung is in AHK's coordinate units, which are LOGICAL: "h360" on a 125%
    ;  display is a control 450 device pixels tall, because AHK scales what you
    ;  ask for by A_ScreenDPI/96. A bitmap is in DEVICE pixels — nothing scales it.
    ;
    ;  So a 360-tall bitmap in a 450-tall control leaves 90px of background under
    ;  her and shrinks her by a fifth on exactly the machines that are hardest to
    ;  test on. Scale the bitmap by the same factor AHK scales the control by, and
    ;  the two agree at every zoom level. (The old ladder never hit this: it asked
    ;  AHK to load the file at "h360 w-1" and AHK did the scaling itself.)
    scale := A_ScreenDPI / 96
    sz := CRED_sizes[idx]
    pxW := Max(1, Round(sz.w * scale))
    pxH := Max(1, Round(sz.h * scale))
    made := []
    Loop CRED_nFrames {
        i := A_Index
        if (CRED_nFrames > 1)
            DllCall("gdiplus\GdipImageSelectActiveFrame", "Ptr", CRED_img,
                    "Ptr", CRED_TimeGuid(), "UInt", i - 1)
        if (DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", pxW, "Int", pxH,
                    "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBmp := 0) != 0)
            break
        if (DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp,
                    "Ptr*", &pG := 0) = 0) {
            DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pG, "Int", 7)  ; HQ bicubic
            DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pG, "Ptr", CRED_img,
                    "Int", 0, "Int", 0, "Int", pxW, "Int", pxH)
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pG)
        }
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &hbm := 0,
                "UInt", CRED_bg)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        if !hbm
            break
        made.Push(hbm)
    }
    if !made.Length
        return false
    ; The old set goes only once the new one exists. A GDI leak here is a handle per
    ; resize step, which a window dragged about for a minute would notice.
    CRED_FreeFrames()
    CRED_frames := made
    CRED_at     := idx
    CRED_frame  := 1
    return true
}

CRED_FreeFrames() {
    global CRED_frames
    for hbm in CRED_frames
        DllCall("DeleteObject", "Ptr", hbm)
    CRED_frames := []
}

; Put frame `n` on the control. STM_SETIMAGE hands back whatever was there; we do
; NOT delete that, because the first one is AHK's own bitmap from Gui.Add and the
; rest are ours and still in CRED_frames.
CRED_ShowFrame(n) {
    static STM_SETIMAGE := 0x0172
    global CRED_pic, CRED_frames
    if (!CRED_pic || !CRED_frames.Length)
        return
    try SendMessage(STM_SETIMAGE, 0, CRED_frames[n], CRED_pic)
}

; Show rung `idx` at (x, y), or hide her when idx is 0. Called from the window's
; layout pass, i.e. on every resize — so the common case (same rung, new position)
; must be a Move and nothing else.
CREDIT_Place(idx, x, y) {
    global CRED_pic, CRED_sizes, CRED_at, CRED_nFrames, CRED_frame
    if !CRED_pic
        return
    if (!idx || idx > CRED_sizes.Length) {
        CRED_pic.Visible := false
        SetTimer(CREDIT_Tick, 0)
        return
    }
    if !CRED_BuildFrames(idx) {
        CRED_pic.Visible := false
        return
    }
    sz := CRED_sizes[idx]
    CRED_pic.Move(x, y, sz.w, sz.h)
    CRED_ShowFrame(CRED_frame)
    CRED_pic.Visible := true
    ; One-shot, re-armed per frame: GIF frames carry their own delays and a single
    ; period would play a 20ms frame for as long as a 500ms one. Nothing to arm for
    ; a still picture — a timer that swaps frame 1 for frame 1 is pure heat.
    if (CRED_nFrames > 1)
        SetTimer(CREDIT_Tick, -CRED_FrameDelay())
}

CRED_FrameDelay() {
    global CRED_delays, CRED_frame
    return CRED_delays.Has(CRED_frame) ? CRED_delays[CRED_frame] : 100
}

CREDIT_Tick() {
    global CRED_pic, CRED_frame, CRED_frames, CRED_nFrames, g
    if (!CRED_pic || !CRED_frames.Length)
        return
    ; Stop dead while she is not on screen. The window spends most of its life
    ; minimised or behind Infloww, and twelve bitmap swaps a second into a hidden
    ; window is a laptop fan for nobody's benefit. Re-armed by the layout pass and
    ; by the next tick, so nothing has to notice the window coming back — the
    ; cheapest thing that DOES wake it up is this same timer, so it keeps a slow
    ; heartbeat rather than switching itself off for good.
    if (!CRED_pic.Visible || WinGetMinMax("ahk_id " g.Hwnd) = -1) {
        SetTimer(CREDIT_Tick, -400)
        return
    }
    CRED_frame := CRED_frame >= CRED_nFrames ? 1 : CRED_frame + 1
    CRED_ShowFrame(CRED_frame)
    SetTimer(CREDIT_Tick, -CRED_FrameDelay())
}
