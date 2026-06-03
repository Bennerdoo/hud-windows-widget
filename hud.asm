; ==============================================================================
;                  64-BIT WINDOWS ASSEMBLY PERFORMANCE HUD WIDGET
; ==============================================================================
; Fits the Win64 ABI exactly. Assembled with NASM (-f win64) and linked via GoLink.
; Queries kernel32.dll for system times and memory, formatting metrics via a
; lightweight custom assembly routine, and drawing using GDI (user32/gdi32).
; ==============================================================================

[bits 64]


extern GetModuleHandleA
extern RegisterClassExA
extern CreateWindowExA
extern ShowWindow
extern UpdateWindow
extern PeekMessageA
extern TranslateMessage
extern DispatchMessageA
extern DefWindowProcA
extern PostQuitMessage
extern SetLayeredWindowAttributes
extern GlobalMemoryStatusEx
extern GetSystemTimes
extern Sleep
extern BeginPaint
extern EndPaint
extern GetClientRect
extern SetTextColor
extern SetBkMode
extern CreateSolidBrush
extern CreateFontA
extern SelectObject
extern DeleteObject
extern FillRect
extern DrawTextA
extern ExitProcess
extern GetSystemMetrics
extern InvalidateRect

global Start

; ------------------------------------------------------------------------------
; DATA SEGMENT (Statically defined variables, strings, and structures)
; ------------------------------------------------------------------------------
section .data
    className db "PerfHUDClass", 0
    windowName db "Performance HUD", 0
    fontName db "Segoe UI", 0

    align 8
    ; WNDCLASSEXA structure definition (80 bytes total in Win64)
    wndClass:
        dd 80                      ; cbSize = 80
        dd 3                       ; style = CS_HREDRAW (1) | CS_VREDRAW (2)
        dq WndProc                 ; lpfnWndProc
        dd 0                       ; cbClsExtra
        dd 0                       ; cbWndExtra
        dq 0                       ; hInstance (Set dynamically at runtime)
        dq 0                       ; hIcon
        dq 0                       ; hCursor
        dq 0                       ; hbrBackground
        dq 0                       ; lpszMenuName
        dq className               ; lpszClassName
        dq 0                       ; hIconSm

; ------------------------------------------------------------------------------
; BSS SEGMENT (Uninitialized memory allocated at runtime)
; ------------------------------------------------------------------------------
section .bss
    hInstance resq 1
    hWnd resq 1
    msgBuffer resb 48      ; MSG structure (48 bytes)
    paintStruct resb 72    ; PAINTSTRUCT structure (72 bytes)
    rect resb 16           ; RECT structure (16 bytes)
    memStatus resb 64      ; MEMORYSTATUSEX structure (64 bytes)
    
    ; Calculated metrics storage
    cpuPercent resd 1
    ramPercent resd 1
    ramGBInt resd 1
    ramGBDec resd 1
    
    ; Kernel times for delta CPU calculation (8-byte QWORDs)
    idleTimeOld resq 1
    kernelTimeOld resq 1
    userTimeOld resq 1
    idleTimeNew resq 1
    kernelTimeNew resq 1
    userTimeNew resq 1
    
    ; Text output buffer
    hudText resb 128

; ------------------------------------------------------------------------------
; CODE SEGMENT (Main execution routines)
; ------------------------------------------------------------------------------
section .text

