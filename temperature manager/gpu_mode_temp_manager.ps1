# gpu_mode_temp_manager.ps1
# GPU Mode / Temp Manager — Universal Edition for Windows Laptops and Desktops
# Supports:
#   - NVIDIA: GeForce RTX 50/40/30/20, GTX 16/10/900/700/600, TITAN, Quadro, Mobile & Desktop
#   - AMD: RDNA 4/3/2/1 (RX 9000/8000/7000/6000/5000), Vega, Polaris (RX 400/500), Legacy GCN / TeraScale (R9/R7/R5/HD)
#   - Intel: Arc (Battlemage/Alchemist), Iris Xe, UHD, HD Graphics (Discrete & Integrated)
# Real-time 0.1s in-memory telemetry via Direct NVML P/Invoke, LibreHardwareMonitor (MSR/SMU/D3D), & OEM EC WMI
# Vendor-aware Power, ULPS, PowerMizer, Graphics Power Plan, & PCIe ASPM management
# Requires Administrator privileges

$ErrorActionPreference = 'Continue'
$FAILSAFE_TEMP_LIMIT = 90
$FAILSAFE_HOTSPOT_LIMIT = 108

# Powercfg Standard GUIDs (Intel Graphics & PCIe ASPM - universal across Windows 10/11)
$GUID_SUB_GRAPHICS = "44f3beca-a7c0-460e-9df2-bb8b99e0cba6"
$GUID_INTEL_PWR    = "3619c3f2-afb2-4afc-b0e9-e7fef372de36"
$GUID_SUB_PCIE     = "501a4d13-42af-4429-9fd1-a8218c268e20"
$GUID_PCIE_ASPM    = "ee12f906-d277-404b-b6da-e5fa1a576df5"

# System Form Factor & OEM Detection (cached once at startup)
$global:SystemVendor = "Generic"
$global:SystemModel  = "PC"
$global:IsLaptop     = $false
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        if ($cs.Manufacturer) { $global:SystemVendor = $cs.Manufacturer.Trim() }
        if ($cs.Model)        { $global:SystemModel  = $cs.Model.Trim() }
        $global:IsLaptop = ($cs.PCSystemType -eq 2)
    }
    if (-not $global:IsLaptop) {
        $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($enc -and $enc.ChassisTypes) {
            # Chassis types 8,9,10,11,12,14,18,21,30,31,32 = Portable / Laptop / Notebook / Convertible
            foreach ($ct in $enc.ChassisTypes) {
                if ($ct -in @(8,9,10,11,12,14,18,21,30,31,32)) { $global:IsLaptop = $true; break }
            }
        }
    }
} catch {}

# ---- Admin Elevation Check ----
function Invoke-AdminCheck {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
        try {
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        } catch {}
        exit
    }
}

# ---- Dynamic Universal GPU Detection (NVIDIA, AMD, Intel) ----
function Get-UniversalGpuList {
    $devs = Get-PnpDevice -Class "Display" -ErrorAction SilentlyContinue | Where-Object {
        $_.Present -and $_.FriendlyName -notmatch 'Basic Render|Basic Display|Remote|Virtual|Citrix|DisplayLink|Parsec|spacedesk'
    }

    $classPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $gpus = @()

    foreach ($d in $devs) {
        # Determine vendor (Hardware VEN ID takes priority, then word-bounded name matching)
        $vendor = "Unknown"
        if ($d.InstanceId -match "VEN_10DE" -or $d.Manufacturer -match "NVIDIA" -or $d.FriendlyName -match "NVIDIA|GeForce|RTX|GTX|TITAN|Quadro") {
            $vendor = "NVIDIA"
        } elseif ($d.InstanceId -match "VEN_1002" -or $d.Manufacturer -match "\bAMD\b|Advanced Micro Devices|\bATI\b" -or $d.FriendlyName -match "\bAMD\b|Radeon|\bATI\b") {
            $vendor = "AMD"
        } elseif ($d.InstanceId -match "VEN_8086" -or $d.Manufacturer -match "\bIntel\b" -or $d.FriendlyName -match "\bIntel\b|Arc|Xe|Iris|UHD|HD Graphics") {
            $vendor = "Intel"
        }

        # Classify Type: Discrete vs Integrated
        $isDiscrete = (
            $vendor -eq "NVIDIA" -or
            ($vendor -eq "AMD" -and $d.FriendlyName -match '\bRX\b|\bR9\b|\bR7\b|\bR5\b|Vega 56|Vega 64|Radeon VII|Radeon Pro|FirePro|\bHD\s*[4-8]\d{3}') -or
            ($vendor -eq "Intel" -and $d.FriendlyName -match '\bArc\s*[AB]\d{3}|\bArc\s*Pro')
        )

        # Classify Architecture / Generation (Modern & Legacy)
        $gen = ""
        if ($vendor -eq "AMD") {
            if ($d.FriendlyName -match 'RX 90\d{2}|RX 8\d{3}|RDNA 4|Navi 4') {
                $gen = "RDNA 4 (Radeon RX 9000/8000 Series)"
            } elseif ($d.FriendlyName -match 'RX 7\d{3}|Radeon [78]\d{2}M|RDNA 3|Navi 3') {
                $gen = "RDNA 3 / 3.5 (Radeon RX 7000 / 700M-800M)"
            } elseif ($d.FriendlyName -match 'RX 6\d{3}|Radeon 6\d{2}M|RDNA 2|Navi 2') {
                $gen = "RDNA 2 (Radeon RX 6000 / 600M Series)"
            } elseif ($d.FriendlyName -match 'RX 5\d{3}|RDNA 1|Navi 1') {
                $gen = "RDNA 1 (Radeon RX 5000 Series)"
            } elseif ($d.FriendlyName -match 'Radeon VII|Vega 64|Vega 56|Vega \d+|Radeon RX Vega') {
                $gen = "Vega (GCN 5th Gen)"
            } elseif ($d.FriendlyName -match 'RX 590|RX 580|RX 570|RX 560|RX 550|RX 480|RX 470|RX 460|Polaris') {
                $gen = "Polaris (GCN 4th Gen / RX 400-500)"
            } elseif ($d.FriendlyName -match 'R9|R7|R5|HD \d{4}|Fiji|Hawaii|Tahiti|Pitcairn') {
                $gen = "Legacy GCN / TeraScale (HD / R-Series)"
            } else {
                $gen = "AMD Radeon Graphics"
            }
        } elseif ($vendor -eq "NVIDIA") {
            if ($d.FriendlyName -match 'RTX 50\d{2}|Blackwell') { $gen = "Blackwell (RTX 50-Series)" }
            elseif ($d.FriendlyName -match 'RTX 40\d{2}|Ada|RTX \d{4} Ada') { $gen = "Ada Lovelace (RTX 40-Series)" }
            elseif ($d.FriendlyName -match 'RTX 30\d{2}|Ampere|RTX A\d{4}') { $gen = "Ampere (RTX 30-Series)" }
            elseif ($d.FriendlyName -match 'RTX 20\d{2}|GTX 16\d{2}|Turing') { $gen = "Turing (RTX 20 / GTX 16)" }
            elseif ($d.FriendlyName -match 'GTX 10\d{2}|Pascal|GT 10\d{2}') { $gen = "Pascal (GTX 10-Series)" }
            elseif ($d.FriendlyName -match 'GTX 9\d{2}|Maxwell|GT 9\d{2}M') { $gen = "Maxwell (GTX 900-Series)" }
            elseif ($d.FriendlyName -match 'GTX [67]\d{2}|GT [67]\d{2}|Kepler') { $gen = "Kepler (GTX 600/700-Series)" }
            elseif ($d.FriendlyName -match 'Quadro|TITAN|Tesla') { $gen = "NVIDIA Workstation / TITAN" }
            else { $gen = "NVIDIA GeForce Architecture" }
        } elseif ($vendor -eq "Intel") {
            if ($d.FriendlyName -match 'Arc\s*B\d{3}') { $gen = "Intel Xe2 Battlemage (Arc B-Series)" }
            elseif ($d.FriendlyName -match 'Arc\s*A\d{3}|Arc\s*Pro') { $gen = "Intel Xe Alchemist (Arc A-Series)" }
            elseif ($d.FriendlyName -match 'Arc') { $gen = "Intel Arc Integrated (Xe-LPG / Xe2)" }
            elseif ($d.FriendlyName -match 'Iris') { $gen = "Intel Iris / Xe Graphics" }
            elseif ($d.FriendlyName -match 'UHD') { $gen = "Intel UHD Graphics" }
            elseif ($d.FriendlyName -match 'HD Graphics') { $gen = "Intel HD Graphics (Legacy)" }
            else { $gen = "Intel Graphics Architecture" }
        } else {
            $gen = "Standard WDDM Display Adapter"
        }

        # Match exact driver registry key via Windows PnP DEVPKEY_Device_Driver first
        $regPath = $null
        try {
            $drvKey = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction SilentlyContinue).Data
            if ($drvKey) {
                $candidate = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drvKey"
                if (Test-Path $candidate) { $regPath = $candidate }
            }
        } catch {}

        # Dynamic fallback: scan all subkeys under Display Class (handles any index, not just 0..20)
        if (-not $regPath -and (Test-Path $classPath)) {
            $allClassKeys = Get-ChildItem $classPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
            if ($d.InstanceId -match '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})') {
                $hwMatch = $matches[1]
                foreach ($k in $allClassKeys) {
                    $m = (Get-ItemProperty $k.PSPath -Name MatchingDeviceId -ErrorAction SilentlyContinue).MatchingDeviceId
                    if ($m -and $m -match [regex]::Escape($hwMatch)) { $regPath = $k.PSPath; break }
                }
            }
            if (-not $regPath) {
                foreach ($k in $allClassKeys) {
                    $desc = (Get-ItemProperty $k.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
                    if ($desc -and $desc -eq $d.FriendlyName) { $regPath = $k.PSPath; break }
                }
            }
        }
        if (-not $regPath) { $regPath = "$classPath\0000" }

        $regIndex = if ($regPath -match '\\([0-9]{4})$') { $matches[1] } else { "0000" }

        # Extract PCI Bus / Device for multi-GPU matching
        $pciBus = $null; $pciDev = $null
        try {
            $loc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
            if ($loc -match 'bus\s+(\d+),\s+device\s+(\d+)') {
                $pciBus = [int]$matches[1]
                $pciDev = [int]$matches[2]
            }
        } catch {}

        $gpus += [pscustomobject]@{
            Device       = $d
            InstanceId   = $d.InstanceId
            FriendlyName = $d.FriendlyName
            Manufacturer = $d.Manufacturer
            Vendor       = $vendor
            IsDiscrete   = $isDiscrete
            Generation   = $gen
            RegPath      = $regPath
            RegIndex     = $regIndex
            PciBus       = $pciBus
            PciDev       = $pciDev
            Status       = $d.Status
        }
    }

    return $gpus
}

