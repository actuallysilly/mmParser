#Requires AutoHotkey v2.0

; SILLY
; ═══════════════════════════════════════════════════════════════════════════════
;  messages.ahk ~ user defined WindowsMessages, these are used for IPC 
; ───────────────────────────────────────────────────────────────────────────────

; We need a way to pass flags between processes so MMA GUI can interact with the engine
; AHK-prefered way to do this are native WindowsMessages
; ─────────────────



; Every window in Windows has a message-queue used for IPC with other windows

; It's not technically just for visible GUI
; it works for GUI, hidden, message windows
; MessageWindows -> Purpose-made type just for the IPC queue system

; Every AHK autohotkey64 creates a MessageWindow so we can use this

; Ox8000 and up are reserved for custom user messages 

; message structs contain LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) 
;   hwnd -> target window adress
;   msg  -> the hex message
;   2 param args for extra data, backward compatibility wordParam and longParam instea of generic types for efficiency on old machines

;               Why do we use messages instead of something else?
;       Because that's the AHK way, everything else required elaborate setup


; ═══════════════════════════════════════════════════════════════════════════════
;  messages.ahk — every window message MMA's processes send each other.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA is several processes sharing files (see docs/decisions.md §5). A file says
;  WHAT the data is; these messages say "go and re-read it" or "this toggle just
;  changed", so a setting applies on the next keypress with no restart.
;
;  ── Why they are all in one file ──────────────────────────────────────────────
;  They were not. 0x8001-0x8005 were declared as bare literals in mass/runtime.ahk
;  under a comment reading "Message numbers are a contract with main_window.ahk",
;  0x8006 in mass/engine.ahk, 0x8010 in sequences/sequences.ahk and 0x8020-0x8022
;  in core/hotkeys.ahk — four files each owning a slice of one number space, and no
;  file listing it. The senders were worse: main_window.ahk posted the raw numbers,
;  including `HK_Broadcast(0x8002 + f, val)` — arithmetic on a magic number, which
;  only works because 0x8003-0x8005 happen to sit directly above 0x8002.
;
;  Adding a message therefore meant grepping hex across the tree and hoping. This
;  is the same failure the mass field list had before store.ahk: two files
;  agreeing by hand about a shared shape. One file, one list.
;
;  ── Adding one ────────────────────────────────────────────────────────────────
;  Declare it here, in the right block, and use the NAME at both ends. Never a
;  literal — a literal is how 0x8002 came to mean two things depending on which
;  file you read.
; ═══════════════════════════════════════════════════════════════════════════════

; ─── Settings the GUI mirrors into the mass engine ────────────────────────────
;  main_window.ahk posts these when you tick a box; mass/runtime.ahk listens and
;  updates its own copy of the setting. Kept CONTIGUOUS and in this order because
;  MMA_MSG_EditableFu() below indexes off the first of the three.
global MMA_MSG_DOUBLE_MM      := 0x8001   ; toggle double-MM (no payload)
global MMA_MSG_WALLET_FU3     := 0x8002   ; wParam = 1 on, 0 off
global MMA_MSG_EDITABLE_FU1   := 0x8003   ; wParam = 1 on, 0 off
global MMA_MSG_EDITABLE_FU2   := 0x8004
global MMA_MSG_EDITABLE_FU3   := 0x8005

; ─── The mass library ─────────────────────────────────────────────────────────
;  Posted after the GUI writes masses.json. The engine re-reads the file; nothing
;  is passed in the message itself.
global MMA_MSG_MASSES_CHANGED := 0x8006

; ─── Sequences → the GUI ──────────────────────────────────────────────────────
;  copyDiscordMessageSeq puts a mass on the clipboard and posts this so the GUI
;  pastes and parses it. The one message that travels TOWARD the window.
global MMA_MSG_AUTOPARSE      := 0x8010

; ─── Hotstrings → the GUI ─────────────────────────────────────────────────────
;  "Add hotkey…" lives in the Hotstrings window now, and that window is its own
;  PROCESS: the Add Hotkey dialog is built out of main_window.ahk's globals (the
;  account file list, the default target file, the snd/SendText writers), so it
;  cannot simply be called from there. This asks the window that owns it to open
;  it. No payload.
global MMA_MSG_ADD_HOTKEY     := 0x8011

; ─── Settings → everything ────────────────────────────────────────────────────
;  The WebView Settings window is its own PROCESS (it carries an Edge runtime,
;  and the main window must never wait on one to open). The Win32 Settings is a
;  Gui inside the main window and could simply call UpdateModelButtons and
;  ApplyWindowTheme when it saved; a separate process cannot.
;
;  So it broadcasts this instead, and the shells answer by re-reading the cfg
;  keys they cache — model names and the theme — and repainting. No payload: the
;  file is the message, exactly as with MMA_MSG_MASSES_CHANGED above.
global MMA_MSG_SETTINGS_CHANGED := 0x8012

; ─── The WebView Settings → the main window ───────────────────────────────────
;  The WebView Settings deliberately does not draw the tabs that drive screen
;  capture — the calibration drags, the region pickers, the detector readouts. Its
;  button for those asks for the Win32 Settings, which is a Gui built inside the
;  MAIN window's process out of that window's globals, so it cannot simply be run.
;  Same shape as MMA_MSG_ADD_HOTKEY above. No payload.
global MMA_MSG_OPEN_SETTINGS := 0x8013

; ─── The hotkey registry ──────────────────────────────────────────────────────
;  Broadcast by HK_Broadcast to every MMA script (see hotkeys.ahk), which is why
;  they are numbered clear of the per-feature messages above.
global HK_MSG_RELOAD          := 0x8020   ; every script re-reads hotkeys.ini
global HK_MSG_SUSPEND         := 0x8021   ; hold fire while a key is captured
global HK_MSG_FIRE            := 0x8022   ; whoever owns this action runs it

; Which message carries "editable follow-up <n>", n = 1..3.
;
; Replaces `HK_Broadcast(0x8002 + f, val)` at the sending end and `msg - 0x8002`
; at the receiving end. Both were correct, and both encoded the block's layout at
; a call site — so moving these three numbers would have broken a send and a
; receive in two different files, silently, with the wrong follow-up going out.
MMA_MSG_EditableFu(n) {
    global MMA_MSG_EDITABLE_FU1
    return MMA_MSG_EDITABLE_FU1 + (n - 1)
}

; The inverse: which follow-up group a received message means, or 0 if it is not
; one of the three. Returning 0 rather than a wrong number matters — this runs in
; an OnMessage handler, where a bad index would quietly set the wrong toggle.
MMA_MSG_EditableFuNo(msg) {
    global MMA_MSG_EDITABLE_FU1, MMA_MSG_EDITABLE_FU3
    if (msg < MMA_MSG_EDITABLE_FU1 || msg > MMA_MSG_EDITABLE_FU3)
        return 0
    return msg - MMA_MSG_EDITABLE_FU1 + 1
}
