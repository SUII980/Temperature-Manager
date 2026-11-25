# CPU & GPU Mode / Temp Manager (Universal Windows Edition)

> **Zero-bloat, real-time `0.1s` terminal telemetry and thermal/power control for Windows Laptops & Desktops.**
> Supports **Intel & AMD CPUs** and **NVIDIA, AMD & Intel GPUs** (both modern and legacy hardware) — without installing heavy OEM suites or background services.

---

## Why Use This Tool?

Gaming laptops and performance PCs often run hot during idle background tasks, lock useful CPU Turbo / EPP settings behind hidden Windows power menus, or force you to keep heavy OEM bloatware running in the background just to check temperatures, TGP wattage, or fan speeds.

**CPU & GPU Mode / Temp Manager** gives you two portable, lightweight PowerShell dashboards with one-click administrator launchers:

- **Instant `0.1s` Live Dashboard** — Clocks, utilization, temperatures, board power, VRAM, and fan speeds update in-place cleanly with zero screen flicker.
- **Zero Background Services** — Nothing installs to Windows or runs after you close the window (`0%` overhead when closed).
- **Universal Compatibility** — Automatically detects CPU generation, OS capabilities, NVIDIA/AMD/Intel GPUs, and Laptop vs. Desktop form factors, gracefully adapting controls and telemetry sensors to your machine.
- **Built-in Thermal Protection** — Intelligent game-aware CPU Auto-Cool Guard and hardware thermal failsafes keep temperatures safe without crippling your gaming FPS.

---

## Live Preview Example

```text
==========================================================
             GPU MODE / TEMP MANAGER
  NVIDIA / AMD / Intel | Laptops & Desktops | Old & New
==========================================================

  Model       : NVIDIA GeForce RTX 4050 Laptop GPU [Discrete / Laptop]
  Architecture: NVIDIA - Ada Lovelace (RTX 40-Series) (Reg: 0001)
  GPU Device  : ON (enabled)
  Temperature : 50C [#########################-------------------------] (Hotspot: 57C)
  Power / Fan : Power: 14.3W / 140W  |  Fan: 0 RPM (0dB Silent)
  Clock Speeds: Core: 2055 MHz  |  VRAM: 8101 MHz
  Utilization : GPU: 0%  |  VRAM Util: 0%
  VRAM Usage  : 221 MB / 6141 MB (NVML (Driver Direct P/Invoke))
  GPU Mode    : Adaptive (Sleep Allowed)
  System Plan : Turbo (ASUSTeK COMPUTER INC.)
```

---

## Included Files

| File | Purpose |
| :--- | :--- |
| `cpu_mode_temp_manager.bat` | One-click Administrator launcher for the CPU tool. |
| `cpu_mode_temp_manager.ps1` | **CPU Mode / Temp Manager** PowerShell dashboard & Auto-Cool Guard. |
| `gpu_mode_temp_manager.bat` | One-click Administrator launcher for the GPU tool. |
| `gpu_mode_temp_manager.ps1` | **GPU Mode / Temp Manager** PowerShell dashboard & multi-vendor controller. |
| `LibreHardwareMonitorLib.dll` / `HidSharp.dll` | In-memory hardware sensor libraries for MSR CPU temps, GPU HotSpot/AMD/Intel sensors, and desktop SuperIO fans. |
| `LICENSE` | MIT License. |

*(Note: `/` is invalid in Windows filenames, so the executable scripts use `cpu_mode_temp_manager` and `gpu_mode_temp_manager`.)*

---

## Quick Start & How to Use

### Requirements
- **OS**: Windows 10 (1809+) or Windows 11 (x64)
- **Permissions**: Administrator (both `.bat` launchers request UAC elevation automatically)

### Installation
1. Click **Code -> Download ZIP** (or clone this repository) and extract all files into one folder (keep the `.dll` files alongside the `.bat` and `.ps1` scripts).
2. Double-click either launcher:
   - **`cpu_mode_temp_manager.bat`** to manage CPU thermals, Turbo Boost, and voltage/EPP.
   - **`gpu_mode_temp_manager.bat`** to manage GPU power modes, clocks, VRAM, TGP power draw, and fan telemetry.