# Initial GPU Discovery
$global:AvailableGpus = Get-UniversalGpuList
# Sort so discrete GPUs appear first
$global:AvailableGpus = @($global:AvailableGpus | Sort-Object { if ($_.IsDiscrete) { 0 } else { 1 } })

if ($global:AvailableGpus.Count -gt 0) {
    $global:ActiveGpuIndex = 0
    $global:GpuInfo = $global:AvailableGpus[0]
} else {
    $global:ActiveGpuIndex = 0
    $global:GpuInfo = [pscustomobject]@{
        Device       = $null
        InstanceId   = "PCI\VEN_10DE*"
        FriendlyName = "GPU Device"
        Manufacturer = "Unknown"
        Vendor       = "Unknown"
        IsDiscrete   = $true
        Generation   = "Standard GPU"
        RegPath      = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000"
        RegIndex     = "0000"
        PciBus       = $null
        PciDev       = $null
        Status       = "Unknown"
    }
}

# ---- Hardware Monitor Globals (LibreHardwareMonitor & Direct NVML P/Invoke) ----
$global:LhmComputer       = $null
$global:LhmNvidiaGpus     = @()
$global:LhmAmdGpus        = @()
$global:LhmIntelGpus      = @()
$global:LhmCpuHardware    = $null
$global:LhmInitialized    = $false

# Direct C# NVML Wrapper (supports both modern System32 DCH and legacy NVSMI nvml.dll paths)
$global:NvmlAvailable     = $false
$global:NvmlDevice        = [IntPtr]::Zero
$global:NvmlInitialized   = $false
$global:NvmlExePath       = $null

# OEM WMI / Fan Polling Cache (universal laptop/desktop support with zero tick lag)
$global:OemWmiProbed      = $false
$global:OemWmiMode        = "None"
$global:OemWmiObj         = $null
$global:LastFanPollTime   = [DateTime]::MinValue
$global:CachedFanResult   = $null

function Get-NvmlExePath {
    if ($global:NvmlExePath) { return $global:NvmlExePath }
    $paths = @(
        "nvidia-smi",
        "$env:SystemRoot\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    foreach ($p in $paths) {
        if ($p -eq "nvidia-smi") {
            if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) { $global:NvmlExePath = "nvidia-smi"; return $p }
        } elseif (Test-Path $p) {
            $global:NvmlExePath = $p; return $p
        }
    }
    return $null
}

function Init-Nvml {
    if ($global:NvmlInitialized) { return $global:NvmlAvailable }
    $global:NvmlInitialized = $true

    $dllCandidates = @(
        "$env:SystemRoot\System32\nvml.dll",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvml.dll"
    )
    $foundDll = $dllCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $foundDll) { return $false }

    try {
        if (-not ('NvmlWrapper' -as [type])) {
            $nvmlCode = @"
using System;
using System.Text;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct NvmlUtilization {
    public uint Gpu;
    public uint Memory;
}

[StructLayout(LayoutKind.Sequential)]
public struct NvmlMemory {
    public ulong Total;
    public ulong Free;
    public ulong Used;
}

public class NvmlWrapper {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("nvml.dll", EntryPoint = "nvmlInit_v2")]
    public static extern int Init();

    [DllImport("nvml.dll", EntryPoint = "nvmlShutdown")]
    public static extern int Shutdown();

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCount_v2")]
    public static extern int GetCount(out uint count);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetHandleByIndex_v2")]
    public static extern int GetHandle(uint index, out IntPtr device);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetName", CharSet = CharSet.Ansi)]
    public static extern int GetName(IntPtr device, StringBuilder name, uint length);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetTemperature")]
    public static extern int GetTemperature(IntPtr device, int sensorType, out uint temp);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetPowerUsage")]
    public static extern int GetPowerUsage(IntPtr device, out uint powerMilliWatts);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetEnforcedPowerLimit")]
    public static extern int GetEnforcedPowerLimit(IntPtr device, out uint limitMilliWatts);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetPowerManagementLimit")]
    public static extern int GetPowerManagementLimit(IntPtr device, out uint limitMilliWatts);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetPowerManagementDefaultLimit")]
    public static extern int GetDefaultPowerLimit(IntPtr device, out uint limitMilliWatts);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetFanSpeed")]
    public static extern int GetFanSpeed(IntPtr device, out uint fanSpeed);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetFanSpeed_v2")]
    public static extern int GetFanSpeedV2(IntPtr device, uint fanIndex, out uint fanSpeed);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetClockInfo")]
    public static extern int GetClockInfo(IntPtr device, int type, out uint clock);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetUtilizationRates")]
    public static extern int GetUtilizationRates(IntPtr device, out NvmlUtilization rates);

    [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetMemoryInfo")]
    public static extern int GetMemoryInfo(IntPtr device, out NvmlMemory memory);
}
"@
            Add-Type -TypeDefinition $nvmlCode -ErrorAction Stop
        }

        # Pre-load exact nvml.dll path (handles legacy Program Files\NVIDIA Corporation\NVSMI too)
        [void][NvmlWrapper]::LoadLibrary($foundDll)

        $r = [NvmlWrapper]::Init()
        if ($r -eq 0) {
            $global:NvmlAvailable = $true
            $global:NvmlDevice = Get-NvmlDeviceForActiveGpu
            return ($global:NvmlDevice -ne [IntPtr]::Zero)
        }
    } catch {}
    return $false
}

function Get-NvmlDeviceForActiveGpu {
    if (-not $global:NvmlAvailable) { return [IntPtr]::Zero }
    $count = [uint32]0
    $cr = [NvmlWrapper]::GetCount([ref]$count)
    if ($cr -ne 0 -or $count -eq 0) {
        $dev0 = [IntPtr]::Zero
        if (([NvmlWrapper]::GetHandle(0, [ref]$dev0)) -eq 0) { return $dev0 }
        return [IntPtr]::Zero
    }

    if ($count -eq 1) {
        $dev0 = [IntPtr]::Zero
        if (([NvmlWrapper]::GetHandle(0, [ref]$dev0)) -eq 0) { return $dev0 }
        return [IntPtr]::Zero
    }

    # Multi-NVIDIA system: match active GPU name
    $targetName = $global:GpuInfo.FriendlyName
    for ($i = [uint32]0; $i -lt $count; $i++) {
        $d = [IntPtr]::Zero
        if (([NvmlWrapper]::GetHandle($i, [ref]$d)) -eq 0 -and $d -ne [IntPtr]::Zero) {
            $sb = New-Object System.Text.StringBuilder 96
            if (([NvmlWrapper]::GetName($d, $sb, 96)) -eq 0) {
                $nvName = $sb.ToString().Trim()
                if ($targetName -match [regex]::Escape($nvName) -or $nvName -match [regex]::Escape($targetName)) {
                    return $d
                }
            }
        }
    }

    $fallback = [IntPtr]::Zero
    [void][NvmlWrapper]::GetHandle(0, [ref]$fallback)
    return $fallback
}

function Init-GpuHardwareMonitor {
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
            $comp.IsGpuEnabled = $true
            $comp.IsCpuEnabled = $true
            # Enable Motherboard SuperIO & Fan Controllers on Desktops (and fallback)
            if (-not $global:IsLaptop) {
                $comp.IsMotherboardEnabled = $true
                $comp.IsControllerEnabled  = $true
            }
            $comp.Open()
            $global:LhmComputer = $comp
            $nvList = @(); $amdList = @(); $intList = @()
            foreach ($hw in $comp.Hardware) {
                if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia) { $nvList += $hw }
                elseif ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd) { $amdList += $hw }
                elseif ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuIntel) { $intList += $hw }
                elseif ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) { $global:LhmCpuHardware = $hw }
            }
            $global:LhmNvidiaGpus = $nvList
            $global:LhmAmdGpus    = $amdList
            $global:LhmIntelGpus  = $intList
            $global:LhmInitialized = $true
            return $true
        } catch {}
    }
    return $false
}

