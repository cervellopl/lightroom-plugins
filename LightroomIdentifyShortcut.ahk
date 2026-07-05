#Requires AutoHotkey v2.0
#SingleInstance Force
;------------------------------------------------------------------------------
; LightroomIdentifyShortcut.ahk   (self-diagnosing build)
;
; Gives the "Plant & Mushroom Tagger" plugin a keyboard shortcut, since the
; Lightroom SDK cannot register hotkeys itself.
;
;   Ctrl + Alt + I  ->  run "Identify Plant / Mushroom..."
;   Ctrl + Alt + J  ->  DIAGNOSTICS (shows AHK version + Lightroom window info)
;
; REQUIRES AutoHotkey **v2**. If you have v1, this file will not run. Check with
; Ctrl+Alt+J, or right-click the tray icon -> it must say "AutoHotkey v2".
;   Install v2:  winget install AutoHotkey.AutoHotkey
;------------------------------------------------------------------------------

; Trailing "..." is often rendered by apps as a single "…" glyph, so we try
; several spellings of the item text.
MENU_ITEM_VARIANTS := [
    "Identify Plant / Mushroom...",
    "Identify Plant / Mushroom" . Chr(0x2026),   ; real ellipsis …
    "Identify Plant / Mushroom"
]

; Confirm the script actually loaded.
TrayTip("Hotkey loaded: Ctrl+Alt+I", "Plant & Mushroom Tagger")

FindLightroom() {
    if WinExist("ahk_exe Lightroom.exe")
        return "ahk_exe Lightroom.exe"
    if WinExist("Lightroom Classic")
        return "Lightroom Classic"
    if WinExist("Lightroom")
        return "Lightroom"
    return ""
}

; ----- Ctrl+Alt+I : run the identification command --------------------------
^!i:: {
    global MENU_ITEM_VARIANTS
    win := FindLightroom()
    if (win = "") {
        MsgBox("Lightroom window not found.`n`nIs Lightroom Classic running?`nPress Ctrl+Alt+J for details.",
               "Plant & Mushroom Tagger", "Iconx")
        return
    }
    WinActivate(win)
    WinWaitActive(win, , 2)

    lastErr := ""
    ; NOTE: v2 array iteration needs TWO vars (index, value); a single var
    ; yields the index, not the string.
    for _, menu in ["Library", "File"] {
        for _, item in MENU_ITEM_VARIANTS {
            try {
                MenuSelect(win, , menu, "Plug-in Extras", item)
                return                       ; success
            } catch as e {
                lastErr := e.Message
            }
        }
    }
    MsgBox("Found Lightroom, but could not select the menu item.`n`n"
         . "Last error: " lastErr "`n`n"
         . "Likely cause: Lightroom's menus are not standard Windows menus on "
         . "this build, so MenuSelect can't reach them. Tell Claude this and "
         . "we'll switch to a UI-Automation approach.",
           "Plant & Mushroom Tagger", "Iconx")
}

; ----- Ctrl+Alt+J : diagnostics ---------------------------------------------
^!j:: {
    info := "AutoHotkey version: " A_AhkVersion "`n"
          . "(must start with 2)`n`n"
    win := FindLightroom()
    if (win = "") {
        info .= "No Lightroom window found.`n"
              . "Tried: ahk_exe Lightroom.exe, 'Lightroom Classic', 'Lightroom'."
        MsgBox(info, "Diagnostics", "Iconi")
        return
    }
    info .= "Matched window by: " win "`n"
          . "Title: " WinGetTitle(win) "`n"
          . "Class: " WinGetClass(win) "`n"
          . "Exe:   " WinGetProcessName(win) "`n"
    MsgBox(info, "Diagnostics", "Iconi")
}
