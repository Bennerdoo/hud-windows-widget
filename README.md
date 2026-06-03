# 64-Bit Windows Assembly Performance HUD

An ultra-lightweight, native, borderless desktop performance overlay widget written in x86-64 assembly language. It queries kernel statistics for CPU load and RAM status every second, formatting and displaying them using raw Windows API and GDI calls with near 0% execution overhead.

---

## Technical Architecture & Core Principles

### 1. Win64 Calling Convention (ABI)
In the x86-64 Windows environment, all API calls must adhere to the Microsoft x64 calling convention:
* **Register Parameters**: The first 4 integer or pointer arguments are passed in registers in left-to-right order:
  * `RCX` (1st parameter)
  * `RDX` (2nd parameter)
  * `R8` (3rd parameter)
  * `R9` (4th parameter)
* **Stack Parameters**: Any additional parameters (5th and beyond) must be pushed onto the stack from right to left (stored at offsets starting at `[RSP + 32]`).
* **Shadow Space (Home Space)**: The caller must allocate **32 bytes** of stack space (immediately above the return address) before calling a function. Even if the function takes fewer than 4 arguments, this space is reserved for the callee to spill registers `RCX`, `RDX`, `R8`, and `R9` if needed.
* **Stack Alignment**: The stack pointer (`RSP`) **must be 16-byte aligned** before any `CALL` instruction is executed. Since a `CALL` instruction pushes an 8-byte return address, the stack at the entry of a function is offset by 8 bytes (`16N + 8`). The function must adjust the stack to restore 16-byte alignment before making any nested calls.
* **Non-volatile Registers**: Registers `RBX`, `RBP`, `RDI`, `RSI`, `R12`, `R13`, `R14`, and `R15` are non-volatile and must be preserved across function calls.

---

## Detailed Code Breakdown (`hud.asm`)

### 1. External Windows API Declarations
```assembly
extern GetModuleHandleA
extern RegisterClassExA
...
extern ExitProcess
```
* **What it does**: Informs the NASM assembler that these symbols are defined elsewhere (inside the system DLLs).
* **Why**: The GoLink linker resolves these symbols dynamically at link-time directly from Windows DLLs (`kernel32.dll`, `user32.dll`, `gdi32.dll`), avoiding the need for static C library imports.

---

### 2. Data Segment (`section .data`)
```assembly
section .data
    className db "PerfHUDClass", 0
    windowName db "Performance HUD", 0
    fontName db "Segoe UI", 0

    align 8
    wndClass:
        dd 80                      ; cbSize = 80
        dd 3                       ; style = CS_HREDRAW | CS_VREDRAW
        dq WndProc                 ; lpfnWndProc
        dd 0                       ; cbClsExtra
        dd 0                       ; cbWndExtra
        dq 0                       ; hInstance
        dq 0                       ; hIcon
        dq 0                       ; hCursor
        dq 0                       ; hbrBackground
        dq 0                       ; lpszMenuName
        dq className               ; lpszClassName
        dq 0                       ; hIconSm
```
* **`align 8`**: Ensures that the `wndClass` structure starts on an 8-byte aligned memory address. Without this, structure offsets might fall on odd addresses, causing performance penalties or alignment-related crashes during Windows API calls like `RegisterClassExA`.
* **`wndClass` (`WNDCLASSEXA` layout)**:
  * `cbSize` (Double Word, 4 bytes): Set to 80 (size of structure in 64-bit).
  * `style` (Double Word, 4 bytes): `CS_HREDRAW | CS_VREDRAW` (values 1 and 2, summed to 3) forces repainting of the entire window if it is resized horizontally or vertically.
  * `lpfnWndProc` (Quad Word, 8 bytes): Holds the pointer to the window message handler callback subroutine (`WndProc`).
  * `cbClsExtra` & `cbWndExtra` (4 bytes each): Set to 0. No extra memory bytes needed.
  * `hInstance` (8 bytes): Initialized dynamically at runtime with the handle of the executing process module.
  * `lpszClassName` (8 bytes): Pointer to the null-terminated string `"PerfHUDClass"`. Windows uses this string to map window instances to their registered class settings.

---

### 3. BSS Segment (`section .bss`)
```assembly
section .bss
    alignb 8
    hInstance resq 1
    hWnd resq 1
    msgBuffer resb 48      ; MSG structure (48 bytes)
    paintStruct resb 72    ; PAINTSTRUCT structure (72 bytes)
    rect resb 16           ; RECT structure (16 bytes)
    memStatus resb 64      ; MEMORYSTATUSEX structure (64 bytes)
    ...
```
* **What it does**: Reserves space in memory for uninitialized variables.
* **Why**: Memory is allocated at program startup without inflating the size of the compiled disk executable.
* **`alignb 8`**: Align the BSS segment to 8-byte boundaries. Windows expects API structures (like `MSG` at 48 bytes, `PAINTSTRUCT` at 72 bytes, `RECT` at 16 bytes, and `MEMORYSTATUSEX` at 64 bytes) to be naturally aligned.

