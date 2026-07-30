#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "../../src/core/utils.ahk"

; @added 2026-07-26
; Was a bare "!1::" written straight into this file — a message on a hardcoded
; key, which is the one thing that is neither data nor declared in hotkeys.ini.
; Named Fu1 to sit beside the Fu2 below it.
:*:Fu1::
{
    snd("Now imagine if I let you snatch that bra off me")
    snd("So you can reveal all of my explicitness")
    snd("And... Might as well take the panties off to while we're there riiight?")
}

; @added 2026-07-25
:*:Fu2::
{
    Sendt("Can you even imagine how nice it would be to take my panties off and reveal the treasure I keep hidden from the world", 1000)
    Sendt("So you can fuck me relentlessly and make me squirt in doggy...", 1000)
    Sendt("Should I remove the panties or fuck yes?", 1000)
}

; @added 2026-07-30 00:15
!9::
{
    snd("But I'm also wondering.. Should I take all of that off myself")
}
