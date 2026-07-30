#Requires AutoHotkey v2.0
#Include "paths.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  crashlog.ahk — kept as a name, not as an implementation.
; ───────────────────────────────────────────────────────────────────────────────
;  This file used to own OnError: it caught uncaught errors and appended one line
;  to error_log.txt. That job now belongs to core\log.ahk, which does it with the
;  STACK attached and alongside everything else the process was doing at the time
;  — the context being the part that actually ends a hunt.
;
;  The file survives because two scripts name it in an #Include (utils.ahk and
;  main_window.ahk) and because its reason for existing separately is unchanged
;  and still correct: main_window.ahk must not include utils.ahk, so the crash
;  logger could not live there. paths.ahk turned out to be the better answer to
;  that same question — every script already includes it — so the hook moved
;  there and this became a forwarder.
;
;  Deleting it would mean editing those two #Include lines for no gain, and a
;  one-line file that explains where the behaviour went is worth more to the next
;  reader than one fewer file.
;
;  There is no OnError registration here any more. Two handlers would both fire
;  and log the same crash twice.
; ═══════════════════════════════════════════════════════════════════════════════
