#Requires AutoHotkey v2.0
#Include "paths.ahk"
#Include "log.ahk"
#Include "active_model.ahk"
#Include "../screen/click_wall.ahk"
; ═══════════════════════════════════════════════════════════════════════════════
;  active_publish.ahk — tell processes outside AHK which account you are on.
; ───────────────────────────────────────────────────────────────────────────────
;  typelog (Python) tags every message with the account it was sent from and
;  starts a new conversation number when you click a fan in the list. It cannot
;  work either out for itself: which model is "active" is ActiveModelStatus's
;  answer, combining the per-site mode (manual, position, name) with two detector
;  files, and re-implementing that in Python would be a second opinion that drifts.
;
;  So the mass engine, the process that resolves the model for every shared key,
;  writes its answer to userdata\active_now.ini on the same 700ms beat as the lock
;  badge. Written only when something changed, and atomically (temp file, then a
;  move), so a reader never sees half of it.
;
;  [active]
;    site   infloww | fansly
;    no     model slot, 0 = MMA does not know
;    name   that slot's display name, "" when no = 0
;    state  ActiveModelStatus's state: ok | none | unknown | ambiguous | unlearned
;    list   the conversation list in SCREEN pixels, "x,y,w,h", or "" when the
;           click wall has no region (CW_Region). A click inside it is a fan switch.
;
;  ActiveModelStatus explains itself in the log when it cannot answer, which is
;  right when a key was pressed and pure noise on a timer, hence LOG_HUSH.
; ═══════════════════════════════════════════════════════════════════════════════

ACTIVE_Publish() {
    global LOG_HUSH, MMA_ACTIVE_NOW
    static last := ""
    no := 0, name := "", state := "none"
    LOG_HUSH += 1
    try {
        st := ActiveModelStatus()
        no := st.no
        state := st.state
        name := (no && st.HasProp("name")) ? st.name : ""
    }
    LOG_HUSH -= 1
    site := ActiveSiteName()
    list := ""
    try {
        r := CW_Region(CW_Cfg().win)
        if r
            list := r.x "," r.y "," r.w "," r.h
    }
    body := "[active]`nsite=" site "`nno=" no "`nname=" name "`nstate=" state "`nlist=" list "`n"
    if (body = last)
        return
    tmp := MMA_ACTIVE_NOW ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(body)
        f.Close()
        FileMove(tmp, MMA_ACTIVE_NOW, true)
        last := body
        LOGV("active.publish", "site=" site " no=" no " name=" name " state=" state " list=" list)
    } catch as e {
        LOGW("active.publish", "could not write " MMA_ACTIVE_NOW ": " e.Message)
    }
}
