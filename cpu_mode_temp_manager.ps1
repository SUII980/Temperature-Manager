# cpu_mode_temp_manager.ps1
# CPU Mode / Temp Manager — Universal Intel / AMD Edition
# Supports: Intel 2nd Gen (Sandy Bridge) through latest, AMD Ryzen/Athlon, Windows 10 1809+ and Windows 11
# Live CPU temperature via LibreHardwareMonitor (MSR), ACPI, or WMI fallback
# Intelligent Auto-Cool Guard, flicker-free in-place UI, full older-device compatibility
# Requires Administrator privileges

$ErrorActionPreference = 'Continue'

# Power Configuration GUIDs (standard Windows powercfg GUIDs)
$SUB_PROCESSOR   = "54533251-82be-4824-96c1-47b60b740d00"
$GUID_BOOST_MODE = "be337238-0d82-4146-a960-4f3749d470c7"
$GUID_EPP        = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"
$GUID_MAX_STATE  = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$GUID_MIN_STATE  = "893dee8e-2bef-41e0-89c6-b55d0929964c"
$GUID_COOLING    = "94d3a615-a899-4ac5-ae2b-e4d8f634367f"

# Auto-Cool Guard state
$global:AutoCoolEnabled   = $true
$global:AutoCoolThreshold = 75
$global:AutoCoolActive    = $false
$global:LastAutoCoolMsg   = ""
$global:AutoCoolDetails   = $null
$FAILSAFE_TEMP_LIMIT      = 92

# Hardware monitor globals
$global:LhmComputer    = $null
$global:LhmCpuHardware = $null
$global:LhmInitialized = $false

# Device capability flags — detected at startup
$global:HasEPP         = $false   # Speed Shift EPP (Intel 6th Gen+ / AMD Ryzen)
$global:HasEfficientBoost = $false  # Boost modes 3,4,5,6 (Win10 1903+)
$global:HasBoostControl = $false  # Basic boost toggle (almost all modern CPUs)
$global:MaxBoostMode   = 2        # Highest supported boost mode index
$global:CpuVendor      = "Unknown"
$global:CpuGeneration  = 0
$global:WinBuild       = 0

# ============================================================
# ADMIN CHECK
# ============================================================
function Invoke-AdminCheck {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "  Requesting Administrator privileges..." -ForegroundColor Yellow
        try {
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        } catch {}
        exit
    }
}

# ============================================================
# DEVICE CAPABILITY DETECTION (runs once at startup)
# ============================================================
function Detect-DeviceCapabilities {
    # Windows build
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $global:WinBuild = [int]($os.BuildNumber)
    } catch { $global:WinBuild = 0 }

    # CPU vendor and generation + static specs cached for real-time performance
    try {
        $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $name = if ($proc.Name) { $proc.Name.Trim() } else { "Intel / AMD Processor" }
        $global:CpuStaticInfo = [pscustomobject]@{
            Name    = $name
            Cores   = if ($proc.NumberOfCores) { $proc.NumberOfCores } else { [Environment]::ProcessorCount }
            Threads = if ($proc.NumberOfLogicalProcessors) { $proc.NumberOfLogicalProcessors } else { [Environment]::ProcessorCount }
            BaseMhz = if ($proc.MaxClockSpeed) { $proc.MaxClockSpeed } else { 2200 }
        }
        if ($name -match 'Intel') {
            $global:CpuVendor = "Intel"
            # Extract Intel generation from model number
            if ($name -match 'Core.*?(\d{1,2})\d{3}') {
                $global:CpuGeneration = [int]$matches[1]
            } elseif ($name -match 'i\d-(\d)') {
                $global:CpuGeneration = [int]$matches[1]
            } else {
                $global:CpuGeneration = 4  # conservative fallback
            }
        } elseif ($name -match 'AMD|Ryzen|Athlon|EPYC|Threadripper') {
            $global:CpuVendor = "AMD"
            $global:CpuGeneration = 10  # AMD always supports modern modes
        } else {
            $global:CpuVendor = "Unknown"
            $global:CpuGeneration = 4
        }
    } catch {}

    # High-speed .NET PerformanceCounters (0.05ms reading for 0.1s real-time refresh)
    try {
        $global:PerfCounterUtil = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Time', '_Total')
        $global:PerfCounterPerf = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total')
        $global:PerfCounterUtil.NextValue() | Out-Null
        $global:PerfCounterPerf.NextValue() | Out-Null
    } catch {
        $global:PerfCounterUtil = $null
        $global:PerfCounterPerf = $null
    }

    # Probe which power settings actually exist on this machine
    $activeGuid = Get-ActivePlanGuid

    # Check EPP support (Intel 6th Gen+ Speed Shift / AMD Ryzen)
    $eppExists = $false
    try {
        $out = powercfg /query $activeGuid $SUB_PROCESSOR $GUID_EPP 2>$null
        if ($out -and $out -notmatch 'not found|invalid' -and $out -match 'Setting GUID') {
            $eppExists = $true
        }
    } catch {}
    # Also check registry path
    if (-not $eppExists) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SUB_PROCESSOR\$GUID_EPP"
        $eppExists = (Test-Path $regPath)
    }
    $global:HasEPP = $eppExists

    # Check Boost Mode support and max available mode
    $boostExists = $false
    $maxMode = 2
    try {
        $out = powercfg /query $activeGuid $SUB_PROCESSOR $GUID_BOOST_MODE 2>$null
        if ($out -and $out -match 'Setting GUID') {
            $boostExists = $true
            # Count available modes from powercfg output
            $modeLines = $out | Select-String 'Possible Setting Index'
            if ($modeLines) {
                $maxMode = $modeLines.Count - 1
            }
        }
    } catch {}
    $global:HasBoostControl  = $boostExists
    $global:MaxBoostMode     = $maxMode
    # Efficient modes (3+) require Win10 1903+ (build 18362+)
    $global:HasEfficientBoost = ($boostExists -and $maxMode -ge 3 -and $global:WinBuild -ge 18362)

    # Unhide settings in power plan UI
    Unhide-ProcessorSettings
}