---

### 4. Entry Point (`Start`)
```assembly
Start:
    push rbp
    mov rbp, rsp
    sub rsp, 144
    mov [rsp + 128], rbx
```
* **What it does**: 
  1. Sets up the stack frame using `RBP` as the base pointer.
  2. Allocates `144` bytes of stack space.
  3. Saves the non-volatile register `RBX` at offset `[rsp + 128]` inside the stack frame.
* **Why**: 
  * Stack alignment calculation: The stack starts at `16N + 8` on entry. Pushing `RBP` shifts it to `16N`. Allocating `144` bytes (a multiple of 16) keeps it at `16M`, which is perfectly aligned for nested function calls.
  * The register `RBX` is saved inline rather than using `push rbx`. Doing `push` after allocating the stack frame would break the 16-byte alignment boundary.

```assembly
    xor rcx, rcx            ; GetModuleHandleA(NULL)
    call GetModuleHandleA
    mov [hInstance], rax
    mov [wndClass + 24], rax ; Set wndClass.hInstance (offset 24)
```
* **What it does**: Obtains the module handle of the executing program and stores it in the `WNDCLASSEX` structure.
* **Why**: An application must associate its window class with the module that defines the window procedure.

```assembly
    mov rcx, wndClass
    call RegisterClassExA
```
* **What it does**: Registers the window class (`wndClass`) with the Windows OS.
* **Why**: Windows requires every window to belong to a registered class that dictates behavior and callbacks.

```assembly
    mov rcx, 0
    call GetSystemMetrics
    mov rbx, rax            ; Screen Width
    sub rbx, 270            ; X = ScreenWidth - 250 (width) - 20 (padding)
```
* **What it does**: Queries the screen resolution horizontally using `GetSystemMetrics(SM_CXSCREEN = 0)` to calculate the exact X coordinate for placing the overlay at the top-right corner.

```assembly
    mov rcx, 0x000800A8     ; dwExStyle (WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)
    mov rdx, className
    mov r8, windowName
    mov r9, 0x80000000      ; dwStyle (WS_POPUP - borderless)
    
    mov [rsp + 32], rbx     ; arg 5: X coordinate
    mov qword [rsp + 40], 20 ; arg 6: Y coordinate
    mov qword [rsp + 48], 250 ; arg 7: Width
    mov qword [rsp + 56], 80  ; arg 8: Height
    mov qword [rsp + 64], 0   ; arg 9: hWndParent
    mov qword [rsp + 72], 0   ; arg 10: hMenu
    mov rax, [hInstance]
    mov [rsp + 80], rax      ; arg 11: hInstance
    mov qword [rsp + 88], 0   ; arg 12: lpParam
    call CreateWindowExA
    mov [hWnd], rax
```
* **What it does**: Configures stack parameters and registers, then creates a borderless, click-through overlay window.
* **Why**:
  * **ExStyles**: 
    * `WS_EX_TOPMOST` (`0x08`) ensures it floats above all other games and windows.
    * `WS_EX_LAYERED` (`0x00080000`) allows transparent blending.
    * `WS_EX_TRANSPARENT` (`0x20`) disables mouse hits, allowing click-through behavior.
    * `WS_EX_TOOLWINDOW` (`0x80`) hides the program from the Alt-Tab menu and taskbar.
  * **Arguments**: The first 4 go in `RCX`, `RDX`, `R8`, and `R9`. Arguments 5 through 12 are loaded starting at `[rsp + 32]`, matching the Win64 calling convention stack layout.

```assembly
    mov rcx, [hWnd]
    xor rdx, rdx
    mov r8, 200             ; Opacity ~78% (200/255)
    mov r9, 2               ; LWA_ALPHA
    call SetLayeredWindowAttributes
```
* **What it does**: Applies the alpha opacity value to the layered window handle.

```assembly
    mov rcx, [hWnd]
    mov rdx, 5              ; SW_SHOW
    call ShowWindow
    
    mov rcx, [hWnd]
    call UpdateWindow
```
* **What it does**: Displays the window on screen and triggers an initial system paint event.

---