; Entry Point (Start)
Start:
    push rbp
    mov rbp, rsp
    ; Allocate 144 bytes stack frame (multiple of 16 for Win64 ABI stack alignment):
    ; - 32 bytes shadow space for child API calls
    ; - stack arguments (up to 12 arguments for CreateWindowExA)
    ; - space to preserve RBX at [rsp + 128]
    sub rsp, 144
    
    ; Preserve RBX inside the stack frame (avoiding push to maintain stack alignment)
    mov [rsp + 128], rbx
    
    ; 1. Retrieve Current Instance Handle: GetModuleHandleA(NULL)
    xor rcx, rcx            ; RCX = NULL
    call GetModuleHandleA
    mov [hInstance], rax
    mov [wndClass + 24], rax ; Set wndClass.hInstance (offset 24)

    ; 2. Register Custom Window Class: RegisterClassExA(&wndClass)
    mov rcx, wndClass
    call RegisterClassExA
    
    ; 3. Dynamically Calculate Position: GetSystemMetrics(SM_CXSCREEN = 0)
    mov rcx, 0
    call GetSystemMetrics
    mov rbx, rax            ; RBX = Screen Width in pixels
    
    ; Position widget 20px from right margin: X = ScreenWidth - Width(250) - 20 = ScreenWidth - 270
    sub rbx, 270
    
    ; 4. Create Layered Click-Through Overlay: CreateWindowExA
    ; dwExStyle = WS_EX_TOPMOST (0x08) | WS_EX_LAYERED (0x00080000) | WS_EX_TRANSPARENT (0x20) | WS_EX_TOOLWINDOW (0x80)
    mov rcx, 0x000800A8     ; RCX = dwExStyle
    mov rdx, className      ; RDX = lpClassName
    mov r8, windowName      ; R8 = lpWindowName
    mov r9, 0x80000000      ; R9 = dwStyle (WS_POPUP - borderless)
    
    ; CreateWindowExA Stack Arguments (arguments 5 to 12):
    mov [rsp + 32], rbx     ; arg 5: X coordinate
    mov qword [rsp + 40], 20 ; arg 6: Y coordinate (20px from top)
    mov qword [rsp + 48], 250 ; arg 7: Width (250px)
    mov qword [rsp + 56], 80  ; arg 8: Height (80px)
    mov qword [rsp + 64], 0  ; arg 9: hWndParent
    mov qword [rsp + 72], 0  ; arg 10: hMenu
    mov rax, [hInstance]
    mov [rsp + 80], rax     ; arg 11: hInstance
    mov qword [rsp + 88], 0  ; arg 12: lpParam
    
    call CreateWindowExA
    mov [hWnd], rax
    
    ; 5. Set Layered Attributes (Opacity ~78%): SetLayeredWindowAttributes
    ; RCX = hWnd, RDX = crKey(0), R8 = bAlpha(200), R9 = dwFlags(LWA_ALPHA = 2)
    mov rcx, [hWnd]
    xor rdx, rdx
    mov r8, 200
    mov r9, 2
    call SetLayeredWindowAttributes
    
    ; 6. Make Window Visible: ShowWindow(hWnd, SW_SHOW = 5)
    mov rcx, [hWnd]
    mov rdx, 5
    call ShowWindow
    
    ; 7. Force Initial Paint: UpdateWindow(hWnd)
    mov rcx, [hWnd]
    call UpdateWindow

    ; 8. Fetch Baseline Times for CPU Usage Delta Calculations
    mov rcx, idleTimeOld
    mov rdx, kernelTimeOld
    mov r8, userTimeOld
    call GetSystemTimes

; ------------------------------------------------------------------------------
; TIMED/NON-BLOCKING MESSAGE LOOP
; ------------------------------------------------------------------------------
MessageLoop:
    ; Non-blocking check for Windows messages: PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE = 1)
    lea rcx, [msgBuffer]
    xor rdx, rdx            ; hWnd = NULL
    xor r8, r8              ; wMsgFilterMin = 0
    xor r9, r9              ; wMsgFilterMax = 0
    mov qword [rsp + 32], 1 ; arg 5: PM_REMOVE
    call PeekMessageA
    
    test rax, rax           ; Check if message exists
    jz .no_message          ; If no message, skip translation/dispatch
    
    ; Check if message is WM_QUIT (message field is at offset 8 in MSG structure)
    mov eax, [msgBuffer + 8]
    cmp eax, 0x0012         ; WM_QUIT = 0x0012
    je .exit_loop
    
    ; Translate and dispatch message
    lea rcx, [msgBuffer]
    call TranslateMessage
    lea rcx, [msgBuffer]
    call DispatchMessageA
    jmp MessageLoop

.no_message:
    ; Update metrics, invalidate screen rect to force repaint, sleep 1000ms
    call UpdateMetrics
    
    ; Force window repaint: InvalidateRect(hWnd, NULL, TRUE)
    mov rcx, [hWnd]
    xor rdx, rdx            ;lpRect = NULL (repaints entire client rect)
    mov r8, 1               ; bErase = TRUE
    call InvalidateRect
    
    ; Rest cycle: Sleep(1000) keeps overhead near 0%
    mov rcx, 1000           ; 1000 milliseconds
    call Sleep
    jmp MessageLoop