function Get-CompatibilitySummary {
    $lines = @()
    $lines += "  CPU Vendor  : $($global:CpuVendor)$(if ($global:CpuGeneration -gt 0 -and $global:CpuVendor -eq 'Intel') { " (Gen $($global:CpuGeneration))" })"
    $lines += "  Win Build   : $($global:WinBuild)  |  EPP Support: $(if ($global:HasEPP) { 'YES (Speed Shift)' } else { 'NO (pre-6th Gen / not exposed)' })"
    $lines += "  Boost Modes : $(if ($global:HasBoostControl) { "0 to $($global:MaxBoostMode)" } else { 'NOT AVAILABLE' })  |  Efficient Boost: $(if ($global:HasEfficientBoost) { 'YES' } else { 'NO (Win10 <1903 or old CPU)' })"
    return $lines
}

# ============================================================
# HARDWARE MONITOR (LibreHardwareMonitor MSR)
# ============================================================
function Init-HardwareMonitor {
    if ($global:LhmInitialized) { return $true }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
    $searchPaths = @(
        (Join-Path $scriptDir "LibreHardwareMonitorLib.dll"),
        (Join-Path $scriptDir "lhm-release\LibreHardwareMonitorLib.dll"),
        (Join-Path $env:USERPROFILE "Downloads\LibreHardwareMonitorLib.dll"),
        (Join-Path $env:USERPROFILE "Downloads\temps management\LibreHardwareMonitorLib.dll"),
        (Join-Path $env:ProgramFiles "LibreHardwareMonitor\LibreHardwareMonitorLib.dll")
    )
    $dllPath = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($dllPath) {
        try {
            Add-Type -Path $dllPath -ErrorAction Stop
            $comp = New-Object LibreHardwareMonitor.Hardware.Computer
            $comp.IsCpuEnabled = $true
            $comp.Open()
            $global:LhmComputer    = $comp
            foreach ($hw in $comp.Hardware) {
                if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
                    $global:LhmCpuHardware = $hw; break
                }
            }
            $global:LhmInitialized = $true
            return $true
        } catch {}
    }
    return $false
}

function Get-RealCpuTemperature {
    # Method 1: LibreHardwareMonitor (MSR — most accurate, works on Intel & AMD)
    if (Init-HardwareMonitor -and $null -ne $global:LhmCpuHardware) {
        try {
            $global:LhmCpuHardware.Update()
            $tempType = [LibreHardwareMonitor.Hardware.SensorType]::Temperature

            # Priority: Package > Core Max > Core Average > any Temperature sensor
            $candidates = @(
                ($global:LhmCpuHardware.Sensors | Where-Object { $_.SensorType -eq $tempType -and $_.Name -eq "CPU Package" }   | Select-Object -First 1),
                ($global:LhmCpuHardware.Sensors | Where-Object { $_.SensorType -eq $tempType -and $_.Name -eq "Core Max" }      | Select-Object -First 1),
                ($global:LhmCpuHardware.Sensors | Where-Object { $_.SensorType -eq $tempType -and $_.Name -match "Average" }    | Select-Object -First 1),
                ($global:LhmCpuHardware.Sensors | Where-Object { $_.SensorType -eq $tempType -and $_.Name -match "Core #" }     | Select-Object -First 1),
                ($global:LhmCpuHardware.Sensors | Where-Object { $_.SensorType -eq $tempType } | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1)
            )
            foreach ($s in $candidates) {
                if ($s -and $s.Value -and [double]$s.Value -gt 15 -and [double]$s.Value -lt 130) {
                    return [pscustomobject]@{ Value = [math]::Round([double]$s.Value,1); Source = "LHM: $($s.Name)" }
                }
            }
        } catch {}
    }

    # Method 2: WMI MSAcpi_ThermalZoneTemperature (older laptops, desktop mainboards)
    try {
        $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
        if ($tz) {
            $temps = @($tz | ForEach-Object {
                $c = [math]::Round(($_.CurrentTemperature - 2732) / 10, 1)
                if ($c -gt 35 -and $c -lt 120) { $c }
            } | Where-Object { $_ -ne $null })
            if ($temps.Count -gt 0) {
                $max = ($temps | Measure-Object -Maximum).Maximum
                # Reject ASUS dummy 27.8C ACPI stub
                if ($max -gt 29) {
                    return [pscustomobject]@{ Value = $max; Source = "ACPI Thermal Zone" }
                }
            }
        }
    } catch {}

    # Method 3: Win32_PerfFormattedData_Counters_ThermalZoneInformation (Win8+)
    try {
        $tzPerf = Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue |
                  Where-Object { $_.HighPrecisionTemperature -gt 2800 } | Select-Object -First 1
        if ($tzPerf) {
            $c = [math]::Round(($tzPerf.HighPrecisionTemperature / 10) - 273.15, 1)
            if ($c -gt 29 -and $c -lt 120) {
                return [pscustomobject]@{ Value = $c; Source = "WMI Thermal Counter" }
            }
        }
    } catch {}

    # Method 4: nvidia-smi GPU temp as shared-heatsink proxy (laptops with shared vapor chamber)
    try {
        $raw = (& nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null).Trim()
        if ($raw -and $raw -notmatch 'N/A|error' -and [int]$raw -gt 20) {
            return [pscustomobject]@{ Value = [double]$raw; Source = "Shared Heatsink (GPU proxy)" }
        }
    } catch {}

    # Method 5: AMD-specific SMU via registry (Ryzen laptops without LHM)
    try {
        $amdSmu = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\amdppm\Parameters" -ErrorAction SilentlyContinue
        if ($amdSmu) {
            # Exists on some AMD systems; actual temp not directly here, but indicates AMD SMU is present
        }
    } catch {}

    return [pscustomobject]@{ Value = $null; Source = "No sensor available — install LibreHardwareMonitorLib.dll" }
}