### 5. Non-Blocking Message Loop (`MessageLoop`)
```assembly
MessageLoop:
    lea rcx, [msgBuffer]
    xor rdx, rdx
    xor r8, r8
    xor r9, r9
    mov qword [rsp + 32], 1 ; PM_REMOVE
    call PeekMessageA
    
    test rax, rax
    jz .no_message
    
    mov eax, [msgBuffer + 8] ; msgBuffer.message offset is 8
    cmp eax, 0x0012         ; WM_QUIT
    je .exit_loop
    
    lea rcx, [msgBuffer]
    call TranslateMessage
    lea rcx, [msgBuffer]
    call DispatchMessageA
    jmp MessageLoop
```
* **What it does**: Checks the Windows thread message queue.
* **Why**: Uses `PeekMessageA` (non-blocking) rather than `GetMessageA` (blocking). This allows the thread to continuously poll performance metrics and execute system rendering ticks even when no user inputs or window events are occurring.

```assembly
.no_message:
    call UpdateMetrics
    
    mov rcx, [hWnd]
    xor rdx, rdx            ; NULL (invalidate entire window)
    mov r8, 1               ; TRUE (erase background)
    call InvalidateRect
    
    mov rcx, 1000           ; Sleep 1 second
    call Sleep
    jmp MessageLoop
```
* **What it does**: When no OS messages exist, it updates CPU/RAM counts, invalidates the window client rect to force GDI to repaint (`WM_PAINT`), sleeps for `1000` milliseconds to save battery and CPU overhead, and loops back.

---

### 6. Metrics Gathering (`UpdateMetrics`)
```assembly
UpdateMetrics:
    push rbp
    mov rbp, rsp
    sub rsp, 48             ; Reserve aligned stack space
```
* **Why `sub rsp, 48`**: Sets up 32 bytes of shadow space plus 16 bytes of padding to align the stack pointer for external library functions inside `UpdateMetrics`.

```assembly
    mov dword [memStatus], 64 ; dwLength = 64 bytes
    mov rcx, memStatus
    call GlobalMemoryStatusEx
```
* **What it does**: Initializes the length field of the `MEMORYSTATUSEX` structure to 64 bytes and queries the OS for memory load metrics.
* **Why**: Windows requires setting `dwLength` to verify structure compatibility.

```assembly
    ; Calculate Free RAM GB = AvailPhys / 1,073,741,824 (1024^3)
    mov rax, [memStatus + 16] ; ullAvailPhys
    mov rcx, 1073741824
    xor rdx, rdx
    div rcx
    mov [ramGBInt], eax
```
* **What it does**: Divides the available physical bytes by $2^{30}$ (1 GB) to get the integer component. The remainder is kept in `RDX`.

```assembly
    ; Calculate RAM Decimal part: (AvailPhys * 10) / 1,073,741,824 % 10
    mov rax, [memStatus + 16]
    mov rcx, 10
    mul rcx
    mov rcx, 1073741824
    div rcx
    mov rcx, 10
    xor rdx, rdx
    div rcx
    mov [ramGBDec], edx
```
* **What it does**: Multiplies bytes by 10, divides by $2^{30}$, and takes modulo 10 to extract the first digit past the decimal point (e.g., `8.4 GB`).

```assembly
    ; CPU Calculation
    mov rcx, idleTimeNew
    mov rdx, kernelTimeNew
    mov r8, userTimeNew
    call GetSystemTimes
```
* **What it does**: Fetches cumulative processor execution times.
* **Why**: CPU load is calculated dynamically by comparing the delta time of the system states across the 1-second sleep intervals:
  $$\text{TotalDelta} = \text{KernelDelta} + \text{UserDelta}$$
  $$\text{CPU Usage \%} = 100 \times \frac{\text{TotalDelta} - \text{IdleDelta}}{\text{TotalDelta}}$$
* **Division-by-Zero Guard**: If the processor reports `TotalDelta == 0` (no time elapsed), the code jumps to `.cpu_zero` to avoid system interrupts/crashes.

```assembly
.formatting:
    lea rdi, [hudText]
    ; Write "CPU: "
    mov byte [rdi], 'C'
    ...
    call int_to_string
    ...
```
* **What it does**: Manually copies characters and invokes `int_to_string` to format the buffer string `"CPU: XX%\nRAM: X.X GB Free (XX% in use)"`.
* **Why**: Avoids standard C libraries (like `sprintf`), resulting in a tiny executable payload footprint and blazing fast performance.

---

