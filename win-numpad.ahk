#Requires AutoHotkey v2.0
#SingleInstance Force

; ==================== 配置（win-numpad.ini）====================
global Enable_F_Keys := true
global Enable_Numpad_Keys := true
global Run_As_Admin := true

LoadSettings() {
    global Enable_F_Keys, Enable_Numpad_Keys, Run_As_Admin
    ini := A_ScriptDir "\win-numpad.ini"
    Enable_F_Keys := IniReadBool(ini, "Settings", "Enable_F_Keys", Enable_F_Keys)
    Enable_Numpad_Keys := IniReadBool(ini, "Settings", "Enable_Numpad_Keys", Enable_Numpad_Keys)
    Run_As_Admin := IniReadBool(ini, "Settings", "Run_As_Admin", Run_As_Admin)
}

IniReadBool(ini, section, key, default := false) {
    val := IniRead(ini, section, key, default ? "1" : "0")
    val := StrLower(Trim(val))
    return val = "1" || val = "true" || val = "yes"
}

LoadSettings()

if Run_As_Admin && !A_IsAdmin {
    try {
        Run '*RunAs "' A_ScriptFullPath '"'
    }
    ExitApp
}

; ==================== 全局初始化 ====================
; 提前初始化 UI Automation COM 对象，确保获取按钮坐标时无任何延迟
global uia := ""
try {
    uia := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
} catch Error as err {
    ; 静默忽略，InteractWithButton 内部会尝试重新初始化
}

; 脚本退出时确保恢复系统光标
OnExit(ExitHandler)

ExitHandler(ExitReason, ExitCode) {
    SetSystemCursor(false) ; 恢复系统光标
}

; ==================== 辅助函数 ====================