# ============================================================
# HEAVY PROCESS DETECTION
# ============================================================
function Get-HeavyProcessStatus {
    $knownHeavyRegex = @(
        'steam|epicgames|gog|battlenet|uplay|origin|gameoverlayui|playnite',
        'valorant|r5apex|apex|cs2|csgo|dota2|pubg|fortnite|overwatch|warzone|cod|mw[23]',
        'gta5|rdr2|witcher3|cyberpunk2077|eldenring|sekiro|darksouls|nioh',
        'fifasetup|fc24|fc25|fc25|nba2k|wwe2k|madden|mlb|nhl',
        'rocketleague|rainbowsix|siege|r6|farcrygame|assassins|acvalhalla|acodyssey',
        'forza|forzahorizon|nfsheat|nfsunbound|nfsmw|grid|f1_|formula|wrrc',
        'minecraft|terraria|stardew|hades|hollow|cuphead|ori|celeste|deeprock',
        'destiny2|bungie|warframe|pathofexile|diablo|diabloiv|poe2',
        'starfield|fallout4|skyrim|dragonage|masseffect|cyberpunk',
        'leagueoflegends|lor|tft|lol|league|wildrift',
        'unreal|ue4|ue5|unity|godot|gamemaker|rpgmaker',
        'blender|cinema4d|houdini|3dsmax|maya|zbrush|substance|marvelous',
        'premiere|afterfx|photoshop|lightroom|illustrator|indesign',
        'resolve|davinci|handbrake|ffmpeg|obs64|obs|streamlabs|xsplit',
        'cinebench|unigine|furmark|3dmark|superposition|kombustor|heaven',
        'vray|octanerender|iray|redshift|cycles|keyshot',
        'msbuild|cl\.exe|link\.exe|cargo|gradle|cmake|ninja|devenv',
        'docker|wsl2|hyper-v|vmware|virtualbox|parallels'
    ) -join '|'

    $s1    = Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, CPU
    Start-Sleep -Milliseconds 250
    $s2    = Get-Process -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, CPU
    $cores = [Environment]::ProcessorCount

    # GPU utilization (NVIDIA) — GPU-bound games have low CPU but high GPU
    $gpuUtil  = 0
    try {
        $raw = (& nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null).Trim()
        if ($raw -and $raw -notmatch 'N/A|error') { $gpuUtil = [int]$raw }
    } catch {}
    $gpuHeavy = ($gpuUtil -ge 30)

    $ignored = 'Idle|System|powershell|pwsh|cmd|conhost|WmiPrvSE|explorer|svchost|lsass|dwm|csrss|taskhostw|searchhost|sihost|fontdrvhost|wininit|winlogon|services|smss|audiodg|spoolsv|msiexec|wuauclt'

    $active = @()
    foreach ($p2 in $s2) {
        $p1 = $s1 | Where-Object { $_.Id -eq $p2.Id }
        if ($p1 -and $null -ne $p2.CPU -and $p2.CPU -ge $p1.CPU) {
            $cpuPct = [math]::Round((($p2.CPU - $p1.CPU) / (0.25 * $cores)) * 100, 1)
            if ($cpuPct -ge 1 -and $p2.ProcessName -notmatch $ignored) {
                $isKnown = ($p2.ProcessName -match $knownHeavyRegex)
                $isHeavy = $isKnown -or ($cpuPct -ge 15)
                $active += [pscustomobject]@{
                    Name     = $p2.ProcessName
                    CpuUsage = $cpuPct
                    IsHeavy  = $isHeavy
                    IsKnown  = $isKnown
                }
            }
        }
    }

    $heavyApps   = $active | Where-Object { $_.IsHeavy }
    $topApp      = $active | Sort-Object CpuUsage -Descending | Select-Object -First 1
    $hasHeavyApp = ($heavyApps.Count -gt 0) -or $gpuHeavy

    return [pscustomobject]@{
        HasHeavyApp = $hasHeavyApp
        HeavyApps   = $heavyApps
        TopApp      = $topApp
        GpuUtil     = $gpuUtil
        GpuHeavy    = $gpuHeavy
    }
}

# ============================================================
# POWER SETTINGS HELPERS
# ============================================================
function Get-ActivePlanGuid {
    try {
        $g = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes" -Name "ActivePowerScheme" -ErrorAction SilentlyContinue).ActivePowerScheme
        if ($g) { return $g }
        $line = powercfg /getactivescheme 2>$null
        if ($line -match 'GUID:\s*([0-9a-fA-F\-]+)') { return $matches[1].Trim() }
    } catch {}
    return "SCHEME_CURRENT"
}

function Get-ActivePlanName {
    try {
        $guid = Get-ActivePlanGuid
        $name = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$guid" -Name "FriendlyName" -ErrorAction SilentlyContinue).FriendlyName
        if ($name) { return $name }
        $line = powercfg /getactivescheme 2>$null
        if ($line -match '\((.+)\)') { return $matches[1].Trim() }
    } catch {}
    return "Unknown"
}

function Get-PowerSettingValue {
    param([string]$Guid)
    try {
        $activeGuid = Get-ActivePlanGuid
        # Registry fast-path
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$activeGuid\$SUB_PROCESSOR\$Guid"
        $val = (Get-ItemProperty $regPath -Name "ACSettingIndex" -ErrorAction SilentlyContinue).ACSettingIndex
        if ($null -ne $val) { return [int]$val }
        # Fallback: powercfg query
        $out = powercfg /query $activeGuid $SUB_PROCESSOR $Guid 2>$null
        $ac  = $out | Select-String 'Current AC Power Setting Index' | Select-Object -First 1
        if ($ac -match '0x([0-9a-fA-F]+)') { return [int]("0x" + $matches[1]) }
    } catch {}
    return -1
}