### 7. Integer to ASCII Routine (`int_to_string`)
```assembly
int_to_string:
    push rbx
    push rcx
    push rdx
    mov rbx, 10             ; Divisor = 10
    xor rcx, rcx            ; Digit counter = 0
.push_loop:
    xor rdx, rdx
    div rbx
    add dl, '0'             ; Convert remainder value to ASCII char
    push rdx
    inc rcx
    test eax, eax
    jnz .push_loop
.pop_loop:
    pop rdx
    mov [rdi], dl           ; Write characters left-to-right
    inc rdi
    loop .pop_loop
```
* **What it does**: Converts an integer inside `EAX` to ASCII decimal characters in memory.
* **Why**: Repeated division by 10 extracts decimal digits in reverse order (least significant first). Pushing them to the CPU stack and then popping them writes them in the correct human-readable order.

---

### 8. Windows Message Handler (`WndProc`)
```assembly
WndProc:
    push rbp
    mov rbp, rsp
    sub rsp, 256
    
    mov [rbp - 32], rcx     ; Save hWnd
    mov [rbp - 40], rdx     ; Save uMsg
    mov [rbp - 48], r8      ; Save wParam
    mov [rbp - 56], r9      ; Save lParam
```
* **What it does**: Callback function triggered by Windows. It allocates a stack frame to save incoming message arguments and preserves registers `RBX`, `RSI`, and `RDI`.

```assembly
.on_paint:
    mov rcx, [rbp - 32]
    lea rdx, [paintStruct]
    call BeginPaint
    mov rbx, rax            ; rbx = hDC
```
* **What it does**: Handles `WM_PAINT` by getting a Device Context (`hDC`) to draw inside the window's client bounds.

```assembly
    mov rcx, 0x0018181B     ; COLORREF background brush color (Dark Zinc)
    call CreateSolidBrush
    mov rsi, rax            ; rsi = hBrush
    
    mov rcx, rbx
    lea rdx, [rect]
    mov r8, rsi
    call FillRect
```
* **What it does**: Creates a solid dark brush object to fill the overlay rectangle, styling it like a dark desktop card widget.

```assembly
    mov rcx, 20             ; Height = 20px
    ...
    mov qword [rsp + 32], 700 ; Bold (FW_BOLD)
    ...
    mov qword [rsp + 88], 5   ; CLEARTYPE_QUALITY
    mov rax, fontName
    mov [rsp + 104], rax      ; FaceName = "Segoe UI"
    call CreateFontA
```
* **What it does**: Creates a clean, bold `Segoe UI` font with ClearType smoothing using the 14-parameter API `CreateFontA`.

```assembly
    mov rcx, rbx
    mov rdx, 0x00D4B606     ; Cyan Text color (BBGGRR format)
    call SetTextColor
    
    mov rcx, rbx
    mov rdx, 1              ; TRANSPARENT background mode
    call SetBkMode
```
* **What it does**: Prepares the GDI context to paint cyan text directly on top of the card background without drawing white boxes behind the characters.

```assembly
    add dword [rect], 15    ; rect.left += 15
    add dword [rect + 4], 15 ; rect.top += 15
    
    mov rcx, rbx
    lea rdx, [hudText]
    mov r8, -1              ; Null-terminated text length flag
    lea r9, [rect]
    mov qword [rsp + 32], 0x800 ; DT_NOPREFIX
    call DrawTextA
```
* **What it does**: Adds a 15px inner padding margin to the bounding box and renders the formatted metrics text inside the overlay.

```assembly
    ; Cleanup
    mov rcx, rbx
    mov rdx, rsi            ; Restore font
    call SelectObject
    
    mov rcx, rdi            ; Delete custom font
    call DeleteObject
    
    mov rcx, [rbp - 32]
    lea rdx, [paintStruct]
    call EndPaint
```
* **What it does**: Cleans up brushes and custom fonts, and notifies Windows that painting is complete.
* **Why**: Prevents GDI memory leaks that would otherwise consume system resources and eventually crash the system shell.

```assembly
.on_destroy:
    mov rcx, 0
    call PostQuitMessage
```
* **What it does**: If the window is destroyed, it sends a quit signal to break out of the message loop and shutdown gracefully.

---

## Compiling & Linking Commands

The compilation pipeline is fully automated in `build.ps1`. However, you can run the steps manually from your shell:

### 1. Compile Code via NASM
Generates a 64-bit Windows Object format file (`hud.obj`):
```powershell
.\nasm-2.16.03\nasm.exe -f win64 hud.asm -o build\hud.obj
```

### 2. Link Executable via GoLink
Links system libraries dynamically and establishes the entry point at `Start`:
```powershell
.\golink\GoLink.exe /entry:Start build\hud.obj kernel32.dll user32.dll gdi32.dll /o build\hud.exe
```

### 3. Run Application
```powershell
.\build\hud.exe
```
