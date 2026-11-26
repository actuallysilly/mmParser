#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  help_panel.ahk — Settings ▸ Help: what every key does, searchable.
; ───────────────────────────────────────────────────────────────────────────────
;  A cheat sheet, not an editor: the Hotkeys tab changes keys, this one answers
;  "what was the key for X" and "what does Ctrl+Win+R do" in one search box.
;  Rows come from HK_HelpRows() (core\hotkeys.ahk), the same list the WebView
;  Settings' Help section draws, so the two cannot disagree.
;
;  The search matches the key as written on screen ("ctrl+win+r"), as words
;  ("ctrl win r"), and the action's name ("grammar").
; ═══════════════════════════════════════════════════════════════════════════════

class HelpPanel {
    __New(hostGui, x, y, w, h) {
        this.rows := []
        for r in HK_HelpRows()
            this.rows.Push({key: HKP_Pretty(r["key"]), what: r["what"],
                            group: r["group"], where: r["where"]})
        this.ed := hostGui.Add("Edit", "x" x " y" y " w" w " h24")
        HKP_Cue(this.ed, "Type a key (ctrl win r) or what it does (grammar)…")
        this.ed.OnEvent("Change", (*) => this.Fill())
        this.lv := hostGui.Add("ListView", "x" x " y" (y + 32) " w" w " h" (h - 32)
                                         . " -Multi Grid", ["Key", "What it does", "Where"])
        HKP_DarkList(this.lv, this.ed)
        this.Fill()
        this.Layout(x, y, w, h)
    }

    Layout(x, y, w, h) {
        this.ed.Move(x, y, w)
        this.lv.Move(x, y + 32, w, h - 32)
        this.lv.ModifyCol(1, 190)
        this.lv.ModifyCol(2, w - 190 - 260 - 24)
        this.lv.ModifyCol(3, 260)
    }

    Fill() {
        q := HelpQuery(this.ed.Value)
        this.lv.Opt("-Redraw")
        this.lv.Delete()
        for r in this.rows
            if HelpMatches(q, r.key, r.what " " r.group)
                this.lv.Add(, r.key, r.what, r.group (r.where != "" ? " · " r.where : ""))
        this.lv.Opt("+Redraw")
    }
}

; A search, read once per keystroke. "ctrl win r", "ctrl+win+r" and "Ctrl+Win+R"
; are one query. When it names modifiers it is a KEY search: the modifiers must
; be exactly those, and the key (if one was typed) exactly that — so "ctrl win r"
; finds Ctrl+Win+R and not every action with an "r" in its name. Otherwise every
; word must appear somewhere in the key or the description.
HelpQuery(text) {
    static MODWORDS := Map("ctrl", "ctrl", "control", "ctrl", "win", "win",
                       "alt", "alt", "shift", "shift")
    words := []
    for wd in StrSplit(RegExReplace(StrLower(Trim(text)), "[+\s]+", " "), " ")
        if (wd != "")
            words.Push(wd)
    mods := Map(), rest := []
    for wd in words {
        if MODWORDS.Has(wd)
            mods[MODWORDS[wd]] := 1
        else
            rest.Push(wd)
    }
    isKey := mods.Count > 0 && rest.Length <= 1
    return {words: words, isKey: isKey, mods: mods, main: rest.Length ? rest[1] : ""}
}

; `key` is the on-screen form ("Ctrl+Win+R"); `text` is everything else searched.
HelpMatches(q, key, text) {
    if !q.words.Length
        return true
    if q.isKey {
        parts := StrSplit(StrLower(key), "+")
        main := parts.Pop()
        if (parts.Length != q.mods.Count)
            return false
        for p in parts
            if !q.mods.Has(p)
                return false
        return (q.main = "" || q.main = main)
    }
    hay := StrLower(StrReplace(key, "+", " ") " " text)
    for wd in q.words
        if !InStr(hay, wd)
            return false
    return true
}
