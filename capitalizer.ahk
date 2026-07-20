#Requires AutoHotkey v2.0
#Include "hotkeys.ahk"

; ============================================================
;  SENTENCE CAPITALIZATION
;  Capitalizes the first letter after:
;    - Enter  (new line)
;    - .  !  ?  followed by Space
;  Non-destructive: never selects or replaces existing text.
;  5-second timeout resets the flag if no letter is typed.
;
;  The Enter keys live in hotkeys.ini under [cap]. The a-z keys below stay
;  hard-coded: they're how this script works, not settings to tune.
; ============================================================

capitalizeNext := false

; Shift+Enter / Ctrl+Enter pass through normally
CapEnterPass() => Send("{Enter}")

; Normal Enter → send Enter, then queue capitalize
CapEnter() {
    global capitalizeNext
    Send("{Enter}")
    capitalizeNext := true
    SetTimer(ResetCapNext, -5000)
}

HK_Bind("cap.enterCap",   CapEnter)
HK_Bind("cap.enterPass1", CapEnterPass)
HK_Bind("cap.enterPass2", CapEnterPass)

; Detect ". " "! " "? " sequences — B0 = no backspace/replacement
:B0:. ::SetCapNext()
:B0:! ::SetCapNext()
:B0:? ::SetCapNext()

SetCapNext() {
    global capitalizeNext
    capitalizeNext := true
    SetTimer(ResetCapNext, -5000)
}

ResetCapNext() {
    global capitalizeNext
    capitalizeNext := false
}

; When capitalizeNext is active, uppercase the next letter typed
#HotIf capitalizeNext
Space:: Send(" ")   ; allow leading spaces, keep waiting
a:: Cap("A")
b:: Cap("B")
c:: Cap("C")
d:: Cap("D")
e:: Cap("E")
f:: Cap("F")
g:: Cap("G")
h:: Cap("H")
i:: Cap("I")
j:: Cap("J")
k:: Cap("K")
l:: Cap("L")
m:: Cap("M")
n:: Cap("N")
o:: Cap("O")
p:: Cap("P")
q:: Cap("Q")
r:: Cap("R")
s:: Cap("S")
t:: Cap("T")
u:: Cap("U")
v:: Cap("V")
w:: Cap("W")
x:: Cap("X")
y:: Cap("Y")
z:: Cap("Z")
#HotIf

Cap(letter) {
    global capitalizeNext
    capitalizeNext := false
    Send(letter)
}