.exit_loop:
    ; Restore preserved registers and terminate
    mov rbx, [rsp + 128]
    mov rsp, rbp
    pop rbp
    
    mov rcx, 0
    call ExitProcess

; ------------------------------------------------------------------------------
; METRICS GATHERING PROCEDURE (Queries Kernel for RAM & CPU values)
; ------------------------------------------------------------------------------
UpdateMetrics:
    push rbp
    mov rbp, rsp
    ; Allocate 48 bytes (multiple of 16 to maintain Win64 ABI stack alignment)
    sub rsp, 48             ; Shadow space + padding
    
    ; ---------------------------
    ; A. Physical RAM Statistics
    ; ---------------------------
    ; MEMORYSTATUSEX is 64 bytes. First DWORD (dwLength) must be set to 64.
    mov dword [memStatus], 64
    mov rcx, memStatus
    call GlobalMemoryStatusEx
    
    ; Read dwMemoryLoad (RAM usage %) at offset 4
    mov eax, [memStatus + 4]
    mov [ramPercent], eax
    
    ; Read ullAvailPhys (Available bytes) at offset 16 (QWORD)
    mov rax, [memStatus + 16]
    
    ; Calculate Integer part of Free GB: AvailPhys / 1,073,741,824 (1024^3)
    mov rcx, 1073741824
    xor rdx, rdx
    div rcx                 ; RAX = Quotient (GB), RDX = Remainder
    mov [ramGBInt], eax
    
    ; Calculate Decimal part of Free GB: (AvailPhys * 10) / 1,073,741,824 % 10
    mov rax, [memStatus + 16]
    mov rcx, 10
    mul rcx                 ; RAX = AvailPhys * 10
    
    mov rcx, 1073741824
    div rcx                 ; RAX = Quotient
    
    mov rcx, 10
    xor rdx, rdx
    div rcx                 ; RDX = RAX % 10
    mov [ramGBDec], edx     ; Save remainder (first decimal digit)

    ; ---------------------------
    ; B. CPU Usage Calculation
    ; ---------------------------
    ; Get current system times
    mov rcx, idleTimeNew
    mov rdx, kernelTimeNew
    mov r8, userTimeNew
    call GetSystemTimes
    
    ; Delta calculations using strictly volatile registers (R8, R9, R10, R11) to avoid pushing/popping
    mov rax, [idleTimeNew]
    sub rax, [idleTimeOld]
    mov r8, rax             ; R8 = IdleDelta
    
    mov rax, [kernelTimeNew]
    sub rax, [kernelTimeOld]
    mov r9, rax             ; R9 = KernelDelta
    
    mov rax, [userTimeNew]
    sub rax, [userTimeOld]
    mov r10, rax            ; R10 = UserDelta
    
    ; Update Old times to New times for next tick
    mov rax, [idleTimeNew]
    mov [idleTimeOld], rax
    mov rax, [kernelTimeNew]
    mov [kernelTimeOld], rax
    mov rax, [userTimeNew]
    mov [userTimeOld], rax
    
    ; Calculate Total Time Delta = KernelDelta + UserDelta
    mov r11, r9
    add r11, r10            ; R11 = TotalDelta
    
    test r11, r11           ; Guard division against 0 deltas
    jz .cpu_zero
    
    ; CPU% = 100 * (TotalDelta - IdleDelta) / TotalDelta
    mov rax, r11
    sub rax, r8             ; RAX = TotalDelta - IdleDelta
    imul rax, 100
    xor rdx, rdx
    div r11                 ; RAX = CPU percentage
    mov [cpuPercent], eax
    jmp .formatting

.cpu_zero:
    mov dword [cpuPercent], 0

    ; ---------------------------
    ; C. Format Output Text String
    ; ---------------------------
