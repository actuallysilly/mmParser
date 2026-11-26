#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  payout_calc.ahk — the little payout calculator.
; ───────────────────────────────────────────────────────────────────────────────
;      result = input × fee × fee … × USD→EUR − subtract
;
;  Out of the box that is  input × 0.97 × 0.97 × rate − 150.  Every number is a
;  [Calculator] key in mass_gui.cfg, editable on its page in the Tools window:
;
;    Fees       multipliers, comma separated          0.97, 0.97
;    Subtract   taken off at the end, in EUR          150
;    UsdToEur   the last rate fetched — also what is  0.91
;               used when the fetch fails
;    RateDate   the date of that rate (written here, not shown in Settings)
;
;  The rate comes from api.frankfurter.dev (European Central Bank reference
;  rates, no key, updated once per working day). It is fetched each time the
;  window opens, ASYNC — the window is usable at once with the saved rate and
;  switches when the answer arrives. Nothing about the user is sent: the request
;  is a fixed URL.
; ═══════════════════════════════════════════════════════════════════════════════

global CALC_WIN := 0
global CALC_RATE_URL := "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR"

; A number from the ini, or the fallback when it is missing or not a number.
CALC_IniNum(key, fallback) {
    v := ""
    try v := Trim(IniRead(MMA_CFG, "Calculator", key, ""))
    return CALC_Num(v, fallback)
}

; "1,234.50", "$1234.5", " 1234 " → 1234.5. Commas are thousands separators.
CALC_Num(s, fallback := "") {
    s := RegExReplace(Trim(s), "[\s$€,]", "")
    return RegExMatch(s, "^-?(\d+\.?\d*|\.\d+)$") ? Number(s) : fallback
}

CALC_Fees() {
    raw := "0.97, 0.97"
    try raw := IniRead(MMA_CFG, "Calculator", "Fees", raw)
    fees := []
    for part in StrSplit(raw, [",", ";", " "]) {
        n := CALC_Num(part)
        if (n != "")
            fees.Push(n)
    }
    return fees
}

; 1234.5 → "1,234.50"
CALC_Money(n) {
    s := Format("{:.2f}", Abs(n))
    whole := SubStr(s, 1, -3), cents := SubStr(s, -2)
    out := ""
    while (StrLen(whole) > 3) {
        out := "," SubStr(whole, -3) out
        whole := SubStr(whole, 1, -3)
    }
    return (n < 0 ? "−" : "") whole out "." cents
}

