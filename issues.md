1) during parsing, also scan the strings, if they contain " or ; or any other AHK character, keep these in an
arr called AHK_CHARS, prepend them with the ` (AHK escape char)
very commonly masses have "FUCK YES" or ;3 which need to be escaped

2) add model button -> creates a file if it doesnt exist

5) add hotkey should have an option to prepend the hotkey with :: or :*:

6) ' turns into � for some reason
6.1) ٩(^ᗜ^ )و ´- wasnt handled well!  turned into ?(^?^ )? �-
6.2) it has trouble parsing emojis they also turn into ?? or �, but inserting them directly in the code works fine!

7) open with code should open root and not /acc

8) clicking parse should clean before parsing, as there are leftover strings from last MM 
if for example there was a follow up 3, but the new mass only goes up to 2