.formatting:
    lea rdi, [hudText]       ; RDI points to destination string buffer
    
    ; Write "CPU: "
    mov byte [rdi], 'C'
    mov byte [rdi+1], 'P'
    mov byte [rdi+2], 'U'
    mov byte [rdi+3], ':'
    mov byte [rdi+4], ' '
    add rdi, 5
    
    ; Write CPU percentage
    mov eax, [cpuPercent]
    call int_to_string
    
    ; Append newline "%\nRAM: "
    mov byte [rdi], '%'
    mov byte [rdi+1], 10
    mov byte [rdi+2], 'R'
    mov byte [rdi+3], 'A'
    mov byte [rdi+4], 'M'
    mov byte [rdi+5], ':'
    mov byte [rdi+6], ' '
    add rdi, 7
    
    ; Write Available RAM GB Integer
    mov eax, [ramGBInt]
    call int_to_string
    
    ; Append dot "."
    mov byte [rdi], '.'
    inc rdi
    
    ; Write Available RAM GB Decimal
    mov eax, [ramGBDec]
    call int_to_string
    
    ; Append " GB Free ("
    mov byte [rdi], ' '
    mov byte [rdi+1], 'G'
    mov byte [rdi+2], 'B'
    mov byte [rdi+3], ' '
    mov byte [rdi+4], 'F'
    mov byte [rdi+5], 'r'
    mov byte [rdi+6], 'e'
    mov byte [rdi+7], 'e'
    mov byte [rdi+8], ' '
    mov byte [rdi+9], '('
    add rdi, 10
    
    ; Write RAM load percentage
    mov eax, [ramPercent]
    call int_to_string
    
    ; Append "% in use)" and null terminator
    mov byte [rdi], '%'
    mov byte [rdi+1], ' '
    mov byte [rdi+2], 'i'
    mov byte [rdi+3], 'n'
    mov byte [rdi+4], ' '
    mov byte [rdi+5], 'u'
    mov byte [rdi+6], 's'
    mov byte [rdi+7], 'e'
    mov byte [rdi+8], ')'
    mov byte [rdi+9], 0      ; Null-terminate string

    add rsp, 48
    pop rbp
    ret

; ------------------------------------------------------------------------------
; AUXILIARY STRING PARSING SUBROUTINE
; Converts 32-bit Integer in EAX to Decimal ASCII digits at RDI
; Updates RDI to point to end of string (the new null-character position)
; ------------------------------------------------------------------------------
int_to_string:
    push rbx
    push rcx
    push rdx
    
    mov rbx, 10             ; Divisor
    xor rcx, rcx            ; Digit counter
    
.push_loop:
    xor rdx, rdx
    div rbx                 ; EAX = quotient, EDX = remainder (digit)
    add dl, '0'             ; Convert to ASCII
    push rdx                ; Push digit onto stack
    inc rcx
    test eax, eax           ; Check if quotient is 0
    jnz .push_loop
    
.pop_loop:
    pop rdx
    mov [rdi], dl           ; Write popped digit in correct order
    inc rdi
    loop .pop_loop
    
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------------------------
; WINDOW PROCEDURE CALLBACK (WndProc)
; Handles events. Uses a standard stack frame with RBP pointer and preserves
; RBX, RSI, and RDI registers to comply with Win64 ABI constraints.
; ------------------------------------------------------------------------------
WndProc:
    ; RCX = hWnd, RDX = uMsg, R8 = wParam, R9 = lParam
    push rbp
    mov rbp, rsp
    ; Allocate 256 bytes frame to hold:
    ; - local parameters (hWnd, Msg, etc.)
    ; - register preservation slots
    ; - GDI stack structures and CreateFontA arguments
    ; - 16-byte stack alignment
    sub rsp, 256
    
    ; Save volatile parameters in stack frame
    mov [rbp - 32], rcx     ; Save hWnd
    mov [rbp - 40], rdx     ; Save uMsg
    mov [rbp - 48], r8      ; Save wParam
    mov [rbp - 56], r9      ; Save lParam
    
    ; Save preserved registers in stack frame
    mov [rbp - 8], rbx
    mov [rbp - 16], rsi
    mov [rbp - 24], rdi

    ; Branch on window message
    cmp rdx, 0x000F         ; WM_PAINT = 0x000F
    je .on_paint
    
    cmp rdx, 0x0002         ; WM_DESTROY = 0x0002
    je .on_destroy
    
    ; Default handling: DefWindowProcA(hWnd, Msg, wParam, lParam)
    mov rcx, [rbp - 32]
    mov rdx, [rbp - 40]
    mov r8, [rbp - 48]
    mov r9, [rbp - 56]
    call DefWindowProcA
    jmp .wnd_proc_exit

