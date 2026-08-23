#Requires AutoHotkey v2.0
; ═══════════════════════════════════════════════════════════════════════════════
;  json_test.ahk — prove src\vendor\json.ahk before the message library depends
;  on it. Run it; it prints to stdout and exits 1 on any failure.
;
;  The cases that matter are the ones MMA's own data will hit: quotes and
;  backslashes inside message text, embedded newlines (every multiline field),
;  emoji (they are all over the masses), and round-tripping.
; ═══════════════════════════════════════════════════════════════════════════════

#Include "../../src/vendor/json.ahk"

pass := 0, fail := 0

Out(s) {
    FileAppend s "`n", "*"
}

Check(name, got, want) {
    global pass, fail
    if (got == want) {
        pass++
        return
    }
    fail++
    Out("FAIL  " name)
    Out("      want: " StrReplace(StrReplace(want, "`n", "\n"), "`r", "\r"))
    Out("      got:  " StrReplace(StrReplace(String(got), "`n", "\n"), "`r", "\r"))
}

Throws(name, fn) {
    global pass, fail
    try {
        fn()
    } catch {
        pass++
        return
    }
    fail++
    Out("FAIL  " name " — expected a throw, got none")
}

; ── scalars ──────────────────────────────────────────────────────────────────
Check("int",        JSON.Parse("42"),        42)
Check("neg int",    JSON.Parse("-7"),        -7)
Check("float",      JSON.Parse("3.5"),       3.5)
Check("exp",        JSON.Parse("1e3"),       1000.0)
Check("true",       JSON.Parse("true"),      1)
Check("false",      JSON.Parse("false"),     0)
Check("null",       JSON.Parse("null"),      "")
Check("plain str",  JSON.Parse('"hi"'),      "hi")

; ── string escapes, both directions ──────────────────────────────────────────
Check("esc quote",   JSON.Parse('"say \"hi\""'),  'say "hi"')
Check("esc bslash",  JSON.Parse('"a\\b"'),        "a\b")
Check("esc newline", JSON.Parse('"a\nb"'),        "a`nb")
Check("esc crlf",    JSON.Parse('"a\r\nb"'),      "a`r`nb")
Check("esc tab",     JSON.Parse('"a\tb"'),        "a`tb")
Check("esc slash",   JSON.Parse('"a\/b"'),        "a/b")
Check("esc unicode", JSON.Parse('"\u0041\u00e9"'), "Aé")

Check("quote out",  JSON.Stringify('say "hi"'),  '"say \"hi\""')
Check("bslash out", JSON.Stringify("a\b"),       '"a\\b"')
Check("nl out",     JSON.Stringify("a`nb"),      '"a\nb"')
Check("crlf out",   JSON.Stringify("a`r`nb"),    '"a\r\nb"')
Check("emoji out",  JSON.Stringify("hey 🍑"),    '"hey 🍑"')   ; literal, not \u

; ── containers ───────────────────────────────────────────────────────────────
o := JSON.Parse('{"a":1,"b":[1,2,3],"c":{"d":"x"}}')
Check("obj scalar",  o["a"],            1)
Check("obj array",   o["b"].Length,     3)
Check("obj nested",  o["c"]["d"],       "x")
Check("empty obj",   JSON.Stringify(Map()),  "{}")
Check("empty arr",   JSON.Stringify([]),     "[]")

; Keys come out SORTED and therefore byte-stable, whatever order they went in —
; AHK's Map does not promise an enumeration order, and an unstable one would make
; every masses.json diff reshuffle forty fields. See _StrMap.
Check("key order",   JSON.Stringify(Map("z", 1, "a", 2)),   '{"a":2,"z":1}')
Check("key order 2", JSON.Stringify(Map("a", 2, "z", 1)),   '{"a":2,"z":1}')
Check("sort is ordinal", JSON.Stringify(Map("b", 1, "A", 2)), '{"A":2,"b":1}')

; ── strictness: silence here would corrupt the library ───────────────────────
Throws("trailing comma obj", () => JSON.Parse('{"a":1,}'))
Throws("trailing comma arr", () => JSON.Parse('[1,2,]'))
Throws("unquoted key",       () => JSON.Parse('{a:1}'))
Throws("single quotes",      () => JSON.Parse("{'a':1}"))
Throws("trailing data",      () => JSON.Parse('{"a":1} junk'))
Throws("unterminated str",   () => JSON.Parse('"abc'))
Throws("bad \\u",            () => JSON.Parse('"\uZZZZ"'))
Throws("bare word",          () => JSON.Parse('nope'))

; ── round trip, with the shapes MMA actually stores ──────────────────────────
hard := Map(
    "mass",  'She said "yes" — then 🍒 winked',
    "fu1",   "line one`nline two`r`nline three",
    "fu2",   "back\slash and a `t tab",
    "empty", "",
    "path",  "C:\Users\Silly\file.ahk")
rt := JSON.Parse(JSON.Stringify(hard, "  "))
for k, v in hard
    Check("roundtrip " k, rt[k], v)

deep := Map("models", [Map("no", 1, "masses", [hard, Map(), Map("x", "y")])])
rt2  := JSON.Parse(JSON.Stringify(deep, "  "))
Check("deep mass",  rt2["models"][1]["masses"][1]["mass"],  hard["mass"])
Check("deep empty", rt2["models"][1]["masses"][2].Count,    0)
Check("deep tail",  rt2["models"][1]["masses"][3]["x"],     "y")

Out("")
Out(pass " passed, " fail " failed")
ExitApp(fail ? 1 : 0)