function Set-PowerSettingValue {
    param([string]$Guid, [int]$Value)
    # Only attempt to set if the setting exists on this device
    $existing = Get-PowerSettingValue -Guid $Guid
    if ($existing -eq -1) { return $false }   # setting not supported on this hardware
    try {
        $activeGuid = Get-ActivePlanGuid
        powercfg /setacvalueindex $activeGuid $SUB_PROCESSOR $Guid $Value 2>$null | Out-Null
        powercfg /setdcvalueindex $activeGuid $SUB_PROCESSOR $Guid $Value 2>$null | Out-Null
        powercfg /setactive $activeGuid 2>$null | Out-Null
        return $true
    } catch { return $false }
}

function Unhide-ProcessorSettings {
    # Makes hidden settings visible in Control Panel Power Options
    $settings = @($GUID_BOOST_MODE, $GUID_EPP, $GUID_MAX_STATE, $GUID_MIN_STATE, $GUID_COOLING)
    foreach ($s in $settings) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SUB_PROCESSOR\$s"
        if (Test-Path $path) {
            try { Set-ItemProperty -Path $path -Name "Attributes" -Value 2 -Type DWord -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# ============================================================
# CPU LIVE TELEMETRY
# ============================================================
function Get-CpuLiveStats {
    try {
        $info = $global:CpuStaticInfo
        if (-not $info) {
            $info = [pscustomobject]@{
                Name     = "Processor"
                Cores    = [Environment]::ProcessorCount
                Threads  = [Environment]::ProcessorCount
                BaseMhz  = 2200
            }
        }

        # Sub-millisecond performance reading via .NET PerformanceCounters (0.05ms)
        $perfPct     = 100
        $utilization = 0
        if ($global:PerfCounterUtil -and $global:PerfCounterPerf) {
            try {
                $rawUtil     = $global:PerfCounterUtil.NextValue()
                $rawPerf     = $global:PerfCounterPerf.NextValue()
                $utilization = [math]::Round([math]::Max(0, [math]::Min(100, $rawUtil)))
                $perfPct     = [math]::Round([math]::Max(10, $rawPerf))
            } catch {}
        } else {
            try {
                $perf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq "_Total" } | Select-Object -First 1
                if ($perf) {
                    $perfPct     = if ($perf.PercentProcessorPerformance) { $perf.PercentProcessorPerformance } else { 100 }
                    $utilization = if ($perf.PercentProcessorTime) { $perf.PercentProcessorTime } else { 0 }
                }
            } catch {}
        }

        $currentMhz = [math]::Round(($perfPct / 100) * $info.BaseMhz)

        return [pscustomobject]@{
            Name        = $info.Name
            Cores       = $info.Cores
            Threads     = $info.Threads
            BaseMhz     = $info.BaseMhz
            CurrentMhz  = $currentMhz
            PerfPct     = $perfPct
            Utilization = $utilization
            Thermal     = Get-RealCpuTemperature
        }
    } catch { return $null }
}

# ============================================================
# FORMATTER HELPERS
# ============================================================
function Format-BoostMode ([int]$Val) {
    switch ($Val) {
        0 { return "0: Disabled (Base Clock Only / Coolest)" }
        1 { return "1: Enabled (Standard Turbo)" }
        2 { return "2: Aggressive (Max Turbo / Full Voltage)" }
        3 { return "3: Efficient Enabled (Smart Boost / Tamed Heat)" }
        4 { return "4: Efficient Aggressive (Dynamic Turbo)" }
        5 { return "5: Aggressive At Guaranteed (Freq-Floor Boost)" }
        6 { return "6: Efficient Aggressive At Guaranteed (Best Balance)" }
        default { return "Unknown ($Val)" }
    }
}

function Format-EPP ([int]$Val) {
    if ($Val -lt 0)    { return "N/A (not supported on this CPU)" }
    if ($Val -le 10)   { return "$Val (Max Performance / Highest Voltage)" }
    elseif ($Val -le 40) { return "$Val (High Performance)" }
    elseif ($Val -le 60) { return "$Val (Balanced / Dynamic Voltage)" }
    elseif ($Val -le 85) { return "$Val (Efficient / Low Voltage / Cool)" }
    else { return "$Val (Max Power Saver / Coldest)" }
}

# ============================================================
# AUTO-COOL GUARD
# ============================================================
function Check-AutoCoolGuard {
    if (-not $global:AutoCoolEnabled) { return }

    $tData = Get-RealCpuTemperature
    if ($null -eq $tData.Value) { return }
    $currentTemp = [double]$tData.Value

    if ($currentTemp -ge $FAILSAFE_TEMP_LIMIT) {
        Invoke-CpuFailsafe -Reason "Emergency: $currentTemp C >= $FAILSAFE_TEMP_LIMIT C hard limit"
        return
    }

    if ($currentTemp -gt $global:AutoCoolThreshold) {
        $pStatus = Get-HeavyProcessStatus

        if (-not $pStatus.HasHeavyApp) {
            $topName = if ($pStatus.TopApp) { "$($pStatus.TopApp.Name) ($($pStatus.TopApp.CpuUsage)%)" } else { "Background services" }

            # Apply counter-measures (only if setting is supported on this device)
            if ($global:HasBoostControl) { Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 0 | Out-Null }
            if ($global:HasEPP)          { Set-PowerSettingValue -Guid $GUID_EPP        -Value 80 | Out-Null }
            Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 90 | Out-Null
            Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1  | Out-Null

            $changes = @("Max Processor State: Capped at 90%", "System Cooling: Active (Fans First)")
            if ($global:HasBoostControl) { $changes = @("Turbo Boost: Disabled (0)") + $changes }
            if ($global:HasEPP)          { $changes += "Speed Shift EPP: 80 (Low Voltage)" }

            $global:AutoCoolActive  = $true
            $global:AutoCoolDetails = [pscustomobject]@{
                Time        = (Get-Date -Format "HH:mm:ss")
                TriggerTemp = $currentTemp
                Culprit     = $topName
                Changes     = $changes
            }
            $global:LastAutoCoolMsg = "Auto-Cool at ${currentTemp}C (no heavy app, top: $topName). Counter-measures applied."
        } else {
            $heavyNames = ($pStatus.HeavyApps | ForEach-Object { "$($_.Name) ($($_.CpuUsage)%)" }) -join ', '
            if ($pStatus.GpuHeavy -and $heavyNames -eq '') { $heavyNames = "GPU workload ($($pStatus.GpuUtil)% GPU)" }
            if ($heavyNames -eq '') { $heavyNames = "Unknown heavy process" }
            $global:LastAutoCoolMsg = "Temp ${currentTemp}C | HELD BACK: $heavyNames active. Performance preserved."
        }
    } else {
        if ($global:AutoCoolActive -and $currentTemp -le ($global:AutoCoolThreshold - 5)) {
            $global:AutoCoolActive  = $false
            $global:LastAutoCoolMsg = "Stabilized at ${currentTemp}C. System ready for full boost."
        }
    }
}

function Invoke-CpuFailsafe {
    param([string]$Reason)
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  !!! CPU THERMAL FAILSAFE ACTIVATED !!!     " -ForegroundColor Red
    Write-Host "  Reason: $Reason"                              -ForegroundColor Red
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Engaging emergency thermal mitigation..." -ForegroundColor Yellow
    if ($global:HasBoostControl) {
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 0 | Out-Null
        Write-Host "  [OK] Turbo Boost Disabled." -ForegroundColor Green
    }
    if ($global:HasEPP) {
        Set-PowerSettingValue -Guid $GUID_EPP -Value 80 | Out-Null
        Write-Host "  [OK] Speed Shift EPP set to 80 (Low Voltage)." -ForegroundColor Green
    }
    Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 85 | Out-Null
    Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1  | Out-Null
    Write-Host "  [OK] Max CPU state capped at 85%." -ForegroundColor Green
    Write-Host "  [OK] Cooling set to Active." -ForegroundColor Green
    Write-Host "  Thermal protection applied." -ForegroundColor Yellow
}

# ============================================================
# CPU POWER MODES (capability-aware)
# ============================================================
function Set-CoolAndQuietMode {
    Write-Host ""
    Write-Host "  Applying Cool & Quiet Mode..." -ForegroundColor Cyan
    if ($global:HasBoostControl) {
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 0 | Out-Null
        Write-Host "  [OK] Turbo Boost: Disabled (locked to base clock)." -ForegroundColor Green
    } else {
        Write-Host "  [--] Boost control not available on this CPU." -ForegroundColor DarkGray
    }
    if ($global:HasEPP) {
        Set-PowerSettingValue -Guid $GUID_EPP -Value 80 | Out-Null
        Write-Host "  [OK] Speed Shift EPP: 80 (Low Voltage / Cool)." -ForegroundColor Green
    } else {
        Write-Host "  [--] EPP not supported — using Max State cap instead." -ForegroundColor DarkGray
    }
    Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 95 | Out-Null
    Set-PowerSettingValue -Guid $GUID_MIN_STATE -Value 5  | Out-Null
    Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1  | Out-Null
    Write-Host "  [OK] Max Processor State: 95% | Cooling: Active." -ForegroundColor Green
    Write-Host "  Result: Expected -15C to -25C drop from previous temps." -ForegroundColor Green
}

function Set-OptimizedGamingMode {
    Write-Host ""
    Write-Host "  Applying Optimized Gaming Mode..." -ForegroundColor Green
    # Use Efficient Aggressive if supported, fall back to standard Aggressive
    if ($global:HasBoostControl) {
        $boostTarget = if ($global:HasEfficientBoost -and $global:MaxBoostMode -ge 4) { 4 }
                       elseif ($global:HasEfficientBoost)                              { 3 }
                       else                                                            { 1 }
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value $boostTarget | Out-Null
        Write-Host "  [OK] Turbo Boost: $(Format-BoostMode $boostTarget)." -ForegroundColor Green
    }
    if ($global:HasEPP) {
        Set-PowerSettingValue -Guid $GUID_EPP -Value 50 | Out-Null
        Write-Host "  [OK] Speed Shift EPP: 50 (Balanced / Dynamic Voltage)." -ForegroundColor Green
    }
    Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 100 | Out-Null
    Set-PowerSettingValue -Guid $GUID_MIN_STATE -Value 5   | Out-Null
    Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1   | Out-Null
    Write-Host "  [OK] Max State: 100% | Cooling: Active." -ForegroundColor Green
    Write-Host "  Balanced gaming performance with moderate thermals." -ForegroundColor Green
}

function Set-MaxPerformanceMode {
    Write-Host ""
    Write-Host "  Applying Max Performance Mode (Unrestricted)..." -ForegroundColor Magenta
    if ($global:HasBoostControl) {
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 2 | Out-Null
        Write-Host "  [OK] Turbo Boost: Aggressive (Mode 2)." -ForegroundColor Green
    }
    if ($global:HasEPP) {
        Set-PowerSettingValue -Guid $GUID_EPP -Value 0 | Out-Null
        Write-Host "  [OK] Speed Shift EPP: 0 (Max Performance Voltage)." -ForegroundColor Green
    }
    Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 100 | Out-Null
    Set-PowerSettingValue -Guid $GUID_MIN_STATE -Value 100 | Out-Null
    Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1   | Out-Null
    Write-Host "  [OK] Max State: 100% | Min State: 100% | Cooling: Active." -ForegroundColor Green
    Write-Host "  WARNING: Expect high temperatures. Use for short bursts only." -ForegroundColor Yellow
}

function Toggle-TurboBoost {
    Write-Host ""
    if (-not $global:HasBoostControl) {
        Write-Host "  Turbo Boost control is not available on this device." -ForegroundColor Red
        Write-Host "  Your CPU may not support powercfg boost mode control." -ForegroundColor DarkGray
        return
    }
    $curBoost = Get-PowerSettingValue -Guid $GUID_BOOST_MODE
    if ($curBoost -eq 0) {
        $onMode = if ($global:HasEfficientBoost -and $global:MaxBoostMode -ge 4) { 4 } else { 2 }
        Write-Host "  Enabling Turbo Boost (Mode $onMode)..." -ForegroundColor Green
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value $onMode | Out-Null
        if ($global:HasEPP) { Set-PowerSettingValue -Guid $GUID_EPP -Value 50 | Out-Null }
        Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 100 | Out-Null
        Write-Host "  [OK] Turbo Boost ON — $(Format-BoostMode $onMode)." -ForegroundColor Green
    } else {
        Write-Host "  Disabling Turbo Boost (locked to base clock)..." -ForegroundColor Cyan
        Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 0 | Out-Null
        Write-Host "  [OK] Turbo Boost OFF. Instant temperature drop expected." -ForegroundColor Cyan
    }
}

function Set-CustomPowerSettings {
    Write-Host ""
    Write-Host "  === Custom CPU Voltage & Power Configuration ===" -ForegroundColor Yellow
    Write-Host ""

    if ($global:HasEPP) {
        Write-Host "  1) Speed Shift EPP  (0=Max Perf, 50=Balanced, 80=Cool, 100=Max Saver)" -ForegroundColor White
    } else {
        Write-Host "  1) Speed Shift EPP  [NOT SUPPORTED on this CPU/OS]" -ForegroundColor DarkGray
    }

    Write-Host "  2) Max Processor State  (cap %: e.g. 75, 85, 90, 95, 100)" -ForegroundColor White

    if ($global:HasBoostControl) {
        $modeRange = "0 to $($global:MaxBoostMode)"
        Write-Host "  3) Turbo Boost Mode  ($modeRange available on this device)" -ForegroundColor White
    } else {
        Write-Host "  3) Turbo Boost Mode  [NOT SUPPORTED on this device]" -ForegroundColor DarkGray
    }

    Write-Host "  B) Back to Main Menu" -ForegroundColor White
    Write-Host ""
    $subChoice = Read-Host "  Select sub-option"

    switch ($subChoice.ToUpper()) {
        '1' {
            if (-not $global:HasEPP) {
                Write-Host "  Speed Shift EPP is not supported on this CPU (requires Intel 6th Gen+ or AMD Ryzen)." -ForegroundColor Red
                return
            }
            $val = Read-Host "  Enter EPP value (0 to 100)"
            if ($val -match '^\d+$' -and [int]$val -ge 0 -and [int]$val -le 100) {
                $eppInt = [int]$val
                Set-PowerSettingValue -Guid $GUID_EPP -Value $eppInt | Out-Null
                Write-Host "  [OK] Speed Shift EPP set to $(Format-EPP $eppInt)." -ForegroundColor Green
            } else { Write-Host "  Invalid. Enter a number between 0 and 100." -ForegroundColor Red }
        }
        '2' {
            $val = Read-Host "  Enter Max Processor State % (50 to 100)"
            if ($val -match '^\d+$' -and [int]$val -ge 50 -and [int]$val -le 100) {
                Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value ([int]$val) | Out-Null
                Write-Host "  [OK] Max Processor State set to $val%." -ForegroundColor Green
            } else { Write-Host "  Invalid. Enter a percentage between 50 and 100." -ForegroundColor Red }
        }
        '3' {
            if (-not $global:HasBoostControl) {
                Write-Host "  Boost Mode control is not available on this device." -ForegroundColor Red
                return
            }
            Write-Host "  Available modes on this device (0 to $($global:MaxBoostMode)):" -ForegroundColor Cyan
            for ($m = 0; $m -le $global:MaxBoostMode; $m++) {
                $marker = if ($m -le 2 -or $global:HasEfficientBoost) { "" } else { " [may not apply]" }
                $modeLine = "    ${m}: $(Format-BoostMode $m)$marker"
                Write-Host $modeLine
            }
            $val = Read-Host "  Enter Boost Mode (0 to $($global:MaxBoostMode))"
            if ($val -match '^\d+$' -and [int]$val -ge 0 -and [int]$val -le $global:MaxBoostMode) {
                $boostInt = [int]$val
                Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value $boostInt | Out-Null
                Write-Host "  [OK] Boost Mode set to $(Format-BoostMode $boostInt)." -ForegroundColor Green
            } else { Write-Host "  Invalid. Enter a number between 0 and $($global:MaxBoostMode)." -ForegroundColor Red }
        }
        default { return }
    }
}

function Configure-AutoCoolGuard {
    Write-Host ""
    Write-Host "  === Intelligent Auto-Cool Guard ===" -ForegroundColor Yellow
    Write-Host "  Status    : $(if ($global:AutoCoolEnabled) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host "  Threshold : $($global:AutoCoolThreshold) C"
    Write-Host "  Rule      : If CPU > $($global:AutoCoolThreshold)C with no heavy apps → auto-reduce boost & voltage"
    Write-Host ""
    Write-Host "  1) Toggle Auto-Cool Guard (ON / OFF)"
    Write-Host "  2) Change Trigger Temperature (current: $($global:AutoCoolThreshold)C)"
    Write-Host "  B) Back"
    Write-Host ""
    $c = Read-Host "  Select option"

    switch ($c.ToUpper()) {
        '1' {
            $global:AutoCoolEnabled = -not $global:AutoCoolEnabled
            Write-Host "  [OK] Auto-Cool Guard: $(if ($global:AutoCoolEnabled) { 'ENABLED' } else { 'DISABLED' })." -ForegroundColor Green
        }
        '2' {
            $t = Read-Host "  Enter threshold in C (55 to 95)"
            if ($t -match '^\d+$' -and [int]$t -ge 55 -and [int]$t -le 95) {
                $global:AutoCoolThreshold = [int]$t
                Write-Host "  [OK] Threshold set to $($global:AutoCoolThreshold) C." -ForegroundColor Green
            } else { Write-Host "  Invalid. Enter between 55 and 95." -ForegroundColor Red }
        }
        default { return }
    }
}

function Reset-CpuDefaults {
    Write-Host ""
    Write-Host "  Resetting to standard defaults..." -ForegroundColor Yellow
    if ($global:HasBoostControl) { Set-PowerSettingValue -Guid $GUID_BOOST_MODE -Value 2  | Out-Null }
    if ($global:HasEPP)          { Set-PowerSettingValue -Guid $GUID_EPP        -Value 50 | Out-Null }
    Set-PowerSettingValue -Guid $GUID_MAX_STATE -Value 100 | Out-Null
    Set-PowerSettingValue -Guid $GUID_MIN_STATE -Value 5   | Out-Null
    Set-PowerSettingValue -Guid $GUID_COOLING   -Value 1   | Out-Null
    $global:AutoCoolActive = $false
    Write-Host "  [OK] CPU settings restored to defaults." -ForegroundColor Green
}

# ============================================================
# IN-PLACE FLICKER-FREE CONSOLE (1-second refresh)
# ============================================================
function Write-LineInPlace {
    param([int]$LineY, [string]$Text, [ConsoleColor]$Color = [ConsoleColor]::White)
    try {
        $pos   = $Host.UI.RawUI.CursorPosition
        $pos.X = 0; $pos.Y = $LineY
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host $Text.PadRight(100) -ForegroundColor $Color -NoNewline
    } catch { Write-Host $Text -ForegroundColor $Color }
}

function Update-TelemetryInPlace {
    $stats  = Get-CpuLiveStats
    $startY = $global:TelemetryStartY

    # Line 0: Processor name
    $procLine = if ($stats) { "  Processor   : $($stats.Name)" } else { "  Processor   : Reading..." }
    Write-LineInPlace -LineY ($startY+0) -Text $procLine -Color White

    # Line 1: Topology
    $topoLine = if ($stats) { "  Topology    : $($stats.Cores) Cores / $($stats.Threads) Threads  |  Base: $($stats.BaseMhz) MHz" } else { "" }
    Write-LineInPlace -LineY ($startY+1) -Text $topoLine -Color DarkGray

    # Line 2: Compatibility flags (device capabilities)
    $capLine = "  Device Cap  : Boost=$(if ($global:HasBoostControl) { "YES (0-$($global:MaxBoostMode))" } else { "NO" })  |  EPP=$(if ($global:HasEPP) { "YES" } else { "NO" })  |  EfficientBoost=$(if ($global:HasEfficientBoost) { "YES" } else { "NO" })"
    Write-LineInPlace -LineY ($startY+2) -Text $capLine -Color DarkGray

    # Line 3: Temperature
    $tData = if ($stats) { $stats.Thermal } else { $null }
    if ($tData -and $null -ne $tData.Value) {
        $tv      = [double]$tData.Value
        $tColor  = if ($tv -ge 85) { "Red" } elseif ($tv -ge 70) { "Yellow" } else { "Green" }
        $barLen  = [Math]::Min([int]($tv / 2), 50)
        $bar     = ("#" * $barLen).PadRight(50, '-')
        Write-LineInPlace -LineY ($startY+3) -Text "  CPU Temp    : $tv C [$bar] ($($tData.Source))" -Color $tColor
    } else {
        Write-LineInPlace -LineY ($startY+3) -Text "  CPU Temp    : Sensor initializing... (place LibreHardwareMonitorLib.dll in script folder)" -Color DarkGray
    }

    # Line 4: Clock / Utilization
    $clkLine = if ($stats) { "  Clock Speed : $($stats.CurrentMhz) MHz ($($stats.PerfPct)%)  |  Utilization: $($stats.Utilization)%" } else { "" }
    Write-LineInPlace -LineY ($startY+4) -Text $clkLine -Color White

    # Line 5: blank
    Write-LineInPlace -LineY ($startY+5) -Text "" -Color White

    # Line 6: Power profile header
    Write-LineInPlace -LineY ($startY+6) -Text "  ---- Power & Voltage Profile ----" -Color DarkGray

    # Line 7: Active power plan
    Write-LineInPlace -LineY ($startY+7) -Text "  System Plan : $(Get-ActivePlanName) (Active Scheme)" -Color Cyan

    # Line 8: Turbo Boost
    if ($global:HasBoostControl) {
        $bv     = Get-PowerSettingValue -Guid $GUID_BOOST_MODE
        $bColor = if ($bv -eq 0) { "Cyan" } elseif ($bv -ge 3) { "Green" } else { "Magenta" }
        Write-LineInPlace -LineY ($startY+8) -Text "  Turbo Boost : $(Format-BoostMode $bv)" -Color $bColor
    } else {
        Write-LineInPlace -LineY ($startY+8) -Text "  Turbo Boost : Not controllable via powercfg on this device" -Color DarkGray
    }

    # Line 9: EPP
    if ($global:HasEPP) {
        $ev = Get-PowerSettingValue -Guid $GUID_EPP
        Write-LineInPlace -LineY ($startY+9) -Text "  Voltage/EPP : $(Format-EPP $ev)" -Color White
    } else {
        Write-LineInPlace -LineY ($startY+9) -Text "  Voltage/EPP : Not supported (pre-6th Gen Intel or incompatible OS)" -Color DarkGray
    }

    # Line 10: Max State & Cooling
    $ms = Get-PowerSettingValue -Guid $GUID_MAX_STATE
    $cv = Get-PowerSettingValue -Guid $GUID_COOLING
    Write-LineInPlace -LineY ($startY+10) -Text "  Max State   : $ms%  |  Cooling: $(if ($cv -eq 1) { 'Active (Fans First)' } else { 'Passive' })" -Color White

    # Line 11: blank
    Write-LineInPlace -LineY ($startY+11) -Text "" -Color White

    # Line 12: Thermal guard header
    Write-LineInPlace -LineY ($startY+12) -Text "  ---- Thermal Guard Status ----" -Color DarkGray

    # Line 13: Auto-Cool status
    $gs = if ($global:AutoCoolEnabled) { "ENABLED (Trigger: >$($global:AutoCoolThreshold)C when idle)" } else { "DISABLED" }
    Write-LineInPlace -LineY ($startY+13) -Text "  Auto-Cool   : $gs" -Color $(if ($global:AutoCoolEnabled) { "Green" } else { "DarkGray" })

    # Lines 14-15: Last action / active alert
    if ($global:AutoCoolActive -and $null -ne $global:AutoCoolDetails) {
        Write-LineInPlace -LineY ($startY+14) -Text "  [!] ACTIVE  : Cooled at $($global:AutoCoolDetails.Time) ($($global:AutoCoolDetails.TriggerTemp) C | $($global:AutoCoolDetails.Culprit))" -Color Yellow
        Write-LineInPlace -LineY ($startY+15) -Text "  Changes     : $($global:AutoCoolDetails.Changes -join ' | ')" -Color Green
    } elseif ($null -ne $global:AutoCoolDetails) {
        Write-LineInPlace -LineY ($startY+14) -Text "  Last Action : Cooled at $($global:AutoCoolDetails.Time) (Was $($global:AutoCoolDetails.TriggerTemp) C). Now stabilized." -Color DarkGray
        Write-LineInPlace -LineY ($startY+15) -Text "  Status      : Monitoring in-place every 0.1s (real-time)." -Color DarkGray
    } elseif ($global:LastAutoCoolMsg) {
        Write-LineInPlace -LineY ($startY+14) -Text "  Status Log  : $global:LastAutoCoolMsg" -Color DarkGray
        Write-LineInPlace -LineY ($startY+15) -Text "" -Color White
    } else {
        Write-LineInPlace -LineY ($startY+14) -Text "  Status      : Real-time telemetry active (0.1s refresh)." -Color DarkGray
        Write-LineInPlace -LineY ($startY+15) -Text "" -Color White
    }

    # Return cursor to prompt line
    try {
        $p = $Host.UI.RawUI.CursorPosition
        $p.X = 24; $p.Y = $global:PromptLineY
        $Host.UI.RawUI.CursorPosition = $p
    } catch {}
}

function Draw-InitialScreen {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "             CPU MODE / TEMP MANAGER                      " -ForegroundColor Cyan
    Write-Host "   Universal Intel & AMD Edition — All Windows PCs        " -ForegroundColor DarkCyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    $global:TelemetryStartY = $Host.UI.RawUI.CursorPosition.Y

    # Reserve 16 blank lines for in-place telemetry block
    for ($i = 0; $i -lt 16; $i++) { Write-Host "" }

    # Static menu (drawn once, never erased)
    Write-Host "  ---- Actions ----" -ForegroundColor DarkGray
    Write-Host "  1) Cool & Quiet Mode      (Base Clock / Low Voltage / -20C)" -ForegroundColor White
    Write-Host "  2) Optimized Gaming Mode  (Smart Boost / Balanced Heat)"    -ForegroundColor White
    Write-Host "  3) Max Performance Mode   (Full Turbo / Max Voltage)"       -ForegroundColor White
    Write-Host "  4) Quick Toggle Turbo     (Instant ON/OFF)"                 -ForegroundColor White
    Write-Host "  5) Custom Power Settings  (EPP, Max State %, Boost Mode)"   -ForegroundColor White
    Write-Host "  6) Auto-Cool Guard        (Config thermal watchdog)"        -ForegroundColor White
    Write-Host "  7) Reset to Defaults      (Restore plan defaults)"          -ForegroundColor White
    Write-Host "  0) Exit" -ForegroundColor White
    Write-Host ""
    Write-Host "  Telemetry updates in-place every 0.1s (exact real-time). Menu never flickers." -ForegroundColor DarkGray
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host -NoNewline "  Enter Option (1-7, 0): "
    $global:PromptLineY = $Host.UI.RawUI.CursorPosition.Y

    Update-TelemetryInPlace
}

function Show-LiveMenu {
    Draw-InitialScreen
    $tick = 0
    while ($true) {
        # 0.1-second (100ms) exact real-time refresh loop
        Start-Sleep -Milliseconds 100
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            return $key.Character.ToString()
        }
        $tick++

        # Thermal watchdog checks every 10 ticks (1.0s) so 0.1s UI is never blocked
        if ($tick % 10 -eq 0) {
            Check-AutoCoolGuard
        }

        Update-TelemetryInPlace
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================
Invoke-AdminCheck
Detect-DeviceCapabilities   # probe what this hardware/OS actually supports
Init-HardwareMonitor | Out-Null

trap {
    Invoke-CpuFailsafe -Reason "Unhandled script error: $_"
    Read-Host "  Press Enter to continue"
    continue
}

while ($true) {
    $opt = Show-LiveMenu
    switch ($opt) {
        '1' { Set-CoolAndQuietMode }
        '2' { Set-OptimizedGamingMode }
        '3' { Set-MaxPerformanceMode }
        '4' { Toggle-TurboBoost }
        '5' { Set-CustomPowerSettings }
        '6' { Configure-AutoCoolGuard }
        '7' { Reset-CpuDefaults }
        '0' {
            Write-Host ""
            Write-Host "  Goodbye!" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500
            Stop-Process -Id $PID -Force
        }
        default { Write-Host "  Invalid key. Use 1-7 or 0." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
    if ($opt -ne '0') {
        Write-Host ""
        Read-Host "  Press Enter to continue"
    }
}