3. Click **Yes** on the Windows Administrator prompt.
4. Watch telemetry update in real time every **0.1 seconds**. Press **`1`–`7`** at any moment to apply a mode or configure settings, **`0`** to exit, or use **`7`** (`Reset`) at any time to revert to standard defaults.

---

## CPU Mode / Temp Manager (`cpu_mode_temp_manager`)

### Compatibility
- **Intel**: 2nd Gen (Sandy Bridge) through the latest Core / Core Ultra series
- **AMD**: Ryzen, Athlon, Threadripper, and EPYC
- **Smart Probing**: Automatically checks Windows build, Boost Mode range (`0`–`6`), Speed Shift / CPPC EPP support, and Efficient Boost availability at startup. Older CPUs without EPP cleanly fall back to Max Processor State control.

### Capabilities & Features
- **Sub-Millisecond Telemetry**: Uses `.NET PerformanceCounter` for live MHz/percentage clock speeds and CPU load alongside **LibreHardwareMonitor MSR** (`CPU Package`, `Core Max`, `Core Average`, `Core #`), with fallbacks to ACPI thermal zones (`MSAcpi_ThermalZoneTemperature`), WMI thermal counters, and NVIDIA heatsink proxy.
- **Power & Boost Modes**:
  1. **Cool & Quiet Mode**: Disables Turbo Boost (`0`), sets EPP `80` (low voltage), caps Max Processor State to `95%`, and sets Active cooling (~15–25°C drop for light work or quiet cooling).
  2. **Optimized Gaming Mode**: Applies smart `Efficient Aggressive` (`4`) or `Efficient Enabled` (`3`) boost with balanced EPP `50` and `100%` Max State.
  3. **Max Performance Mode**: Sets Aggressive Boost (`2`), EPP `0`, and `100%` Min/Max Processor State for maximum throughput.
  4. **Quick Toggle Turbo**: Instant one-key ON/OFF switch for Turbo Boost.
  5. **Custom Power Settings**: Independently tune **Speed Shift EPP (`0–100`)**, **Max Processor State (`50–100%`)**, and **Turbo Boost Mode (`0–6`)**.
- **Intelligent Auto-Cool Guard (Option 6)**:
  - Runs a 1-second thermal check (default threshold **`> 75°C`**, configurable between `55°C–95°C`).
  - **Game & Workload Aware**: Detects active games, launchers, 3D engines/renderers, video editors, compilers, VMs, and high CPU/GPU usage (`>= 30%` GPU load). When a game or heavy app is active, Auto-Cool **holds back** to protect your FPS; when temps spike with no heavy app running, it automatically reduces boost, EPP (`80`), and Max State (`90%`).
  - **Emergency Thermal Failsafe (`92°C`)**: Automatically throttles CPU power if temperature hits `92°C`.
- **Control Panel Integration**: Automatically unhides hidden Windows processor power settings (`Attributes = 2`) and includes **Reset to Defaults** (Option 7).

---

## GPU Mode / Temp Manager (`gpu_mode_temp_manager`)

### Compatibility
- **NVIDIA**: GeForce RTX 50/40/30/20, GTX 16/10/900/700/600, TITAN, and Quadro (loads `nvml.dll` from both `System32` DCH and legacy `NVSMI` paths, with multi-GPU name matching).
- **AMD**: RDNA 4/3/2/1 (RX 9000/8000/7000/6000/5000), Vega, Polaris (RX 400/500), and Legacy GCN / TeraScale (R9/R7/R5/HD).
- **Intel**: Arc (Battlemage / Alchemist), Iris Xe, UHD, and HD Graphics (Discrete & Integrated).
- **Form Factors**: Auto-detects **Laptop vs. Desktop** and resolves exact active Windows Display driver keys via `DEVPKEY_Device_Driver`.