function Get-LhmHardwareForActiveGpu {
    if (-not (Init-GpuHardwareMonitor)) { return $null }
    $active = $global:GpuInfo
    $list = switch ($active.Vendor) {
        "NVIDIA" { $global:LhmNvidiaGpus }
        "AMD"    { $global:LhmAmdGpus }
        "Intel"  { $global:LhmIntelGpus }
        default  { @($global:LhmComputer.Hardware | Where-Object { $_.HardwareType -match 'Gpu' }) }
    }
    if ($list.Count -eq 1) { return $list[0] }
    if ($list.Count -gt 1) {
        $match = $list | Where-Object { $_.Name -eq $active.FriendlyName -or $active.FriendlyName -match [regex]::Escape($_.Name) } | Select-Object -First 1
        if ($match) { return $match }
        return $list[0]
    }
    return ($global:LhmComputer.Hardware | Where-Object { $_.HardwareType -match 'Gpu' } | Select-Object -First 1)
}

function Get-SharedDieTemperature {
    # For Integrated GPUs (Intel iGPU / AMD APU), the GPU shares the CPU Package die
    if ($global:LhmInitialized -and $null -ne $global:LhmCpuHardware) {
        try {
            $global:LhmCpuHardware.Update()
            $tempType = [LibreHardwareMonitor.Hardware.SensorType]::Temperature
            $s = $global:LhmCpuHardware.Sensors | Where-Object {
                $_.SensorType -eq $tempType -and $_.Name -match 'CPU Package|Core Max|Core Average|Core \(Tctl/Tdie\)'
            } | Select-Object -First 1
            if ($s -and $s.Value -and [double]$s.Value -gt 15 -and [double]$s.Value -lt 130) {
                return [math]::Round([double]$s.Value)
            }
        } catch {}
    }
    try {
        $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
        if ($tz) {
            $max = ($tz | ForEach-Object { [math]::Round(($_.CurrentTemperature - 2732) / 10) } | Where-Object { $_ -gt 29 -and $_ -lt 120 } | Measure-Object -Maximum).Maximum
            if ($max) { return [int]$max }
        }
    } catch {}
    return $null
}

# Universal OEM Laptop EC WMI Probe (auto-detects ASUS, Lenovo, Dell/Alienware, HP, or Win32_Fan)
function Get-OemEcFanRpm {
    if (-not $global:OemWmiProbed) {
        $global:OemWmiProbed = $true
        $mfg = $global:SystemVendor

        # 1. ASUS (TUF / ROG / ZenBook / VivoBook)
        if ($mfg -match 'ASUS') {
            try {
                $wmi = Get-CimInstance -Namespace 'root/wmi' -ClassName 'AsusAtkWmi_WMNB' -ErrorAction Stop
                if ($wmi) { $global:OemWmiMode = "ASUS"; $global:OemWmiObj = $wmi }
            } catch {}
        }

        # 2. Lenovo (Legion / LOQ / IdeaPad Gaming)
        if ($global:OemWmiMode -eq "None" -and $mfg -match 'LENOVO') {
            foreach ($cls in @('LENOVO_GAMEZONE_DATA', 'LENOVO_FAN_METHOD', 'LENOVO_OTHER_METHOD')) {
                try {
                    $wmi = Get-CimInstance -Namespace 'root/wmi' -ClassName $cls -ErrorAction Stop | Select-Object -First 1
                    if ($wmi) { $global:OemWmiMode = "LENOVO:$cls"; $global:OemWmiObj = $wmi; break }
                } catch {}
            }
        }

        # 3. Dell / Alienware
        if ($global:OemWmiMode -eq "None" -and $mfg -match 'Dell|Alienware') {
            try {
                $wmi = Get-CimInstance -Namespace 'root/dcim/sysman' -ClassName 'DCIM_FanSensor' -ErrorAction Stop
                if ($wmi) { $global:OemWmiMode = "DELL_DCIM" }
            } catch {}
        }
    }

    try {
        if ($global:OemWmiMode -eq "ASUS" -and $null -ne $global:OemWmiObj) {
            # Query GPU fan (0x00110014), fallback to CPU/unified fan (0x00110013)
            foreach ($src in @([uint32]0x00110014, [uint32]0x00110013)) {
                $res = Invoke-CimMethod -InputObject $global:OemWmiObj -MethodName 'DSTS' -Arguments @{ Source = $src } -ErrorAction SilentlyContinue
                if ($res -and $null -ne $res.device_status) {
                    $rpm = [uint32]$res.device_status -band 0xFFFF
                    if ($rpm -gt 0 -and $rpm -lt 15000) { return [int]$rpm }
                    if ($src -eq 0x00110014 -and $rpm -eq 0) { return 0 }
                }
            }
        } elseif ($global:OemWmiMode -like "LENOVO:*" -and $null -ne $global:OemWmiObj) {
            foreach ($m in @('GetFan2Speed', 'GetFan1Speed', 'GetFanSpeed')) {
                try {
                    $res = Invoke-CimMethod -InputObject $global:OemWmiObj -MethodName $m -ErrorAction SilentlyContinue
                    if ($res) {
                        $val = if ($null -ne $res.Data) { [int]$res.Data } elseif ($null -ne $res.CurrentFanSpeed) { [int]$res.CurrentFanSpeed } else { $null }
                        if ($null -ne $val -and $val -ge 0 -and $val -lt 15000) { return $val }
                    }
                } catch {}
            }
        } elseif ($global:OemWmiMode -eq "DELL_DCIM") {
            $fans = Get-CimInstance -Namespace 'root/dcim/sysman' -ClassName 'DCIM_FanSensor' -ErrorAction SilentlyContinue
            if ($fans) {
                $gpuFan = $fans | Where-Object { $_.ElementName -match 'GPU|Video|Fan 2' } | Select-Object -First 1
                if (-not $gpuFan) { $gpuFan = $fans | Select-Object -First 1 }
                if ($gpuFan -and $null -ne $gpuFan.CurrentReading) { return [int]$gpuFan.CurrentReading }
            }
        }
    } catch {
        $global:OemWmiProbed = $false
        $global:OemWmiObj    = $null
    }

    # Generic ACPI Win32_Fan DesiredSpeed check (some OEM BIOSes populate this)
    try {
        $wFan = Get-CimInstance Win32_Fan -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.DesiredSpeed -and $_.DesiredSpeed -gt 0 } | Select-Object -First 1
        if ($wFan) { return [int]$wFan.DesiredSpeed }
    } catch {}

    return $null
}

# Universal Fan Telemetry (Desktop NVML, LHM GPU/SuperIO, Multi-OEM Laptop EC WMI, Verified Zero-RPM)
function Get-GpuFanTelemetry {
    param([int]$Temp = 0, [string]$Vendor = "NVIDIA", $LhmGpuHw = $null)

    # Integrated GPUs rarely have a dedicated GPU fan (share laptop chassis/CPU cooling)
    if (-not $global:GpuInfo.IsDiscrete -and $global:IsLaptop) {
        return "Shared (CPU/Chassis Cooling)"
    }

    # 1. Desktop NVIDIA GPU via NVML (supports multi-fan v2 + classic v1)
    if ($Vendor -eq "NVIDIA" -and $global:NvmlAvailable -and $global:NvmlDevice -ne [IntPtr]::Zero) {
        $fanSpeed = [uint32]0
        $fr = [NvmlWrapper]::GetFanSpeedV2($global:NvmlDevice, 0, [ref]$fanSpeed)
        if ($fr -ne 0) {
            $fr = [NvmlWrapper]::GetFanSpeed($global:NvmlDevice, [ref]$fanSpeed)
        }
        if ($fr -eq 0 -and $fanSpeed -le 100) {
            if ($fanSpeed -eq 0) { return "0% (0dB Silent)" }
            return "$fanSpeed%"
        }
    }

    # 2. LHM Active GPU Hardware Fan Sensors (AMD Desktop/Mobile, Intel Arc, NVIDIA via LHM)
    if ($null -ne $LhmGpuHw) {
        try {
            $fanSensors = @($LhmGpuHw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan })
            if ($fanSensors.Count -gt 0) {
                $maxRpm = ($fanSensors | Where-Object { $null -ne $_.Value } | Measure-Object -Property Value -Maximum).Maximum
                if ($null -ne $maxRpm) {
                    $rpmInt = [math]::Round([double]$maxRpm)
                    if ($rpmInt -eq 0) { return "0 RPM (0dB Silent)" }
                    return "$rpmInt RPM"
                }
            }
            $ctrlSensors = @($LhmGpuHw.Sensors | Where-Object { $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Control -and $_.Name -match 'Fan' })
            if ($ctrlSensors.Count -gt 0) {
                $maxPct = ($ctrlSensors | Where-Object { $null -ne $_.Value } | Measure-Object -Property Value -Maximum).Maximum
                if ($null -ne $maxPct) {
                    $pctInt = [math]::Round([double]$maxPct)
                    if ($pctInt -eq 0) { return "0% (0dB Silent)" }
                    return "$pctInt%"
                }
            }
        } catch {}
    }

    # Throttle WMI & Motherboard SuperIO fan polling to every 400ms to keep 0.1s loop ultra-responsive
    $now = [DateTime]::UtcNow
    if ($null -ne $global:CachedFanResult -and ($now - $global:LastFanPollTime).TotalMilliseconds -lt 400) {
        return $global:CachedFanResult
    }
    $global:LastFanPollTime = $now

    # 3. Universal OEM Laptop EC / BIOS Fan Tachometer (ASUS, Lenovo, Dell/Alienware, ACPI)
    $oemRpm = Get-OemEcFanRpm
    if ($null -ne $oemRpm) {
        if ($oemRpm -eq 0) {
            $global:CachedFanResult = "0 RPM (0dB Silent)"
        } else {
            $global:CachedFanResult = "$oemRpm RPM"
        }
        return $global:CachedFanResult
    }

    # 4. Desktop Motherboard SuperIO & Fan Controllers (recursive SubHardware scan)
    if ($global:LhmInitialized -and $global:LhmComputer) {
        try {
            foreach ($h in $global:LhmComputer.Hardware) {
                if ($h.HardwareType -in @([LibreHardwareMonitor.Hardware.HardwareType]::Motherboard, [LibreHardwareMonitor.Hardware.HardwareType]::SuperIO, [LibreHardwareMonitor.Hardware.HardwareType]::Cooler)) {
                    $h.Update()
                    $allNodes = @($h) + @($h.SubHardware)
                    foreach ($node in $allNodes) {
                        if ($node -ne $h) { $node.Update() }
                        $s = $node.Sensors | Where-Object {
                            $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan -and
                            $_.Name -match 'GPU|VGA|PCIE|Aux|Fan #2|System' -and $_.Value -gt 0
                        } | Select-Object -First 1
                        if ($s -and $s.Value) {
                            $global:CachedFanResult = "$([math]::Round([double]$s.Value)) RPM"
                            return $global:CachedFanResult
                        }
                    }
                }
            }
        } catch {}
    }

    # 5. Honest Universal Fallback (no tachometer exposed to OS)
    if ($global:IsLaptop) {
        $global:CachedFanResult = "Auto (EC Managed)"
    } else {
        $global:CachedFanResult = "Auto (Driver Managed)"
    }
    return $global:CachedFanResult
}