OpenPayoutCalc(*) {
    global CALC_WIN
    if CALC_WIN {
        try {
            CALC_WIN.Show()
            return
        }
        CALC_WIN := 0
    }

    BG      := "15141C"
    FIELDBG := "2A2836"
    TXT     := "E6E4EE"
    MUTED   := "8E8AA6"
    ACCENT  := "B89CFF"

    rate     := CALC_IniNum("UsdToEur", 0.91)
    rateDate := ""
    try rateDate := Trim(IniRead(MMA_CFG, "Calculator", "RateDate", ""))
    rateNote := rateDate != "" ? "saved " rateDate : "default"
    req := 0

    cg := Gui("+AlwaysOnTop -MinimizeBox", "Payout calculator")
    CALC_WIN := cg
    cg.BackColor := BG
    cg.MarginX := 16
    cg.MarginY := 12

    cg.SetFont("s13 Bold c" ACCENT, "Segoe UI")
    cg.Add("Text", "x16 y12 w320", "Payout calculator")

    cg.SetFont("s10 Norm c" MUTED, "Segoe UI")
    cg.Add("Text", "x16 y48 w60", "USD")
    cg.SetFont("s14 c" TXT, "Segoe UI")
    edIn := cg.Add("Edit", "x76 y42 w260 h34 Background" FIELDBG)

    cg.SetFont("s10 c" MUTED, "Segoe UI")
    cg.Add("Text", "x16 y94 w60", "EUR")
    cg.SetFont("s20 Bold c" ACCENT, "Segoe UI")
    lblOut := cg.Add("Text", "x76 y84 w260", "—")

    cg.SetFont("s9 Norm c" MUTED, "Segoe UI")
    lblHow  := cg.Add("Text", "x16 y128 w320", "")
    lblRate := cg.Add("Text", "x16 y148 w320", "")

    cg.SetFont("s10 c" TXT, "Segoe UI")
    btnCopy  := cg.Add("Button", "x16 y178 w110 h30", "Copy result")
    btnClose := cg.Add("Button", "x246 y178 w90 h30", "Close")

    edIn.OnEvent("Change", Recalc)
    btnCopy.OnEvent("Click", DoCopy)
    btnClose.OnEvent("Click", DoClose)
    cg.OnEvent("Close", DoClose)
    cg.OnEvent("Escape", DoClose)

    ArchiveDarkTheme(cg, [edIn])
    THEME_BoldButtons(cg)
    ArchiveCueBanner(edIn, "amount in dollars")
    Recalc()
    cg.Show("w352 h222")
    edIn.Focus()
    StartFetch()
    return

    Result() {
        amount := CALC_Num(edIn.Value)
        if (amount = "")
            return ""
        v := amount
        for f in CALC_Fees()
            v *= f
        return v * rate - CALC_IniNum("Subtract", 150)
    }

    Recalc(*) {
        fees := ""
        for f in CALC_Fees()
            fees .= " × " f
        lblHow.Value := "input" fees " × " Round(rate, 5) " − " CALC_IniNum("Subtract", 150)
        lblRate.Value := "USD→EUR " Round(rate, 5) "  (" rateNote ")"
        r := Result()
        lblOut.Value := (r = "") ? "—" : "€ " CALC_Money(r)
    }

    DoCopy(*) {
        r := Result()
        if (r = "")
            return
        A_Clipboard := Format("{:.2f}", r)
        ToolTip("Copied " Format("{:.2f}", r))
        SetTimer(ClearArchiveTip, -1200)
    }

    ; Async so the window is usable at once; PollFetch picks up the answer.
    StartFetch() {
        rateNote .= ", updating…"
        Recalc()
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("GET", CALC_RATE_URL, true)
            req.SetTimeouts(5000, 5000, 5000, 5000)
            req.Send()
            SetTimer(PollFetch, 100)
        } catch as err {
            FetchFailed("could not start the request: " err.Message)
        }
    }

    PollFetch() {
        static waited := 0
        if !req {
            SetTimer(PollFetch, 0)
            return
        }
        done := false
        try done := req.WaitForResponse(0)
        catch as err {
            SetTimer(PollFetch, 0), waited := 0
            FetchFailed(err.Message)
            return
        }
        if !done {
            waited += 100
            if (waited < 15000)
                return
            SetTimer(PollFetch, 0), waited := 0
            FetchFailed("timed out")
            return
        }
        SetTimer(PollFetch, 0), waited := 0
        body := "", status := 0, m := 0, d := 0
        try status := req.Status, body := req.ResponseText
        req := 0
        if (status != 200 || !RegExMatch(body, '"EUR"\s*:\s*([\d.]+)', &m) || Number(m[1]) <= 0) {
            FetchFailed("HTTP " status)
            return
        }
        RegExMatch(body, '"date"\s*:\s*"([\d-]+)"', &d)
        rate := Number(m[1])
        day  := d ? d[1] : FormatTime(, "yyyy-MM-dd")
        rateNote := "ECB " day
        try IniWrite(rate, MMA_CFG, "Calculator", "UsdToEur")
        try IniWrite(day, MMA_CFG, "Calculator", "RateDate")
        LOGI("calc", "USD→EUR " rate " (" day ")")
        if CALC_WIN
            Recalc()
    }

    FetchFailed(why) {
        req := 0
        rateNote := (rateDate != "" ? "saved " rateDate : "default") " — live rate unavailable"
        LOGW("calc", "could not fetch the USD→EUR rate (" why ") — using " rate)
        if CALC_WIN
            Recalc()
    }

    DoClose(*) {
        global CALC_WIN
        SetTimer(PollFetch, 0)
        req := 0
        CALC_WIN := 0
        cg.Destroy()
    }
}
