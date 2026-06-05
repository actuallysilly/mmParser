#Requires AutoHotkey v2.0

; ============================================================
;  BRITISHIZER + SPELL FIXER
;  Enter  → fix typos + americanisms, capitalize sentences
; ============================================================

global fixes := Map(

    ; ---- COMMON SPELLING MISTAKES -------------------------
    "thru", "through",
    ">", "?",
    "tho", "though",
    "forrest", "forest",


    "teh",         "the",
    "thier",       "their",
    "theres",      "there's",
    "youre",       "you're",
    "dont",        "don't",
    "cant",        "can't",
    "wont",        "won't",
    "didnt",       "didn't",
    "doesnt",      "doesn't",
    "wasnt",       "wasn't",
    "isnt",        "isn't",
    "im",          "I'm",
    "ive",         "I've",
    "id",          "I'd",
    "ill",         "I'll",
    "recieve",     "receive",
    "beleive",     "believe",
    "occured",     "occurred",
    "occurance",   "occurrence",
    "seperate",    "separate",
    "definately",  "definitely",
    "untill",      "until",
    "wich",        "which",
    "wehre",       "where",
    "becuase",     "because",
    "freind",      "friend",
    "wierd",       "weird",
    "accomodate",  "accommodate",
    "embarass",    "embarrass",
    "neccessary",  "necessary",
    "adress",      "address",
    "writting",    "writing",
    "writen",      "written",
    "truely",      "truly",
    "arguement",   "argument",
    "lisence",     "licence",
    "occassion",   "occasion",
    "grammer",     "grammar",
    "publically",  "publicly",

    ; ---- AMERICAN → BRITISH --------------------------------
    ; -or → -our
    "color",       "colour",
    "colors",      "colours",
    "colored",     "coloured",
    "coloring",    "colouring",
    "flavor",      "flavour",
    "flavors",     "flavours",
    "honor",       "honour",
    "honors",      "honours",
    "honored",     "honoured",
    "labor",       "labour",
    "labors",      "labours",
    "neighbor",    "neighbour",
    "neighbors",   "neighbours",
    "rumor",       "rumour",
    "rumors",      "rumours",
    "humor",       "humour",
    "humors",      "humours",
    "valor",       "valour",
    "odor",        "odour",
    "armor",       "armour",
    "harbor",      "harbour",
    "endeavor",    "endeavour",
    "favorite",    "favourite",
    "favorites",   "favourites",

    ; -ize → -ise
    "organize",    "organise",
    "organized",   "organised",
    "organizing",  "organising",
    "realize",     "realise",
    "realized",    "realised",
    "realizing",   "realising",
    "recognize",   "recognise",
    "recognized",  "recognised",
    "recognizing", "recognising",
    "specialize",  "specialise",
    "specialized", "specialised",
    "authorize",   "authorise",
    "authorized",  "authorised",
    "criticize",   "criticise",
    "criticized",  "criticised",
    "apologize",   "apologise",
    "apologized",  "apologised",
    "memorize",    "memorise",
    "memorized",   "memorised",
    "minimize",    "minimise",
    "maximize",    "maximise",
    "prioritize",  "prioritise",
    "prioritized", "prioritised",
    "customize",   "customise",
    "customized",  "customised",
    "summarize",   "summarise",
    "summarized",  "summarised",
    "legalize",    "legalise",
    "legalized",   "legalised",
    "analyze",     "analyse",
    "analyzed",    "analysed",
    "analyzing",   "analysing",

    ; -er → -re
    "center",      "centre",
    "centers",     "centres",
    "centered",    "centred",
    "theater",     "theatre",
    "theaters",    "theatres",
    "fiber",       "fibre",
    "fibers",      "fibres",
    "liter",       "litre",
    "liters",      "litres",
    "meter",       "metre",
    "meters",      "metres",
    "kilometer",   "kilometre",
    "kilometers",  "kilometres",
    "specter",     "spectre",
    "somber",      "sombre",
    "somberly",    "sombrely",

    ; misc
    "gray",        "grey",
    "grays",       "greys",
    "tire",        "tyre",
    "tires",       "tyres",
    "program",     "programme",
    "programs",    "programmes",
    "catalog",     "catalogue",
    "catalogs",    "catalogues",
    "dialog",      "dialogue",
    "dialogs",     "dialogues",
    
    "draft",       "draught",
    "drafts",      "draughts",
    "aluminum",    "aluminium",
    "plow",        "plough",
    "plows",       "ploughs",
    "defense",     "defence",
    "defenses",    "defences",
    "offense",     "offence",
    "offenses",    "offences",
    "license",     "licence",
    "licenses",    "licences",
    "practice",    "practise",   ; verb form
    "skeptic",     "sceptic",
    "skeptical",   "sceptical",
    "skeptics",    "sceptics",
    "skepticism",  "scepticism",
    "mom",         "mum",
    "moms",        "mums",
    "soccer",      "football",
    "candy",       "sweets",
    "vacation",    "holiday",
    "apartment",   "flat",
    "elevator",    "lift",
    "truck",       "lorry",
    "cookie",      "biscuit",
    "cookies",     "biscuits",
    "trash",       "rubbish",
    "garbage",     "rubbish",
    "sidewalk",    "pavement",
    "faucet",      "tap",
    "drugstore",   "chemist",
    "gas",         "petrol",
    "diaper",      "nappy",
    "diapers",     "nappies",
    "eraser",      "rubber",
    "cellphone",   "mobile",
    "sneakers",    "trainers",
    "pants",       "trousers",
    "underwear",   "pants",
    "math",        "maths",
    "gotten",      "got",
)

!Enter:: Send("{Enter}")

Enter::  FixAndReplace(true)
#Enter:: FixAndReplace(false)

FixAndReplace(sendEnter) {
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^a")
    Sleep(50)
    Send("^c")
    ClipWait(1)
    text := A_Clipboard

    if (text = "") {
        A_Clipboard := saved
        if sendEnter
            Send("{Enter}")
        return
    }

    text := FixAll(text)
    text := CapitalizeSentences(text)

    A_Clipboard := text
    ClipWait(0.5)
    Send("^a")
    Sleep(50)
    Send("^v")
    Sleep(100)

    A_Clipboard := saved
    if sendEnter
        Send("{Enter}")
}

FixAll(text) {
    for wrong, right in fixes
        text := RegExReplace(text, "\b" . wrong . "\b", right)
    return text
}

CapitalizeSentences(text) {
    text := RegExReplace(text, "m)^([a-z])", "$U{1}")
    text := RegExReplace(text, "([.!?])(\s+)([a-z])", "$1$2$U{3}")
    text := RegExReplace(text, "\bi\b", "I")
    return text
}