.on_paint:
    ; 1. Begin Paint: BeginPaint(hWnd, &paintStruct)
    mov rcx, [rbp - 32]
    lea rdx, [paintStruct]
    call BeginPaint
    mov rbx, rax            ; RBX = hDC
    
    ; 2. Fetch Client Rect: GetClientRect(hWnd, &rect)
    mov rcx, [rbp - 32]
    lea rdx, [rect]
    call GetClientRect
    
    ; 3. Draw Solid Zinc Dark Background Card: CreateSolidBrush(0x001B1B18)
    mov rcx, 0x0018181B     ; COLORREF = 0x00BBGGRR -> R=0x1B, G=0x18, B=0x18 (Dark Grey Card)
    call CreateSolidBrush
    mov rsi, rax            ; RSI = hBrush
    
    ; Fill client area: FillRect(hDC, &rect, hBrush)
    mov rcx, rbx
    lea rdx, [rect]
    mov r8, rsi
    call FillRect
    
    ; Clean up solid brush
    mov rcx, rsi
    call DeleteObject
    
    ; 4. Create Custom Font: CreateFontA
    mov rcx, 20             ; Height = 20
    xor rdx, rdx            ; Width = Default
    xor r8, r8              ; Escapement = 0
    xor r9, r9              ; Orientation = 0
    
    ; Load stack arguments (args 5 to 14) onto stack:
    mov qword [rsp + 32], 700 ; arg 5: Weight (FW_BOLD = 700)
    mov qword [rsp + 40], 0   ; arg 6: Italic = FALSE
    mov qword [rsp + 48], 0   ; arg 7: Underline = FALSE
    mov qword [rsp + 56], 0   ; arg 8: StrikeOut = FALSE
    mov qword [rsp + 64], 0   ; arg 9: CharSet (ANSI_CHARSET = 0)
    mov qword [rsp + 72], 0   ; arg 10: OutPrecision = Default
    mov qword [rsp + 80], 0   ; arg 11: ClipPrecision = Default
    mov qword [rsp + 88], 5   ; arg 12: Quality (CLEARTYPE_QUALITY = 5)
    mov qword [rsp + 96], 0   ; arg 13: PitchAndFamily = Default
    mov rax, fontName
    mov [rsp + 104], rax      ; arg 14: FaceName = "Segoe UI"
    
    call CreateFontA
    mov rdi, rax            ; RDI = hFont
    
    ; Select Font: SelectObject(hDC, hFont)
    mov rcx, rbx
    mov rdx, rdi
    call SelectObject
    mov rsi, rax            ; RSI = hOldFont
    
    ; 5. Set Text Color (Cyan): SetTextColor(hDC, COLORREF = 0x00D4B606)
    ; RGB Cyan: R=6 (06), G=182 (B6), B=212 (D4). BBGGRR format = 0x00D4B606
    mov rcx, rbx
    mov rdx, 0x00D4B606
    call SetTextColor
    
    ; Set Text Background to Transparent: SetBkMode(hDC, TRANSPARENT = 1)
    mov rcx, rbx
    mov rdx, 1
    call SetBkMode
    
    ; 6. Draw Metrics Text: DrawTextA(hDC, text, -1, &rect, DT_NOPREFIX = 0x800)
    ; Apply a padding margin inside the card: rect.left += 15, rect.top += 15
    add dword [rect], 15
    add dword [rect + 4], 15
    
    mov rcx, rbx
    lea rdx, [hudText]
    mov r8, -1
    lea r9, [rect]
    mov qword [rsp + 32], 0x00000800 ; arg 5: DT_NOPREFIX
    call DrawTextA
    
    ; 7. GDI Objects Cleanup
    ; Restore old font in DC
    mov rcx, rbx
    mov rdx, rsi
    call SelectObject
    
    ; Delete custom bold font
    mov rcx, rdi
    call DeleteObject
    
    ; 8. Finalize Painting: EndPaint(hWnd, &paintStruct)
    mov rcx, [rbp - 32]
    lea rdx, [paintStruct]
    call EndPaint
    
    xor rax, rax            ; Return 0
    jmp .wnd_proc_exit

.on_destroy:
    ; Send Exit message: PostQuitMessage(0)
    mov rcx, 0
    call PostQuitMessage
    xor rax, rax

.wnd_proc_exit:
    ; Restore preserved registers
    mov rbx, [rbp - 8]
    mov rsi, [rbp - 16]
    mov rdi, [rbp - 24]
    
    mov rsp, rbp
    pop rbp
    ret