; 递归查找子窗口句柄
FindChildWindowByClass(parentHwnd, className) {
    hwnd := DllCall("user32\FindWindowEx", "Ptr", parentHwnd, "Ptr", 0, "Str", className, "Ptr", 0, "Ptr")
    if hwnd
        return hwnd
    child := 0
    loop {
        child := DllCall("user32\FindWindowEx", "Ptr", parentHwnd, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
        if !child
            break
        found := FindChildWindowByClass(child, className)
        if found
            return found
    }
    return 0
}

; 核心交互函数
InteractWithButton(index, action) {
    prevDetect := DetectHiddenWindows(true)

    ; 1. 初始化 UI Automation COM 对象 (如果全局初始化失败，则在这里尝试重新初始化)
    global uia
    if !uia {
        try {
            uia := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
        } catch Error as err {
            Tip("无法初始化 UI Automation")
            DetectHiddenWindows(prevDetect)
            return
        }
    }

    ; 2. 寻找副屏任务栏
    hwndSecondary := WinExist("ahk_class Shell_SecondaryTrayWnd")
    if !hwndSecondary {
        hwndSecondary := DllCall("user32\FindWindowW", "Str", "Shell_SecondaryTrayWnd", "Ptr", 0, "Ptr")
    }

    if !hwndSecondary {
        Tip("未找到副屏任务栏（请确保已连接双屏并开启了副屏任务栏）")
        DetectHiddenWindows(prevDetect)
        return
    }

    ; 3. 递归寻找 MSTaskListWClass 控件（副屏应用按钮列表容器）
    hwndTaskList := FindChildWindowByClass(hwndSecondary, "MSTaskListWClass")
    if !hwndTaskList {
        Tip("未找到副屏任务栏应用列表控件")
        DetectHiddenWindows(prevDetect)
        return
    }

    ; 4. 获取 UIA 元素并查找按钮
    try {
        ; ElementFromHandle (IUIAutomation vtable index 6)
        taskListElementPtr := 0
        ComCall(6, uia, "ptr", hwndTaskList, "ptr*", &taskListElementPtr)
        if !taskListElementPtr {
            DetectHiddenWindows(prevDetect)
            return
        }
        taskListElement := ComValue(0xD, taskListElementPtr)
        
        ; CreateTrueCondition (IUIAutomation vtable index 21)
        trueConditionPtr := 0
        ComCall(21, uia, "ptr*", &trueConditionPtr)
        if !trueConditionPtr {
            DetectHiddenWindows(prevDetect)
            return
        }
        trueCondition := ComValue(0xD, trueConditionPtr)
        
        ; FindAll (IUIAutomationElement vtable index 6)
        ; TreeScope_Children := 0x2 (直接子元素)
        elementArrayPtr := 0
        ComCall(6, taskListElement, "int", 0x2, "ptr", trueCondition, "ptr*", &elementArrayPtr)
        if !elementArrayPtr {
            DetectHiddenWindows(prevDetect)
            return
        }
        elementArray := ComValue(0xD, elementArrayPtr)
        
        ; 获取数组长度 (IUIAutomationElementArray vtable index 3)
        length := 0
        ComCall(3, elementArray, "int*", &length)
        if length == 0 {
            Tip("副屏任务栏没有应用按钮")
            DetectHiddenWindows(prevDetect)
            return
        }
        
        ; 过滤出 ControlType == 50000 (Button) 或 50011 (Group，当有多个窗口时会变为Group) 的元素
        buttons := []
        loop length {
            elementPtr := 0
            ComCall(4, elementArray, "int", A_Index - 1, "ptr*", &elementPtr)
            if elementPtr {
                element := ComValue(0xD, elementPtr)
                ; get_CurrentControlType (IUIAutomationElement vtable index 21)
                controlType := 0
                ComCall(21, element, "int*", &controlType)
                if controlType == 50000 || controlType == 50011 {
                    buttons.Push(element)
                }
            }
        }
        
        if index < 1 || index > buttons.Length {
            Tip("副屏任务栏只有 " buttons.Length " 个应用，没有第 " index " 个")
            DetectHiddenWindows(prevDetect)
            return
        }
        
        ; 获取目标按钮
        targetBtn := buttons[index]
        
        ; 获取其边界矩形 (get_CurrentBoundingRectangle vtable index 43)
        rect := Buffer(16, 0)
        ComCall(43, targetBtn, "ptr", rect)
        left := NumGet(rect, 0, "Int")
        top := NumGet(rect, 4, "Int")
        right := NumGet(rect, 8, "Int")
        bottom := NumGet(rect, 12, "Int")
        
        ; 计算中心坐标
        x := (left + right) // 2
        y := (top + bottom) // 2
        
        ; 5. 极速物理模拟点击 (0ms 延迟，完美兼容所有修饰键)
        SimulateClick(x, y, action)
        
    } catch Error as err {
        Tip("操作失败: " err.Message)
    }
    DetectHiddenWindows(prevDetect)
}

; 极速物理模拟点击并恢复鼠标位置 (内核级别 DllCall + 全局隐藏光标方案)
SimulateClick(x, y, action) {
    ; 1. 隐藏系统光标，防止移动时闪烁
    SetSystemCursor(true)
    
    try {
        ; 获取原始鼠标位置
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt.Ptr)
        origX := NumGet(pt, 0, "Int")
        origY := NumGet(pt, 4, "Int")
        
        ; 2. 瞬间移动鼠标到目标位置并点击
        ; #^ / #+ / #! 热键的修饰键由用户按住，不再 Send，避免与物理按键冲突
        DllCall("user32\SetCursorPos", "Int", x, "Int", y)
        if action == "right" {
            DllCall("user32\mouse_event", "UInt", 0x08, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr", 0) ; Right down
            DllCall("user32\mouse_event", "UInt", 0x10, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr", 0) ; Right up
        } else {
            DllCall("user32\mouse_event", "UInt", 0x02, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr", 0) ; Left down
            DllCall("user32\mouse_event", "UInt", 0x04, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr", 0) ; Left up
        }
        
        ; 3. 瞬间移回鼠标
        DllCall("user32\SetCursorPos", "Int", origX, "Int", origY)
    } finally {
        ; 6. 无论如何都必须恢复系统光标
        SetSystemCursor(false)
    }
}

; 全局隐藏/显示系统光标 (仅替换常规箭头和手型光标，极大减少 DllCall 数量，提升一倍速度)
SetSystemCursor(hide := true) {
    static system_cursors := [32512, 32649] ; OCR_NORMAL (常规箭头), OCR_HAND (手型光标)
    static h_blank := 0
    
    if hide {
        if !h_blank {
            andMask := Buffer(128, 0xFF)
            xorMask := Buffer(128, 0x00)
            h_blank := DllCall("CreateCursor", "Ptr", 0, "Int", 0, "Int", 0, "Int", 32, "Int", 32, "Ptr", andMask, "Ptr", xorMask, "Ptr")
        }
        for id in system_cursors {
            h_dup := DllCall("CopyIcon", "Ptr", h_blank, "Ptr")
            DllCall("SetSystemCursor", "Ptr", h_dup, "UInt", id)
        }
    } else {
        DllCall("SystemParametersInfo", "UInt", 0x0057, "UInt", 0, "Ptr", 0, "UInt", 0) ; SPI_SETCURSORS
    }
}

Tip(msg) {
    ToolTip msg
    SetTimer () => ToolTip(), -2000
}

; ==================== 热键绑定 ====================

#HotIf Enable_F_Keys

; 1. Win + F1~F10 (对应 Win + 1~0)
#F1::InteractWithButton(1, "normal")
#F2::InteractWithButton(2, "normal")
#F3::InteractWithButton(3, "normal")
#F4::InteractWithButton(4, "normal")
#F5::InteractWithButton(5, "normal")
#F6::InteractWithButton(6, "normal")
#F7::InteractWithButton(7, "normal")
#F8::InteractWithButton(8, "normal")
#F9::InteractWithButton(9, "normal")
#F10::InteractWithButton(10, "normal")

; 2. Win + Alt + F1~F10 (对应 Win + Alt + 1~0，右键菜单/Jump List)
#!F1::InteractWithButton(1, "right")
#!F2::InteractWithButton(2, "right")
#!F3::InteractWithButton(3, "right")
#!F4::InteractWithButton(4, "right")
#!F5::InteractWithButton(5, "right")
#!F6::InteractWithButton(6, "right")
#!F7::InteractWithButton(7, "right")
#!F8::InteractWithButton(8, "right")
#!F9::InteractWithButton(9, "right")
#!F10::InteractWithButton(10, "right")

; 3. Win + Ctrl + F1~F10 (对应 Win + Ctrl + 1~0，切换到该应用的上一个活动窗口)
#^F1::InteractWithButton(1, "ctrl")
#^F2::InteractWithButton(2, "ctrl")
#^F3::InteractWithButton(3, "ctrl")
#^F4::InteractWithButton(4, "ctrl")
#^F5::InteractWithButton(5, "ctrl")
#^F6::InteractWithButton(6, "ctrl")
#^F7::InteractWithButton(7, "ctrl")
#^F8::InteractWithButton(8, "ctrl")
#^F9::InteractWithButton(9, "ctrl")
#^F10::InteractWithButton(10, "ctrl")

; 4. Win + Shift + F1~F10 (对应 Win + Shift + 1~0，打开该应用的新实例)
#+F1::InteractWithButton(1, "shift")
#+F2::InteractWithButton(2, "shift")
#+F3::InteractWithButton(3, "shift")
#+F4::InteractWithButton(4, "shift")
#+F5::InteractWithButton(5, "shift")
#+F6::InteractWithButton(6, "shift")
#+F7::InteractWithButton(7, "shift")
#+F8::InteractWithButton(8, "shift")
#+F9::InteractWithButton(9, "shift")
#+F10::InteractWithButton(10, "shift")

#HotIf


#HotIf Enable_Numpad_Keys

; 5. Win + Numpad1~Numpad0 (对应 Win + 1~0)
#Numpad1::InteractWithButton(1, "normal")
#Numpad2::InteractWithButton(2, "normal")
#Numpad3::InteractWithButton(3, "normal")
#Numpad4::InteractWithButton(4, "normal")
#Numpad5::InteractWithButton(5, "normal")
#Numpad6::InteractWithButton(6, "normal")
#Numpad7::InteractWithButton(7, "normal")
#Numpad8::InteractWithButton(8, "normal")
#Numpad9::InteractWithButton(9, "normal")
#Numpad0::InteractWithButton(10, "normal")

; 6. Win + Alt + Numpad1~Numpad0 (对应 Win + Alt + 1~0)
#!Numpad1::InteractWithButton(1, "right")
#!Numpad2::InteractWithButton(2, "right")
#!Numpad3::InteractWithButton(3, "right")
#!Numpad4::InteractWithButton(4, "right")
#!Numpad5::InteractWithButton(5, "right")
#!Numpad6::InteractWithButton(6, "right")
#!Numpad7::InteractWithButton(7, "right")
#!Numpad8::InteractWithButton(8, "right")
#!Numpad9::InteractWithButton(9, "right")
#!Numpad0::InteractWithButton(10, "right")

; 7. Win + Ctrl + Numpad1~Numpad0 (对应 Win + Ctrl + 1~0)
#^Numpad1::InteractWithButton(1, "ctrl")
#^Numpad2::InteractWithButton(2, "ctrl")
#^Numpad3::InteractWithButton(3, "ctrl")
#^Numpad4::InteractWithButton(4, "ctrl")
#^Numpad5::InteractWithButton(5, "ctrl")
#^Numpad6::InteractWithButton(6, "ctrl")
#^Numpad7::InteractWithButton(7, "ctrl")
#^Numpad8::InteractWithButton(8, "ctrl")
#^Numpad9::InteractWithButton(9, "ctrl")
#^Numpad0::InteractWithButton(10, "ctrl")

; Win+Shift+Numpad 因 Windows 在按住 Shift 时强制把小键盘映射为方向键，无法可靠拦截，已放弃。
; 新实例请用 Win+Shift+F1~F10。

#HotIf
