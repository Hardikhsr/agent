@echo off
:: ═══════════════════════════════════════════════════
:: INSTALL.bat — Launcher for install_protection.ps1
:: Uses proven VBS-based UAC elevation (works with all path types)
:: Falls back to ULTIMATE_SETUP.bat if PowerShell fails
:: ═══════════════════════════════════════════════════

:: Check for Administrator privileges
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

if '%errorlevel%' NEQ '0' (
    echo.
    echo [!] Requesting Administrator Access...
    echo.
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"

    echo.
    echo =========================================================
    echo    SYSTEM HEALTH MONITOR - INSTALLER
    echo =========================================================
    echo.

    :: Step 1: Unblock all files first (prevents SmartScreen/execution policy issues)
    echo [1/3] Removing download blocks...
    powershell.exe -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -Path (\"$($_.FullName):Zone.Identifier\") -Force -ErrorAction SilentlyContinue } catch {} }; Get-ChildItem -Path '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

    :: Step 2: Try PowerShell installer first
    echo [2/3] Launching PowerShell Installer...
    echo.

    :: Use short path name for the script to avoid path-with-spaces issues
    set "PS_SCRIPT=%~dp0install_protection.ps1"

    :: Check if PS1 file exists
    if not exist "%PS_SCRIPT%" (
        echo [!] install_protection.ps1 not found!
        echo [!] Falling back to ULTIMATE_SETUP.bat...
        goto Fallback
    )

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

    :: Check if PowerShell succeeded
    if %errorlevel% neq 0 (
        echo.
        echo [!] PowerShell installer returned error code: %errorlevel%
        echo [!] Falling back to ULTIMATE_SETUP.bat...
        goto Fallback
    )

    goto Done

:Fallback
    echo.
    if exist "%~dp0ULTIMATE_SETUP.bat" (
        echo [*] Running ULTIMATE_SETUP.bat as fallback...
        call "%~dp0ULTIMATE_SETUP.bat"
    ) else (
        echo [ERROR] No fallback installer found!
        echo Make sure ULTIMATE_SETUP.bat or install_protection.ps1 exists.
    )
    goto Done

:Done
    echo.
    echo [3/3] Installation complete.
    echo.
    pause
    exit /B