# ---- GPU Device Queries ----
function Get-GpuDeviceStatus {
    try {
        $device = Get-PnpDevice -InstanceId $global:GpuInfo.InstanceId -ErrorAction SilentlyContinue
        if ($null -eq $device) { return "NotFound" }
        return $device.Status
    } catch { return "Error" }
}

function Get-GpuLiveStats {
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor

    # Method 1: High-Speed Direct NVML Telemetry for NVIDIA (~0.1ms, exact board power & TGP limits)
    if ($vendor -eq "NVIDIA" -and (Init-Nvml)) {
        try {
            if ($global:NvmlDevice -eq [IntPtr]::Zero) {
                $global:NvmlDevice = Get-NvmlDeviceForActiveGpu
            }
            $dev = $global:NvmlDevice
            if ($dev -ne [IntPtr]::Zero) {
                $tempUint = [uint32]0
                $tr = [NvmlWrapper]::GetTemperature($dev, 0, [ref]$tempUint)
                if ($tr -eq 0) {
                    $tempVal = [int]$tempUint

                    # Real Board Power Draw (milliwatts -> Watts)
                    $pw = [uint32]0
                    $pr = [NvmlWrapper]::GetPowerUsage($dev, [ref]$pw)
                    $powerDraw = if ($pr -eq 0 -and $pw -gt 0) { [math]::Round($pw / 1000.0, 1) } else { "Auto" }

                    # Power Limit chain: Enforced (Dynamic Boost) -> Management Limit -> Default Limit -> Dynamic
                    $lim = [uint32]0
                    $lr = [NvmlWrapper]::GetEnforcedPowerLimit($dev, [ref]$lim)
                    if ($lr -ne 0 -or $lim -eq 0) {
                        $lr = [NvmlWrapper]::GetPowerManagementLimit($dev, [ref]$lim)
                    }
                    if ($lr -ne 0 -or $lim -eq 0) {
                        $lr = [NvmlWrapper]::GetDefaultPowerLimit($dev, [ref]$lim)
                    }
                    $powerLimit = if ($lr -eq 0 -and $lim -gt 0) { [math]::Round($lim / 1000.0, 1) } else { "Dynamic" }

                    # Clocks
                    $coreClk = [uint32]0
                    [void][NvmlWrapper]::GetClockInfo($dev, 0, [ref]$coreClk)
                    $memClk = [uint32]0
                    [void][NvmlWrapper]::GetClockInfo($dev, 2, [ref]$memClk)

                    # Utilization
                    $util = New-Object NvmlUtilization
                    [void][NvmlWrapper]::GetUtilizationRates($dev, [ref]$util)

                    # VRAM
                    $mem = New-Object NvmlMemory
                    [void][NvmlWrapper]::GetMemoryInfo($dev, [ref]$mem)
                    $vramUsed  = if ($mem.Total -gt 0) { [math]::Round($mem.Used / 1MB) } else { 0 }
                    $vramTotal = if ($mem.Total -gt 0) { [math]::Round($mem.Total / 1MB) } else { "N/A" }

                    # HotSpot & LHM Fan via LHM (if available)
                    $hotspotVal = $null
                    $lhmHw = Get-LhmHardwareForActiveGpu
                    if ($null -ne $lhmHw -and $lhmHw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia) {
                        try {
                            $lhmHw.Update()
                            $hotspotVal = ($lhmHw.Sensors | Where-Object {
                                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $_.Name -match 'Hot Spot|Junction'
                            } | Select-Object -First 1).Value
                            if ($hotspotVal) { $hotspotVal = [math]::Round([double]$hotspotVal) }
                        } catch {}
                    }

                    $fanSpeed = Get-GpuFanTelemetry -Temp $tempVal -Vendor "NVIDIA" -LhmGpuHw $lhmHw

                    return [pscustomobject]@{
                        Temperature  = $tempVal
                        HotSpot      = $hotspotVal
                        TempNote     = $null
                        PowerDraw    = $powerDraw
                        PowerLimit   = $powerLimit
                        CoreClock    = if ($coreClk -gt 0) { $coreClk } else { "N/A" }
                        MemClock     = if ($memClk -gt 0) { $memClk } else { "N/A" }
                        MaxCoreClock = "N/A"
                        GpuUtil      = $util.Gpu
                        MemUtil      = $util.Memory
                        PState       = "P0"
                        FanSpeed     = $fanSpeed
                        MemUsed      = $vramUsed
                        MemTotal     = $vramTotal
                        Source       = "NVML (Driver Direct P/Invoke)"
                    }
                }
            }
        } catch {}
    }

    # Method 2: High-speed in-memory telemetry via LibreHardwareMonitor (AMD, Intel Arc/iGPU, Legacy NVIDIA)
    $hw = Get-LhmHardwareForActiveGpu
    if ($null -ne $hw) {
        try {
            $hw.Update()
            $sensors = $hw.Sensors

            # Temperature (Core & Hotspot/Junction)
            $tempVal = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $_.Name -match 'GPU Core|GPU VR VDDC|GPU Temp'
            } | Select-Object -First 1).Value

            $hotspotVal = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and $_.Name -match 'Hot Spot|Junction'
            } | Select-Object -First 1).Value

            if ($null -eq $tempVal -and $null -ne $hotspotVal) {
                $tempVal = $hotspotVal
            }

            $tempNote = $null
            if ($null -eq $tempVal -and -not $activeGpu.IsDiscrete) {
                $sharedTemp = Get-SharedDieTemperature
                if ($null -ne $sharedTemp) {
                    $tempVal  = $sharedTemp
                    $tempNote = "Shared CPU Die"
                }
            }

            # Clocks (Core & Memory)
            $coreClock = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Clock -and $_.Name -match 'GPU Core|GPU Shader'
            } | Select-Object -First 1).Value

            $memClock = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Clock -and $_.Name -match 'GPU Memory'
            } | Select-Object -First 1).Value

            # Utilization (Hardware Core/Memory, falling back to D3D 3D engine for Intel iGPU/older cards)
            $gpuUtil = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $_.Name -match 'GPU Core|D3D 3D'
            } | Sort-Object { if ($_.Name -match 'GPU Core') { 0 } else { 1 } } | Select-Object -First 1).Value

            $memUtil = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Load -and $_.Name -match 'GPU Memory'
            } | Select-Object -First 1).Value

            # VRAM (Dedicated Used/Total, or Shared Memory Used/Total for Integrated GPUs)
            $memUsed = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::SmallData -and $_.Name -match 'Dedicated Memory Used|GPU Memory Used|D3D Shared Memory Used'
            } | Sort-Object { if ($_.Name -match 'Dedicated|GPU Memory') { 0 } else { 1 } } | Select-Object -First 1).Value

            $memTotal = ($sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::SmallData -and $_.Name -match 'GPU Memory Total|Memory Total|D3D Shared Memory Total'
            } | Sort-Object { if ($_.Name -match 'Dedicated|GPU Memory Total') { 0 } else { 1 } } | Select-Object -First 1).Value

            if ($null -eq $memUtil -and $memUsed -and $memTotal -and [double]$memTotal -gt 0) {
                $memUtil = [math]::Round(([double]$memUsed / [double]$memTotal) * 100)
            }

            # Power Draw (Total/PPT prioritized over Package/Core)
            $powerSensor = $sensors | Where-Object {
                $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -and $_.Name -match 'GPU Total|PPT|GPU Package|GPU ASIC|GPU Chip|GPU Core|GPU Power'
            } | Sort-Object {
                if ($_.Name -match 'Total|PPT') { 0 }
                elseif ($_.Name -match 'Package|ASIC') { 1 }
                else { 2 }
            } | Select-Object -First 1
            $powerVal = if ($powerSensor) { $powerSensor.Value } else { $null }

            # Power Limit
            $limitSensor = $sensors | Where-Object {
                ($_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Power -or
                 $_.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::SmallData) -and
                $_.Name -match 'Power Limit|TDP Limit|PPT Limit'
            } | Select-Object -First 1
            $powerLimit = if ($limitSensor -and $limitSensor.Value) { [math]::Round([double]$limitSensor.Value, 1) } else { "Dynamic" }

            # Fan Speed
            $tInt = if ($tempVal) { [math]::Round([double]$tempVal) } else { 0 }
            $fanSpeed = Get-GpuFanTelemetry -Temp $tInt -Vendor $vendor -LhmGpuHw $hw

            # Return whenever ANY sensor data is available (supports iGPUs & legacy GPUs without thermal diodes)
            if ($null -ne $tempVal -or $null -ne $gpuUtil -or $null -ne $memUsed -or $null -ne $powerVal) {
                return [pscustomobject]@{
                    Temperature  = if ($null -ne $tempVal) { [math]::Round([double]$tempVal) } else { "N/A" }
                    HotSpot      = if ($hotspotVal) { [math]::Round([double]$hotspotVal) } else { $null }
                    TempNote     = $tempNote
                    PowerDraw    = if ($powerVal) { [math]::Round([double]$powerVal, 1) } else { "Auto" }
                    PowerLimit   = $powerLimit
                    CoreClock    = if ($coreClock) { [math]::Round([double]$coreClock) } else { "N/A" }
                    MemClock     = if ($memClock) { [math]::Round([double]$memClock) } else { "N/A" }
                    MaxCoreClock = "N/A"
                    GpuUtil      = if ($gpuUtil) { [math]::Round([double]$gpuUtil) } else { 0 }
                    MemUtil      = if ($memUtil) { [math]::Round([double]$memUtil) } else { 0 }
                    PState       = "P0"
                    FanSpeed     = $fanSpeed
                    MemUsed      = if ($memUsed) { [math]::Round([double]$memUsed) } else { 0 }
                    MemTotal     = if ($memTotal) { [math]::Round([double]$memTotal) } else { "N/A" }
                    Source       = "LHM ($vendor Hardware/D3D)"
                }
            }
        } catch {}
    }

    # Method 3: Fallback for NVIDIA via nvidia-smi (supports both System32 & legacy NVSMI folder)
    if ($vendor -eq "NVIDIA") {
        $smiExe = Get-NvmlExePath
        if ($smiExe) {
            try {
                $raw = & $smiExe --query-gpu=temperature.gpu,power.draw,enforced.power.limit,clocks.current.graphics,clocks.max.graphics,utilization.gpu,utilization.memory,pstate,fan.speed,memory.used,memory.total --format=csv,noheader,nounits 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $parts = ($raw -join '').Split(',')
                    if ($parts.Count -ge 11) {
                        $sTemp = $parts[0].Trim()
                        $tInt = 0; try { $tInt = [int]$sTemp } catch {}
                        $sDraw = $parts[1].Trim()
                        if ($sDraw -match '\[N/A\]|N/A') { $sDraw = "Auto" }
                        $sLimit = $parts[2].Trim()
                        if ($sLimit -match '\[N/A\]|N/A') { $sLimit = "Dynamic" }
                        $sFan = $parts[8].Trim()
                        if ($sFan -match '\[N/A\]|N/A') {
                            $sFan = Get-GpuFanTelemetry -Temp $tInt -Vendor "NVIDIA"
                        }
                        return [pscustomobject]@{
                            Temperature  = $sTemp
                            HotSpot      = $null
                            TempNote     = $null
                            PowerDraw    = $sDraw
                            PowerLimit   = $sLimit
                            CoreClock    = $parts[3].Trim()
                            MemClock     = "N/A"
                            MaxCoreClock = $parts[4].Trim()
                            GpuUtil      = $parts[5].Trim()
                            MemUtil      = $parts[6].Trim()
                            PState       = $parts[7].Trim()
                            FanSpeed     = $sFan
                            MemUsed      = $parts[9].Trim()
                            MemTotal     = $parts[10].Trim()
                            Source       = "nvidia-smi"
                        }
                    }
                }
            } catch {}
        }
    }

    # Method 4: Universal Fallback via Windows WDDM D3D Performance Counters (works on any GPU without DLLs)
    try {
        $gpuLoad = (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'engtype_3D' } | Measure-Object -Property UtilizationPercentage -Maximum).Maximum
        $memCtrs = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction SilentlyContinue
        $vramMb = "N/A"
        if ($memCtrs) {
            if ($activeGpu.IsDiscrete) {
                $best = ($memCtrs | Sort-Object DedicatedUsage -Descending | Select-Object -First 1)
                if ($best -and $best.DedicatedUsage -gt 0) { $vramMb = [math]::Round($best.DedicatedUsage / 1MB) }
            } else {
                $best = ($memCtrs | Where-Object { $_.DedicatedUsage -eq 0 } | Sort-Object SharedUsage -Descending | Select-Object -First 1)
                if ($best -and $best.SharedUsage -gt 0) { $vramMb = [math]::Round($best.SharedUsage / 1MB) }
            }
        }
        $sharedTemp = if (-not $activeGpu.IsDiscrete) { Get-SharedDieTemperature } else { $null }
        if ($null -ne $gpuLoad -or $vramMb -ne "N/A") {
            return [pscustomobject]@{
                Temperature  = if ($null -ne $sharedTemp) { $sharedTemp } else { "N/A" }
                HotSpot      = $null
                TempNote     = if ($null -ne $sharedTemp) { "Shared Die" } else { $null }
                PowerDraw    = "Auto"
                PowerLimit   = "Dynamic"
                CoreClock    = "N/A"
                MemClock     = "N/A"
                MaxCoreClock = "N/A"
                GpuUtil      = if ($null -ne $gpuLoad) { [int]$gpuLoad } else { 0 }
                MemUtil      = 0
                PState       = "Active"
                FanSpeed     = Get-GpuFanTelemetry -Temp ([int]($sharedTemp -as [int])) -Vendor $vendor
                MemUsed      = $vramMb
                MemTotal     = "Dynamic"
                Source       = "Windows WDDM D3D Counter"
            }
        }
    } catch {}

    return $null
}

