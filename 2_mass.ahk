#Requires AutoHotkey v2.0
#SingleInstance Force
; Model 2. This file is DATA: the three mN blocks below hold the message text
; and nothing else. Follow-ups, alts, branches, PPV and the __mm hotstring are
; shared behaviour and live in mass_runtime.ahk — do not copy them back in here.
#Include "mass_runtime.ahk"

; which of the three blocks the hotkeys act on; mass_gui rewrites this line
massNo := 2
modelFileNo := 2

m1 := {
mass: "",
fu1: "",
fu1_5: "",
fu1_7: "",

fu2: "",
fu2_5: "",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

m2 := {
mass: "Beach or bedroom tonight? 🏖️",
fu1: "I've been going back and forth on it all day",
fu1_5: "",
fu1_7: "",

fu2: "Because one of them involves a lot less clothing",
fu2_5: "",
fu2_7: "",

fu3: "So which is it, before I pick for you? 😌",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "Honestly I've changed my mind about six times since this morning",
fu1_alt1: "You get to decide, I'm useless at picking",
fu1_alt2: "",

fu2_alt0: "One of those options has a strict no-clothing policy`nI'll let you guess which",
fu2_alt1: "Fair warning though`nOnly one of them has a door that locks`nChoose carefully x",
fu2_alt2: "",

fu3_alt0: "Don't leave me hanging, I'm already halfway packed",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

m3 := {
mass: "",
fu1: "",
fu1_5: "",
fu1_7: "",

fu2: "",
fu2_5: "",
fu2_7: "",

fu3: "",
fu3_5: "",
fu3_7: "",

ppv_base: "",
ppv_f1: "",
ppv_f2: "",
ppv_f3: "",

br1_name: "",
br1_fu1: "",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "",
br2_fu1: "",
br2_fu2: "",
br2_fu3: "",
br2_ppv: "",

br3_name: "",
br3_fu1: "",
br3_fu2: "",
br3_fu3: "",
br3_ppv: "",

fu1_alt0: "",
fu1_alt1: "",
fu1_alt2: "",

fu2_alt0: "",
fu2_alt1: "",
fu2_alt2: "",

fu3_alt0: "",
fu3_alt1: "",
fu3_alt2: "",

altGui: ""
}

; Binds every [mass.2] key hotkeys.ahk declares, applies the Mouse-control
; setting, and starts the active-model gating. See mass_runtime.ahk.
MassInit(2)
