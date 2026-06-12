chatheight := 100
home := [95, 65]
ppvOpenNotif := [1760, 110]
unreadBtn := [250, 250]

!-::Unread()
+Space::focusAuto()
Down::nextChat()
+Left::Unread()
Up::focusTop()

Ins::DoFu1()
Home::DoFu2()
PgUp::DoFu3()

Del::clickOn(unreadBtn)
End::clickOn(home)
PgDn::clickOn(ppvOpenNotif)