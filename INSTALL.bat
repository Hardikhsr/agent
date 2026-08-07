@echo off
:: ═══════════════════════════════════════════════════
:: INSTALL.bat — Lightweight launcher for install_protection.ps1
:: Uses proven VBS-based UAC elevation (works with all path types)
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
    echo [1] Bypassing Execution Policy...
    echo [2] Launching Installer...
    echo.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_protection.ps1"

    echo.
    echo [3] Installation complete.
    echo.
    pause
    exit /B
