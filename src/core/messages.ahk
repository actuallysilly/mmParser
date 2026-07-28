#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  messages.ahk — every window message MMA's processes send each other.
; ───────────────────────────────────────────────────────────────────────────────
;  MMA is several processes sharing files (see ARCHITECTURE.md §5). A file says
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