function Get-GpuPowerMode {
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor
    $regPath   = $activeGpu.RegPath

    if ($vendor -eq "NVIDIA") {
        try {
            $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            $rtpm  = $props.EnableRuntimePowerManagement
            $pmLvl = $props.PowerMizerLevel
            $perf  = $props.PerfLevelSrc
            if ($rtpm -eq 0 -or $pmLvl -eq 1 -or $perf -eq 0x2222) { return "Max Performance (Always On)" }
            elseif ($rtpm -eq 17 -or $pmLvl -eq 3 -or $perf -eq 0x3322) { return "Adaptive (Sleep Allowed)" }
            elseif ($null -ne $rtpm) { return "Driver Managed (RTPM=$rtpm)" }
            else { return "Standard (Driver Managed)" }
        } catch { return "Standard (Driver Managed)" }
    } elseif ($vendor -eq "AMD") {
        try {
            $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            $ulps  = $props.EnableUlps
            $delag = $props.KMD_DeLag
            if ($ulps -eq 0 -or $delag -eq 1) { return "Max Performance (ULPS Off / Low Latency)" }
            elseif ($ulps -eq 1) { return "Energy-Saving (ULPS Enabled / Deep Sleep)" }
            else { return "Standard (Driver Managed)" }
        } catch { return "Standard (Driver Managed)" }
    } elseif ($vendor -eq "Intel") {
        try {
            $out = powercfg /query SCHEME_CURRENT $GUID_SUB_GRAPHICS $GUID_INTEL_PWR 2>$null
            $acLine = $out | Select-String 'Current AC Power Setting Index:' | Select-Object -First 1
            if ($acLine -match '0x([0-9a-fA-F]+)') {
                $idx = [Convert]::ToInt32($matches[1], 16)
                if ($idx -eq 2) { return "Max Performance (Intel Power Plan)" }
                elseif ($idx -eq 1) { return "Balanced (Adaptive)" }
                elseif ($idx -eq 0) { return "Energy-Saving (Max Battery Life)" }
            }
        } catch {}
        return "Standard (Driver Managed)"
    } else {
        return "Standard / OS Managed"
    }
}

function Get-ActivePowerPlan {
    try {
        $guid = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes" -Name "ActivePowerScheme" -ErrorAction SilentlyContinue).ActivePowerScheme
        if ($guid) {
            $name = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$guid" -Name "FriendlyName" -ErrorAction SilentlyContinue).FriendlyName
            if ($name) { return $name }
        }
        $line = powercfg /getactivescheme 2>$null
        if ($line -match '\((.+)\)') { return $matches[1].Trim() }
    } catch {}
    return "Unknown"
}

function Set-PcieAspmMode {
    param([int]$AcIndex, [int]$DcIndex)
    try {
        powercfg /setacvalueindex SCHEME_CURRENT $GUID_SUB_PCIE $GUID_PCIE_ASPM $AcIndex 2>$null
        powercfg /setdcvalueindex SCHEME_CURRENT $GUID_SUB_PCIE $GUID_PCIE_ASPM $DcIndex 2>$null
        powercfg /setactive SCHEME_CURRENT 2>$null
        return $true
    } catch { return $false }
}

# ---- Universal PnP State Helper ----
function Set-GpuPnpState {
    param([string]$InstanceId, [ValidateSet('Enable', 'Disable')][string]$Action)
    $done = $false
    try {
        if ($Action -eq 'Enable' -and (Get-Command Enable-PnpDevice -ErrorAction SilentlyContinue)) {
            Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            $done = $true
        } elseif ($Action -eq 'Disable' -and (Get-Command Disable-PnpDevice -ErrorAction SilentlyContinue)) {
            Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            $done = $true
        }
    } catch {}

    if (-not $done) {
        try {
            $flag = if ($Action -eq 'Enable') { "/enable-device" } else { "/disable-device" }
            pnputil $flag $InstanceId 2>$null | Out-Null
            $done = $true
        } catch {}
    }
    return $done
}

