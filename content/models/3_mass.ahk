#Requires AutoHotkey v2.0
#SingleInstance Force
; Model 3. This file is DATA: the three mN blocks below hold the message text
; and nothing else. Follow-ups, alts, branches, PPV and the __mm hotstring are
; shared behaviour and live in mass/runtime.ahk — do not copy them back in here.
#Include "../../src/mass/runtime.ahk"

; which of the three blocks the hotkeys act on; mass_gui rewrites this line
massNo := 1
modelFileNo := 3

m1 := {
mass: "Pop or rock music?",
fu1: "But does it really matter when I can rock your body so you can pop a boner for me `;3",
fu1_5: "I really love Arctic Monkeys btw, so rock for me I guess... Btw, what part of me makes you pop a boner?",
fu1_7: "",

fu2: "My supple breasts really >.<...? Well they are massive and warm to the touch.. I can't blame you for obsessively wanting to suck on them.. Would you also pinch them?",
fu2_5: "",
fu2_7: "",

fu3: "Can you imagine how nice it would feel to have my ass on top of your face? I would wiggle it up and down for you so you feel enchanted and enticed 💘... Would you heart skip a beat as your cock follows my rhythm?",
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

m3 := {
mass: "Pop or rock music?",
fu1: "But does it really matter when I can rock your body so you can pop a boner for me `;3",
fu1_5: "I really love Arctic Monkeys btw, so rock for me I guess... Btw, what part of me makes you pop a boner?",
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

br1_name: "Tits",
br1_fu1: "My supple breasts really >.<...? Well they are massive and warm to the touch.. I can't blame you for obsessively wanting to suck on them.. Would you also pinch them?",
br1_fu2: "",
br1_fu3: "",
br1_ppv: "",

br2_name: "Ass",
br2_fu1: "Can you imagine how nice it would feel to have my ass on top of your face? I would wiggle it up and down for you so you feel enchanted and enticed 💘... Would you heart skip a beat as your cock follows my rhythm?",
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

; Binds every [mass.3] key hotkeys.ahk declares, applies the Mouse-control
; setting, and starts the active-model gating. See mass/runtime.ahk.
MassInit(3)