### Capabilities & Features
- **High-Speed Multi-Engine Telemetry**:
  - **Direct NVML C# P/Invoke (`~0.1 ms`)**: Queries `nvml.dll` directly in memory for true **Total Board Power Draw (W)**, **Enforced Dynamic Boost / Management / Default TGP Limits (W)**, core/memory clocks, GPU/VRAM utilization, and dedicated VRAM—paired with LHM **HotSpot** temperature.
  - **AMD & Intel Support (LHM + WDDM D3D)**: Reads core/hotspot temps, package/board power, clocks, dedicated & shared VRAM, D3D 3D engine utilization, and **Shared CPU Die temperature** fallback on integrated GPUs.
  - **Universal Fan Speed Telemetry**: Reads Desktop NVML (`GetFanSpeed_v2` / `GetFanSpeed`), LHM GPU & Desktop Motherboard SuperIO/Controller sensors, and multi-OEM Laptop EC WMI (**ASUS** `AsusAtkWmi_WMNB`, **Lenovo** `LENOVO_GAMEZONE_DATA` / `LENOVO_FAN_METHOD`, **Dell/Alienware** `DCIM_FanSensor`, plus `Win32_Fan`), accurately reporting verified **`0 RPM (0dB Silent)`**, live RPM/`%`, `Shared (CPU/Chassis Cooling)`, or `Auto (EC Managed)` / `Auto (Driver Managed)`.
  - **Zero-DLL Fallbacks**: Automatically falls back to `nvidia-smi` and native Windows WDDM D3D Performance Counters (`GPUEngine` + `GPUAdapterMemory`).
- **GPU Modes & Controls**:
  1. **Turn GPU ON** / **2) Turn GPU OFF**: Enable or disable discrete/secondary GPUs cleanly (`Enable-PnpDevice` / `Disable-PnpDevice` with `pnputil` fallback) plus a **Single-GPU Desktop Safeguard** that asks you to type `YES` before disabling your only active display adapter.
  3. **GPU Performance Mode**: Disables NVIDIA Runtime Power Management / locks `PerfLevelSrc` + legacy `PowerMizerLevel`; disables AMD ULPS and enables `KMD_DeLag` + PowerPlay memory responsiveness; sets Intel Graphics Power Plan to Maximum Performance; sets discrete PCIe ASPM to Off on AC.
  4. **GPU Energy-Saving Mode**: Restores NVIDIA Adaptive sleep, AMD ULPS deep idle sleep, Intel Maximum Battery Life, and PCIe ASPM Maximum Power Savings.
  5. **Refresh / Restart GPU**: Power-cycles the selected GPU PnP device and restarts vendor display container services.
  6. **Switch Active GPU**: Instantly toggle management between multiple GPUs (e.g., discrete RTX/Radeon GPU and integrated Intel/AMD graphics).
  7. **Reset GPU Defaults**: Restores factory driver registry keys, clears overrides, resets PCIe ASPM, and re-enables the GPU if disabled.
- **Automated Overheat Failsafe**: Restores safe adaptive defaults automatically if GPU Core reaches `>= 90°C` or HotSpot reaches `>= 108°C`.

---

## Safety & Disclaimer

> [!WARNING]
> **USE AT YOUR OWN RISK.** This tool modifies Windows power schemes, CPU boost/voltage policy settings, PCIe ASPM, and display driver registry keys. **The creator is NOT responsible or liable for any hardware damage, overheating, system instability, crashes, data loss, voided warranties, or any other issues caused directly or indirectly by using this tool.** By downloading or running these scripts, you accept full responsibility for your system.

- All changes use standard Windows `powercfg` settings, PnP device states, and vendor display driver registry keys—no permanent BIOS modifications are made.
- Both tools include **Reset to Defaults** (Option `7`) and automatic thermal failsafes, though you should always monitor your system when testing aggressive performance profiles.
- Registry power-mode changes on some GPU drivers may require toggling the GPU or rebooting Windows to take full effect.

---

## License

Licensed under the [MIT License](LICENSE).
