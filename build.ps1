# ==============================================================================
#                  POWERSHELL BUILD & AUTOMATION SCRIPT
# ==============================================================================
# Automates compiling and linking the 64-bit Assembly Performance HUD widget.
# Usage: .\build.ps1
# ==============================================================================

# Ensure error-handling is strict
$ErrorActionPreference = "Stop"

# 1. Setup Build Directories
$buildDir = "build"
if (-not (Test-Path $buildDir)) {
    Write-Host "Creating build directory..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

# Clean any previous builds
if (Test-Path "$buildDir\hud.exe") {
    Remove-Item "$buildDir\hud.exe"
}
if (Test-Path "$buildDir\hud.obj") {
    Remove-Item "$buildDir\hud.obj"
}

# Define executable paths relative to the project root
$nasmPath = "nasm-2.16.03\nasm.exe"
$goLinkPath = "golink\GoLink.exe"

# 2. Check for Compiler & Linker Availability
if (-not (Test-Path $nasmPath)) {
    Write-Error "NASM compiler not found at '$nasmPath'. Please verify your workspace contents."
}
if (-not (Test-Path $goLinkPath)) {
    Write-Error "GoLink linker not found at '$goLinkPath'. Please verify your workspace contents."
}

Write-Host "Compiling hud.asm using NASM..." -ForegroundColor Yellow
# Assemble with Win64 format
& $nasmPath -f win64 hud.asm -o "$buildDir\hud.obj"

if (Test-Path "$buildDir\hud.obj") {
    Write-Host "Compilation Succeeded! Object file created at '$buildDir\hud.obj'" -ForegroundColor Green
} else {
    Write-Error "Assembly failed. Check hud.asm for errors."
}

Write-Host "Linking hud.obj using GoLink..." -ForegroundColor Yellow
# Link as Windows GUI program with entry point 'Start'
# GoLink automatically searches and links the given DLLs: kernel32, user32, gdi32
& $goLinkPath /entry:Start "$buildDir\hud.obj" kernel32.dll user32.dll gdi32.dll /o "$buildDir\hud.exe"

if (Test-Path "$buildDir\hud.exe") {
    Write-Host "Linking Succeeded! Executable created at '$buildDir\hud.exe'" -ForegroundColor Green
    Write-Host "Launching Performance HUD Widget..." -ForegroundColor Green
    Write-Host "Enjoy your native, lightweight assembly overlay widget!" -ForegroundColor Cyan
    
    # Run the HUD executable
    & "$buildDir\hud.exe"
} else {
    Write-Error "Linking failed. Check GoLink linking parameters."
}