# ---- Universal Vendor Power Profile Helper (Performance | EnergySaving | Default) ----
function Apply-GpuVendorPowerProfile {
    param([ValidateSet('Performance', 'EnergySaving', 'Default')][string]$Mode)

    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor
    $regPath   = $activeGpu.RegPath
    $hasReg    = Test-Path $regPath

    if ($vendor -eq "NVIDIA") {
        if ($hasReg) {
            if ($Mode -eq 'Performance') {
                try { Set-ItemProperty -Path $regPath -Name "EnableRuntimePowerManagement" -Value 0 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] NVIDIA runtime power management disabled (always on)." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "PerfLevelSrc" -Value 0x2222 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] GPU performance level forced to maximum (0x2222)." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "DisableDynamicPstate" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] Dynamic PState switching disabled." -ForegroundColor Green } catch {}
                # Legacy / Desktop NVIDIA PowerMizer compatibility (Kepler/Maxwell/Pascal/Desktop)
                try {
                    Set-ItemProperty -Path $regPath -Name "PowerMizerEnable" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $regPath -Name "PowerMizerLevel" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $regPath -Name "PowerMizerLevelAC" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    Write-Host "  [OK] Legacy/Desktop NVIDIA PowerMizer set to Prefer Max Performance." -ForegroundColor Green
                } catch {}
            } else {
                # EnergySaving or Default
                try { Set-ItemProperty -Path $regPath -Name "EnableRuntimePowerManagement" -Value 17 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] NVIDIA runtime power management set to Adaptive (sleep allowed)." -ForegroundColor Green } catch {}
                if ($Mode -eq 'EnergySaving') {
                    try { Set-ItemProperty -Path $regPath -Name "PerfLevelSrc" -Value 0x3322 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] GPU performance level set to adaptive (0x3322)." -ForegroundColor Green } catch {}
                } else {
                    try { Remove-ItemProperty -Path $regPath -Name "PerfLevelSrc" -ErrorAction SilentlyContinue; Write-Host "  [OK] PerfLevelSrc clock override removed." -ForegroundColor Green } catch {}
                }
                try { Remove-ItemProperty -Path $regPath -Name "DisableDynamicPstate" -ErrorAction SilentlyContinue; Write-Host "  [OK] Dynamic PState switching enabled." -ForegroundColor Green } catch {}
                if ($Mode -eq 'Default') {
                    foreach ($pmKey in @("PowerMizerEnable", "PowerMizerLevel", "PowerMizerLevelAC")) {
                        try { Remove-ItemProperty -Path $regPath -Name $pmKey -ErrorAction SilentlyContinue } catch {}
                    }
                    Write-Host "  [OK] Legacy/Desktop PowerMizer overrides cleared." -ForegroundColor Green
                } else {
                    try {
                        Set-ItemProperty -Path $regPath -Name "PowerMizerEnable" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $regPath -Name "PowerMizerLevel" -Value 3 -Type DWord -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $regPath -Name "PowerMizerLevelAC" -Value 3 -Type DWord -ErrorAction SilentlyContinue
                    } catch {}
                }
            }
        } else {
            Write-Host "  [!] Driver registry key not accessible; applying OS PCIe power settings." -ForegroundColor Yellow
        }
    } elseif ($vendor -eq "AMD") {
        if ($hasReg) {
            if ($Mode -eq 'Performance') {
                try { Set-ItemProperty -Path $regPath -Name "EnableUlps" -Value 0 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD ULPS disabled (Ultra Low Power State OFF - prevents stutters)." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "EnableUlps_NA" -Value 0 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD secondary ULPS flag disabled." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "KMD_DeLag" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD driver low-latency queue (Anti-Lag) enabled." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "PP_MCLKStutterModeHack" -Value 0 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD PowerPlay memory clock responsiveness enabled." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "PP_ThermalAutoThrottlingEnable" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD PowerPlay thermal safeguard confirmed active." -ForegroundColor Green } catch {}
            } else {
                try { Set-ItemProperty -Path $regPath -Name "EnableUlps" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD ULPS enabled (deep idle sleep allowed)." -ForegroundColor Green } catch {}
                try { Set-ItemProperty -Path $regPath -Name "EnableUlps_NA" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD secondary ULPS flag enabled." -ForegroundColor Green } catch {}
                try { Remove-ItemProperty -Path $regPath -Name "KMD_DeLag" -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD driver low-latency overrides cleared." -ForegroundColor Green } catch {}
                if ($Mode -eq 'Default') {
                    try { Remove-ItemProperty -Path $regPath -Name "PP_MCLKStutterModeHack" -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD PowerPlay memory clock overrides removed." -ForegroundColor Green } catch {}
                }
                try { Set-ItemProperty -Path $regPath -Name "PP_ThermalAutoThrottlingEnable" -Value 1 -Type DWord -ErrorAction SilentlyContinue; Write-Host "  [OK] AMD thermal safeguard confirmed active." -ForegroundColor Green } catch {}
            }
        } else {
            Write-Host "  [!] Driver registry key not accessible; applying OS PCIe power settings." -ForegroundColor Yellow
        }
    } elseif ($vendor -eq "Intel") {
        $intelIdx = if ($Mode -eq 'Performance') { 2 } elseif ($Mode -eq 'EnergySaving') { 0 } else { 1 }
        $label    = if ($Mode -eq 'Performance') { "Maximum Performance" } elseif ($Mode -eq 'EnergySaving') { "Maximum Battery Life" } else { "Balanced (Default)" }
        try {
            powercfg /setacvalueindex SCHEME_CURRENT $GUID_SUB_GRAPHICS $GUID_INTEL_PWR $intelIdx 2>$null
            powercfg /setdcvalueindex SCHEME_CURRENT $GUID_SUB_GRAPHICS $GUID_INTEL_PWR $(if ($Mode -eq 'Performance') { 1 } else { $intelIdx }) 2>$null
            powercfg /setactive SCHEME_CURRENT 2>$null
            Write-Host "  [OK] Intel Graphics Power Plan set to $label." -ForegroundColor Green
        } catch {
            Write-Host "  [!] Intel Graphics Power Plan handled by driver." -ForegroundColor Yellow
        }
    }

    # Universal PCIe Link State Power Management (ASPM) for Discrete PCIe GPUs
    if ($activeGpu.IsDiscrete) {
        if ($Mode -eq 'Performance') {
            if (Set-PcieAspmMode -AcIndex 0 -DcIndex 1) {
                Write-Host "  [OK] PCIe Link State Power Management (ASPM) set to Off on AC (Max Bandwidth)." -ForegroundColor Green
            }
        } elseif ($Mode -eq 'EnergySaving') {
            if (Set-PcieAspmMode -AcIndex 2 -DcIndex 2) {
                Write-Host "  [OK] PCIe Link State Power Management (ASPM) set to Maximum Power Savings." -ForegroundColor Green
            }
        } else {
            if (Set-PcieAspmMode -AcIndex 1 -DcIndex 2) {
                Write-Host "  [OK] PCIe Link State Power Management (ASPM) restored to Balanced/Default." -ForegroundColor Green
            }
        }
    }
}

# ---- Failsafe (Vendor-Aware) ----
function Invoke-Failsafe {
    param([string]$Reason)
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  !!! GPU FAILSAFE ACTIVATED !!!              " -ForegroundColor Red
    Write-Host "  Reason: $Reason"                             -ForegroundColor Red
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Restoring GPU safe defaults for $vendor..." -ForegroundColor Yellow

    Apply-GpuVendorPowerProfile -Mode 'Default'

    # Re-enable GPU device if it was disabled
    try {
        $status = Get-GpuDeviceStatus
        if ($status -ne "OK" -and $status -ne "NotFound") {
            if (Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Enable') {
                Write-Host "  [OK] GPU device re-enabled." -ForegroundColor Green
            }
        }
    } catch {}

    Write-Host "  Failsafe complete. Restart may be needed for registry changes." -ForegroundColor Yellow
}

function Check-OverheatFailsafe {
    $stats = Get-GpuLiveStats
    if ($null -ne $stats) {
        try {
            $temp = [int]$stats.Temperature
            if ($temp -ge $FAILSAFE_TEMP_LIMIT) {
                Invoke-Failsafe -Reason "GPU Core temperature critical ($temp C >= $FAILSAFE_TEMP_LIMIT C)"
                return $true
            }
            if ($null -ne $stats.HotSpot -and [int]$stats.HotSpot -ge $FAILSAFE_HOTSPOT_LIMIT) {
                Invoke-Failsafe -Reason "GPU Hot Spot junction temperature critical ($($stats.HotSpot) C >= $FAILSAFE_HOTSPOT_LIMIT C)"
                return $true
            }
        } catch {}
    }
    return $false
}

# ---- GPU Hardware Device On / Off ----
function Turn-GpuOn {
    $activeGpu = $global:GpuInfo
    $status    = Get-GpuDeviceStatus
    Write-Host ""
    if ($status -eq "NotFound") { Write-Host "  [X] GPU device not found!" -ForegroundColor Red; return }
    if ($status -eq "OK") { Write-Host "  [!] GPU ($($activeGpu.FriendlyName)) is already ON." -ForegroundColor Yellow; return }

    Write-Host "  Enabling GPU ($($activeGpu.FriendlyName))..." -ForegroundColor Green
    if (-not (Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Enable')) {
        Invoke-Failsafe -Reason "Enable device failed"; return
    }

    Start-Sleep -Seconds 2
    $newStatus = Get-GpuDeviceStatus
    if ($newStatus -eq "OK") {
        $global:NvmlDevice = [IntPtr]::Zero
        Write-Host "  [VERIFIED] GPU is now ON." -ForegroundColor Green
    } else {
        Write-Host "  [!] First attempt failed. Retrying..." -ForegroundColor Yellow
        Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Disable' | Out-Null
        Start-Sleep -Seconds 1
        Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Enable' | Out-Null
        Start-Sleep -Seconds 2
        if ((Get-GpuDeviceStatus) -eq "OK") {
            $global:NvmlDevice = [IntPtr]::Zero
            Write-Host "  [VERIFIED] GPU is now ON (after retry)." -ForegroundColor Green
        } else {
            Invoke-Failsafe -Reason "Could not enable GPU"
        }
    }
}

function Turn-GpuOff {
    $activeGpu = $global:GpuInfo
    $status    = Get-GpuDeviceStatus
    Write-Host ""
    if ($status -eq "NotFound") { Write-Host "  [X] GPU device not found!" -ForegroundColor Red; return }
    if ($status -ne "OK") { Write-Host "  [!] GPU ($($activeGpu.FriendlyName)) is already OFF." -ForegroundColor Yellow; return }

    # Single-GPU Desktop Safeguard: prevent accidental black-screen if no other display adapter is active
    $otherOk = @($global:AvailableGpus | Where-Object { $_.InstanceId -ne $activeGpu.InstanceId -and $_.Device.Status -eq "OK" })
    if ($otherOk.Count -eq 0) {
        Write-Host "  [WARNING] This is your ONLY active display adapter ($($activeGpu.FriendlyName))!" -ForegroundColor Red
        Write-Host "  Disabling it may turn off your monitor until you reboot." -ForegroundColor Yellow
        $confirm = Read-Host "  Type YES to disable anyway, or press Enter to cancel"
        if ($confirm -cne "YES") {
            Write-Host "  Cancelled safely." -ForegroundColor Green
            return
        }
    }

    Write-Host "  Disabling GPU ($($activeGpu.FriendlyName))..." -ForegroundColor Cyan
    if (-not (Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Disable')) {
        Invoke-Failsafe -Reason "Disable device failed"; return
    }

    Start-Sleep -Seconds 2
    $newStatus = Get-GpuDeviceStatus
    if ($newStatus -ne "OK") {
        Write-Host "  [VERIFIED] GPU is now OFF." -ForegroundColor Green
    } else {
        Write-Host "  [!] Retrying with pnputil..." -ForegroundColor Yellow
        try { pnputil /disable-device $activeGpu.InstanceId 2>$null | Out-Null; Start-Sleep -Seconds 2 } catch {}
        if ((Get-GpuDeviceStatus) -ne "OK") {
            Write-Host "  [VERIFIED] GPU is now OFF (after retry)." -ForegroundColor Green
        } else {
            Invoke-Failsafe -Reason "Could not disable GPU"
        }
    }
}

# ---- GPU Performance / Energy Modes (Vendor Specific) ----
function Set-PerformanceMode {
    $activeGpu = $global:GpuInfo
    Write-Host ""
    Write-Host "  Applying GPU Performance Mode for $($activeGpu.FriendlyName)..." -ForegroundColor Green

    Apply-GpuVendorPowerProfile -Mode 'Performance'

    # Enable GPU if it was off
    $gpuStatus = Get-GpuDeviceStatus
    if ($gpuStatus -ne "OK" -and $gpuStatus -ne "NotFound") {
        Write-Host "  GPU was OFF. Enabling..." -ForegroundColor Green
        Turn-GpuOn
    }

    Start-Sleep -Seconds 1
    Write-Host ""
    Write-Host "  [VERIFIED] GPU Performance Mode applied for $($activeGpu.FriendlyName)." -ForegroundColor Green
    Write-Host "  Active Power Mode: $(Get-GpuPowerMode)" -ForegroundColor Cyan
    Write-Host "  NOTE: Restart may be needed for driver registry changes to take full effect." -ForegroundColor DarkGray
}

function Set-EnergySavingMode {
    $activeGpu = $global:GpuInfo
    Write-Host ""
    Write-Host "  Applying GPU Energy-Saving Mode for $($activeGpu.FriendlyName)..." -ForegroundColor Cyan

    Apply-GpuVendorPowerProfile -Mode 'EnergySaving'

    Start-Sleep -Seconds 1
    Write-Host ""
    Write-Host "  [VERIFIED] GPU Energy-Saving Mode applied for $($activeGpu.FriendlyName)." -ForegroundColor Cyan
    Write-Host "  Active Power Mode: $(Get-GpuPowerMode)" -ForegroundColor Cyan
    Write-Host "  NOTE: Restart may be needed for driver registry changes to take full effect." -ForegroundColor DarkGray
}

# ---- Refresh / Restart GPU ----
function Refresh-Gpu {
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor
    Write-Host ""
    Write-Host "  Refreshing / Resetting $vendor GPU ($($activeGpu.FriendlyName))..." -ForegroundColor Yellow
    $status = Get-GpuDeviceStatus
    if ($status -eq "NotFound") {
        Write-Host "  [X] GPU device not found!" -ForegroundColor Red
        return
    }

    $otherOk = @($global:AvailableGpus | Where-Object { $_.InstanceId -ne $activeGpu.InstanceId -and $_.Device.Status -eq "OK" })
    if ($otherOk.Count -eq 0) {
        Write-Host "  [NOTE] Screen may blink briefly while cycling your primary display driver." -ForegroundColor DarkGray
    }

    try {
        Write-Host "  Step 1: Power-cycling GPU Device via PnP..." -ForegroundColor DarkGray
        Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Disable' | Out-Null
        Start-Sleep -Seconds 1
        Set-GpuPnpState -InstanceId $activeGpu.InstanceId -Action 'Enable' | Out-Null
        Start-Sleep -Seconds 2
        $global:NvmlDevice = [IntPtr]::Zero

        Write-Host "  Step 2: Restarting display driver background services..." -ForegroundColor DarkGray
        if ($vendor -eq "NVIDIA") {
            Get-Service -Name "NVDisplay.ContainerLocalSystem" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] NVIDIA Display Container Service restarted." -ForegroundColor Green
        } elseif ($vendor -eq "AMD") {
            Get-Service -Name "AMD External Events Utility" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Get-Service -Name "amdfendrsr" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Get-Service -Name "AUEPLauncher" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] AMD Display Events & Crash Defender Services restarted." -ForegroundColor Green
        } elseif ($vendor -eq "Intel") {
            Get-Service -Name "cphs" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Get-Service -Name "igfxCUIService2.0.0.0" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue
            Write-Host "  [OK] Intel Graphics Management Service restarted." -ForegroundColor Green
        }

        $newStatus = Get-GpuDeviceStatus
        if ($newStatus -eq "OK") {
            Write-Host "  [VERIFIED] GPU refreshed successfully and responsive." -ForegroundColor Green
        } else {
            Write-Host "  [!] GPU status after refresh: $newStatus" -ForegroundColor Yellow
        }
    } catch {
        Invoke-Failsafe -Reason "GPU refresh encountered error: $_"
    }
}

# ---- Switch Active GPU (Multi-GPU Systems) ----
function Select-ActiveGpu {
    Write-Host ""
    Write-Host "  === Select Active GPU to Manage ===" -ForegroundColor Yellow
    if ($global:AvailableGpus.Count -le 1) {
        Write-Host "  Only 1 GPU detected on this system ($($global:GpuInfo.FriendlyName))." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    for ($i = 0; $i -lt $global:AvailableGpus.Count; $i++) {
        $g = $global:AvailableGpus[$i]
        $tag = if ($i -eq $global:ActiveGpuIndex) { " [ACTIVE]" } else { "" }
        $typeTag = if ($g.IsDiscrete) { "Discrete" } else { "Integrated" }
        Write-Host "  $($i + 1)) $($g.FriendlyName) ($($g.Vendor) - $typeTag)$tag" -ForegroundColor $(if ($i -eq $global:ActiveGpuIndex) { "Green" } else { "White" })
    }
    Write-Host "  B) Back to Main Menu" -ForegroundColor White
    Write-Host ""
    $pick = Read-Host "  Select GPU number (1-$($global:AvailableGpus.Count))"
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $global:AvailableGpus.Count) {
        $global:ActiveGpuIndex = [int]$pick - 1
        $global:GpuInfo = $global:AvailableGpus[$global:ActiveGpuIndex]
        if ($global:GpuInfo.Vendor -eq "NVIDIA" -and $global:NvmlAvailable) {
            $global:NvmlDevice = Get-NvmlDeviceForActiveGpu
        }
        $global:LastFanPollTime = [DateTime]::MinValue
        $global:CachedFanResult = $null
        Write-Host "  [OK] Switched active GPU to $($global:GpuInfo.FriendlyName)." -ForegroundColor Green
        Start-Sleep -Seconds 1
    }
}

# ---- Reset GPU Defaults ----
function Reset-GpuDefaults {
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor

    Write-Host ""
    Write-Host "  Resetting $vendor GPU settings to factory driver defaults..." -ForegroundColor Yellow

    Apply-GpuVendorPowerProfile -Mode 'Default'

    # Ensure device is enabled
    $status = Get-GpuDeviceStatus
    if ($status -ne "OK" -and $status -ne "NotFound") {
        Write-Host "  Re-enabling GPU device..." -ForegroundColor Green
        Turn-GpuOn
    }

    Start-Sleep -Seconds 1
    Write-Host ""
    Write-Host "  [VERIFIED] GPU settings restored to factory defaults for $($activeGpu.FriendlyName)." -ForegroundColor Green
    Write-Host "  Active Power Mode: $(Get-GpuPowerMode)" -ForegroundColor Cyan
    Write-Host "  NOTE: Restart may be needed for driver registry changes to take full effect." -ForegroundColor DarkGray
}

# ---- In-Place Flicker-Free Console Updating ----
function Write-LineInPlace {
    param([int]$LineY, [string]$Text, [ConsoleColor]$Color = [ConsoleColor]::White)
    try {
        $pos = $Host.UI.RawUI.CursorPosition
        $pos.X = 0
        $pos.Y = $LineY
        $Host.UI.RawUI.CursorPosition = $pos
        $padded = $Text.PadRight(95)
        Write-Host $padded -ForegroundColor $Color -NoNewline
    } catch {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Update-TelemetryInPlace {
    $startY    = $global:TelemetryStartY
    $activeGpu = $global:GpuInfo
    $vendor    = $activeGpu.Vendor
    $typeDesc  = if ($activeGpu.IsDiscrete) { "Discrete" } else { "Integrated" }
    $formDesc  = if ($global:IsLaptop) { "Laptop" } else { "Desktop/PC" }

    # Line 0: Model Name & Type
    $modelLine = "  Model       : $($activeGpu.FriendlyName) [$typeDesc / $formDesc]"
    Write-LineInPlace -LineY ($startY + 0) -Text $modelLine -Color White

    # Line 1: Vendor & Generation Architecture
    $genLine = "  Architecture: $($activeGpu.Vendor) - $($activeGpu.Generation) (Reg: $($activeGpu.RegIndex))"
    Write-LineInPlace -LineY ($startY + 1) -Text $genLine -Color DarkGray

    # Line 2: GPU Device State
    $devStatus   = Get-GpuDeviceStatus
    $statusColor = if ($devStatus -eq "OK") { "Green" } else { "Red" }
    $statusText  = if ($devStatus -eq "OK") { "ON (enabled)" } else { "OFF (disabled)" }
    Write-LineInPlace -LineY ($startY + 2) -Text "  GPU Device  : $statusText" -Color $statusColor

    # Live stats if GPU is ON
    if ($devStatus -eq "OK") {
        $s = Get-GpuLiveStats
        if ($null -ne $s) {
            $temp = 0
            try { if ($s.Temperature -ne "N/A") { $temp = [int]$s.Temperature } } catch {}
            $tempColor = if ($temp -ge 85) { "Red" } elseif ($temp -ge 70) { "Yellow" } else { "Green" }
            $barLen    = [Math]::Min([int]($temp / 2), 50)
            $tempBar   = ("#" * $barLen).PadRight(50, '-')

            $noteText = if ($s.TempNote) { " ($($s.TempNote))" } elseif ($null -ne $s.HotSpot) { " (Hotspot: $($s.HotSpot)C)" } else { "" }
            $tempLine = if ($temp -gt 0) { "  Temperature : $($s.Temperature)C [$tempBar]$noteText" } else { "  Temperature : Not Exposed (Driver/OS Managed)" }
            if ($temp -eq 0) { $tempColor = "DarkGray" }
            Write-LineInPlace -LineY ($startY + 3) -Text $tempLine -Color $tempColor

            $pDraw  = if ($s.PowerDraw  -match 'N/A') { "Auto" } elseif ("$($s.PowerDraw)" -match '^\d+(\.\d+)?$') { "$($s.PowerDraw)W" } else { "$($s.PowerDraw)" }
            $pLimit = if ($s.PowerLimit -match 'N/A') { "Dynamic" } elseif ("$($s.PowerLimit)" -match '^\d+(\.\d+)?$') { "$($s.PowerLimit)W" } else { "$($s.PowerLimit)" }
            $fan    = if ("$($s.FanSpeed)" -match 'RPM|%|Silent|Auto|Dynamic|Shared|Managed') { "$($s.FanSpeed)" } elseif ("$($s.FanSpeed)" -match '^\d+$') { "$($s.FanSpeed)%" } else { "Auto (Managed)" }
            Write-LineInPlace -LineY ($startY + 4) -Text "  Power / Fan : Power: $pDraw / $pLimit  |  Fan: $fan" -Color White

            $coreClk = if ($s.CoreClock -match 'N/A') { "Driver Managed" } else { "$($s.CoreClock) MHz" }
            $memClk  = if ($s.MemClock  -match 'N/A') { "Auto" } else { "$($s.MemClock) MHz" }
            Write-LineInPlace -LineY ($startY + 5) -Text "  Clock Speeds: Core: $coreClk  |  VRAM: $memClk" -Color White

            Write-LineInPlace -LineY ($startY + 6) -Text "  Utilization : GPU: $($s.GpuUtil)%  |  VRAM Util: $($s.MemUtil)%" -Color White

            $vUsed  = if ($s.MemUsed  -match 'N/A') { "N/A" } else { "$($s.MemUsed) MB" }
            $vTotal = if ($s.MemTotal -match 'N/A|Dynamic') { "$($s.MemTotal)" } else { "$($s.MemTotal) MB" }
            Write-LineInPlace -LineY ($startY + 7) -Text "  VRAM Usage  : $vUsed / $vTotal ($($s.Source))" -Color White
        } else {
            Write-LineInPlace -LineY ($startY + 3) -Text "  (GPU telemetry initializing...)" -Color DarkGray
            for ($j = 4; $j -le 7; $j++) {
                Write-LineInPlace -LineY ($startY + $j) -Text "" -Color White
            }
        }
    } else {
        Write-LineInPlace -LineY ($startY + 3) -Text "  GPU is currently disabled / sleeping." -Color DarkGray
        for ($j = 4; $j -le 7; $j++) {
            Write-LineInPlace -LineY ($startY + $j) -Text "" -Color White
        }
    }

    # Line 8: GPU Mode
    $gpuMode   = Get-GpuPowerMode
    $modeColor = if ($gpuMode -match "Max Performance") { "Green" } else { "Cyan" }
    Write-LineInPlace -LineY ($startY + 8) -Text "  GPU Mode    : $gpuMode" -Color $modeColor

    # Line 9: System Plan
    $plan = Get-ActivePowerPlan
    Write-LineInPlace -LineY ($startY + 9) -Text "  System Plan : $plan ($($global:SystemVendor))" -Color DarkGray

    # Line 10: Multi-GPU notification (if more than 1 GPU)
    if ($global:AvailableGpus.Count -gt 1) {
        $gpuInfoLine = "  Hardware    : GPU $($global:ActiveGpuIndex + 1) of $($global:AvailableGpus.Count) selected. Press 6 to switch active GPU."
        Write-LineInPlace -LineY ($startY + 10) -Text $gpuInfoLine -Color Yellow
    } else {
        Write-LineInPlace -LineY ($startY + 10) -Text "" -Color White
    }

    # Line 11: Blank separator
    Write-LineInPlace -LineY ($startY + 11) -Text "" -Color White

    try {
        $promptPos = $Host.UI.RawUI.CursorPosition
        $promptPos.X = 26
        $promptPos.Y = $global:PromptLineY
        $Host.UI.RawUI.CursorPosition = $promptPos
    } catch {}
}

function Draw-InitialScreen {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host "             GPU MODE / TEMP MANAGER                      " -ForegroundColor Magenta
    Write-Host "  NVIDIA / AMD / Intel | Laptops & Desktops | Old & New   " -ForegroundColor DarkMagenta
    Write-Host "==========================================================" -ForegroundColor Magenta
    Write-Host ""

    $global:TelemetryStartY = $Host.UI.RawUI.CursorPosition.Y

    # Reserve 12 blank lines for in-place telemetry
    for ($i = 0; $i -lt 12; $i++) {
        Write-Host ""
    }

    # Static actions menu (Drawn once! Never wiped or flickered!)
    Write-Host "  ---- Actions ----" -ForegroundColor DarkGray
    Write-Host "  1) Turn GPU ON" -ForegroundColor White
    Write-Host "  2) Turn GPU OFF" -ForegroundColor White
    Write-Host "  3) GPU Performance Mode    (Max clocks / Anti-stutter / No sleep)" -ForegroundColor White
    Write-Host "  4) GPU Energy-Saving Mode  (Adaptive / Cool & Quiet / ULPS sleep)" -ForegroundColor White
    Write-Host "  5) Refresh / Restart GPU   (Driver & device reset)" -ForegroundColor White
    Write-Host "  6) Switch Active GPU       (Toggle between available GPUs)" -ForegroundColor White
    Write-Host "  7) Reset GPU Defaults      (Restore factory driver defaults)" -ForegroundColor White
    Write-Host "  0) Exit" -ForegroundColor White
    Write-Host ""
    Write-Host "  Status refreshes in-place every 0.1s (exact real-time). Commands are always visible." -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
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
        if ($tick % 10 -eq 0) {
            $oh = Check-OverheatFailsafe
            if ($oh) { Read-Host "  Press Enter to continue" }
        }
        Update-TelemetryInPlace
    }
}

# ---- Main Execution ----
Invoke-AdminCheck
Init-Nvml | Out-Null
Init-GpuHardwareMonitor | Out-Null

trap {
    Invoke-Failsafe -Reason "Unhandled error: $_"
    Read-Host "  Press Enter to continue"
    continue
}

while ($true) {
    $opt = Show-LiveMenu
    switch ($opt) {
        '1' { Turn-GpuOn }
        '2' { Turn-GpuOff }
        '3' { Set-PerformanceMode }
        '4' { Set-EnergySavingMode }
        '5' { Refresh-Gpu }
        '6' { Select-ActiveGpu }
        '7' { Reset-GpuDefaults }
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
