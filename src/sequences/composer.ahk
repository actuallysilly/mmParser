; Search area covers the Aあ + ⋮ icon strip
; Background in this region is 0x262335; icons are grey (~0x808080)
GREY2_X1 := 605
GREY2_Y1 := 828
GREY2_X2 := 685
GREY2_Y2 := 870

DebugGreySearch() {
    global GREY2_X1, GREY2_Y1, GREY2_X2, GREY2_Y2
    CoordMode "Pixel", "Screen"
    pos := FindNthColor(2, 0x808080, GREY2_X1, GREY2_Y1, GREY2_X2, GREY2_Y2, 60, 10)
    if !pos {
        ToolTip "Not found"
        SetTimer(() => ToolTip(), -3000)
        return
    }
    ToolTip "Found at " pos[1] "," pos[2]
    SetTimer(() => ToolTip(), -3000)
    CoordMode "Mouse", "Screen"
    MouseMove pos[1], pos[2]
}

ClickSecondGrey() {
    global GREY2_X1, GREY2_Y1, GREY2_X2, GREY2_Y2
    CoordMode "Pixel", "Screen"
    pos := FindNthColor(2, 0x808080, GREY2_X1, GREY2_Y1, GREY2_X2, GREY2_Y2, 60, 10)
    if !pos
        return
    CoordMode "Mouse", "Screen"
    MouseMove pos[1], pos[2]
    Click
    CoordMode "Mouse", "Window"
}
