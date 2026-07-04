#Requires AutoHotkey v2.0
;------------------------------------------------------------------------------
; LightroomIdentifyShortcut.ahk
;
; Gives the "Plant & Mushroom Tagger" plugin a keyboard shortcut, since the
; Lightroom SDK cannot register hotkeys itself. This script drives the menu
; item for you.
;
;   Default hotkey:  Ctrl + Alt + I
;
; How to use
;   1. Install AutoHotkey v2:  https://www.autohotkey.com/
;   2. Double-click this .ahk file to run it (a green "H" appears in the tray).
;   3. In Lightroom's Library module, select a photo and press Ctrl+Alt+I.
;   4. To start it automatically with Windows, put a shortcut to this file in:
;         shell:startup     (press Win+R, type that, Enter, drop a shortcut in)
;
; Notes
;   * The menu title below must EXACTLY match the plugin's menu entry
;     ("Identify Plant / Mushroom..."). If you rename it in Info.lua, update it
;     here too.
;   * Lightroom Classic's main executable is Lightroom.exe.
;------------------------------------------------------------------------------

MENU_ITEM := "Identify Plant / Mushroom..."
LR        := "ahk_exe Lightroom.exe"

; ----- Ctrl+Alt+I : run the identification command --------------------------
^!i:: RunIdentify()

RunIdentify() {
    global MENU_ITEM, LR

    if !WinExist(LR) {
        TrayTip("Lightroom is not running.", "Plant & Mushroom Tagger")
        return
    }
    WinActivate(LR)
    WinWaitActive(LR, , 2)

    ; Try the Library menu first, then the File menu (the command lives in
    ; Plug-in Extras under both).
    try {
        MenuSelect(LR, , "Library", "Plug-in Extras", MENU_ITEM)
        return
    }
    try {
        MenuSelect(LR, , "File", "Plug-in Extras", MENU_ITEM)
        return
    }
    TrayTip("Could not find the menu item.`nMake sure you are in the Library module.",
            "Plant & Mushroom Tagger")
}
