# ============================================================
#  mlc_benchmark.ps1  -  AIDA64-style Cache & Memory Benchmark
#  Uses Intel MLC v3.12  https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
#  Requires: PowerShell 5.1+, Windows 10/11 or Windows Server
#  Run as Administrator for full MLC access (MSR prefetcher control)
# ============================================================

$MLC_URL  = "https://downloadmirror.intel.com/866182/mlc_v3.12.tgz"
$WORKDIR  = Join-Path $env:TEMP "mlc_bench_$PID"
$MLC_BIN  = ""
$START_TIME = Get-Date

# -- ANSI colours (Windows 10 1511+ / WT) --------------------
$ESC   = [char]27
$BOLD  = "$ESC[1m"
$CYAN  = "$ESC[1;36m"
$GREEN = "$ESC[1;32m"
$YELLOW= "$ESC[1;33m"
$RESET = "$ESC[0m"

# Enable VT processing on older consoles
try {
    $h = (Get-Process -Id $PID).MainWindowHandle
    if ($h) {
        Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class Con{[DllImport("kernel32")]public static extern bool SetConsoleMode(IntPtr h,uint m);
[DllImport("kernel32")]public static extern bool GetConsoleMode(IntPtr h,out uint m);}
'@
        $hOut = [Console]::OutputEncoding; $dummy = $hOut  # suppress unused warning
        $stdout = (New-Object Microsoft.Win32.SafeHandles.SafeFileHandle([IntPtr]::new(-11), $false))
        $handle = [Microsoft.Win32.SafeHandles.SafeFileHandle]
    }
} catch {}

# -- helpers --------------------------------------------------
function Die([string]$msg) { Write-Host "`n${ESC}[1;31mERROR:${RESET} $msg" -ForegroundColor Red; exit 1 }
function Hdr([string]$msg) { Write-Host "`n${CYAN}━━━  $msg  ━━━${RESET}" }
function Row([string]$label, [string]$val) { Write-Host ("  {0,-30} {1}" -f $label, $val) }

function Fmt-BW([string]$bw) {
    if ($bw -match '^(\d+)\s*MB/s$') {
        $n = [double]$Matches[1]
        if ($n -ge 100000) { return ("{0:F1} GB/s" -f ($n / 1000)) }
    }
    return $bw
}

function Check-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "${YELLOW}Warning: running without Administrator. Some MLC tests may be restricted.${RESET}"
        Write-Host "         Re-run: ${BOLD}Start-Process pwsh -Verb RunAs -ArgumentList '-File `"$PSCommandPath`"'${RESET}`n"
    }
}

# -- System Information ---------------------------------------
function Show-SystemInfo {
    Hdr "System Information"

    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $bios= Get-CimInstance Win32_BIOS

    Row "Hostname"        $env:COMPUTERNAME
    Row "OS"              "$($os.Caption) (Build $($os.BuildNumber))"
    Row "Kernel"          "NT $($os.Version)"
    Row "Architecture"    $env:PROCESSOR_ARCHITECTURE

    # Virtualization / hypervisor
    $virt = "None"
    $model = $cs.Model
    if ($cs.HypervisorPresent) { $virt = "Hypervisor present" }
    elseif ($model -match "Virtual|VMware|VirtualBox|KVM|Hyper-V|QEMU|Xen") { $virt = $model }
    Row "Virtualization"  $virt

    # Uptime
    $uptime = (Get-Date) - $os.LastBootUpTime
    Row "Uptime"          ("{0}d {1}h {2}m" -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes)

    # NUMA nodes via registry
    $numaKey   = "HKLM:\SYSTEM\CurrentControlSet\Control\NUMA"
    $numaCount = if (Test-Path $numaKey) { ((Get-Item $numaKey).GetSubKeyNames() | Measure-Object).Count } else { 1 }
    Row "NUMA Nodes"      $numaCount

    # Root disk
    $disk = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($disk) {
        $total = [math]::Round(($disk.Used + $disk.Free) / 1GB, 0)
        $used  = [math]::Round($disk.Used / 1GB, 0)
        $free  = [math]::Round($disk.Free / 1GB, 0)
        Row "Root Disk (C:)"  "${total}G total, ${used}G used, ${free}G free"
    }

    # Power plan
    $plan = powercfg /getactivescheme 2>$null
    if ($plan -match "\((.+)\)") { Row "Power Plan" $Matches[1] }
}

# -- CPU Information ------------------------------------------
function Show-CpuInfo {
    Hdr "CPU Information"

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $allCpu = @(Get-CimInstance Win32_Processor)

    Row "CPU Model"        $cpu.Name.Trim()
    Row "Physical Cores"   ($allCpu | Measure-Object NumberOfCores -Sum).Sum
    Row "Logical CPUs"     ($allCpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    Row "Max Frequency"    "$($cpu.MaxClockSpeed) MHz"
    # Win32_Processor.Model is often blank; use ProcessorId for stepping info
    $stepping  = if ($cpu.Stepping)  { $cpu.Stepping }  else { "?" }
    $cpuModel  = if ($cpu.Revision)  { "0x{0:X4}" -f $cpu.Revision } else { "?" }
    Row "CPU Family / Model / Stepping" "$($cpu.Family) / $cpuModel / $stepping"

    # Cache sizes - aggregate per level to avoid duplicate entries
    $caches = Get-CimInstance Win32_CacheMemory -ErrorAction SilentlyContinue
    $cacheByLevel = @{}
    foreach ($c in $caches) {
        $level = switch ($c.Level) { 3{"L1"} 4{"L2"} 5{"L3"} default{"L$($c.Level)"} }
        if (-not $cacheByLevel.ContainsKey($level)) { $cacheByLevel[$level] = 0 }
        $cacheByLevel[$level] += $c.InstalledSize
    }
    foreach ($level in ($cacheByLevel.Keys | Sort-Object)) {
        $sizeKB = $cacheByLevel[$level]
        $display = if ($sizeKB -ge 1024) { "{0} MiB" -f [math]::Round($sizeKB/1024, 0) } else { "${sizeKB} KB" }
        Row "${level} Cache" $display
    }
}

# -- Memory Information ---------------------------------------
function Show-MemoryInfo {
    Hdr "Memory Information"

    $os  = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    Row "Memory Total" "${totalGB} GiB"

    $dimms = @(Get-CimInstance Win32_PhysicalMemory)
    if ($dimms.Count -eq 0) {
        Row "DIMMs" "N/A (VM or no WMI access)"
        return
    }

    $populated = $dimms | Where-Object { $_.Capacity -gt 0 }
    $first = $populated | Select-Object -First 1

    $memType = switch ($first.SMBIOSMemoryType) {
        20 {"DDR"} 21 {"DDR2"} 22 {"DDR2 FB-DIMM"} 24 {"DDR3"} 26 {"DDR4"} 34 {"DDR5"} default {"Unknown ($($first.SMBIOSMemoryType))"}
    }
    Row "Memory Type"       $memType
    Row "Configured Speed"  "$($first.ConfiguredClockSpeed) MT/s"
    Row "Rated Speed"       "$($first.Speed) MT/s"

    $dimmCount = $populated.Count
    $dimmSizeGB = [math]::Round($first.Capacity / 1GB, 0)
    $totalSlots = $dimms.Count
    Row "DIMMs Installed"   "${dimmCount} x ${dimmSizeGB} GB (${totalSlots} slots total)"
    Row "Manufacturer"      ($first.Manufacturer -replace '\s+$', '')
    Row "Part Number"       ($first.PartNumber   -replace '\s+$', '')

    $ecc = switch ($first.MemoryType) { 11{"ECC"} 12{"ECC"} default{"None"} }
    $csType = (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1).MemoryErrorCorrection
    $eccLabel = switch ($csType) { 3{"None"} 4{"Parity"} 5{"Single-bit ECC"} 6{"Multi-bit ECC"} 7{"CRC"} default{"Unknown"} }
    Row "ECC"               $eccLabel

    # DIMM topology table
    Write-Host ""
    Write-Host ("  {0,-12} {1,-10} {2,-20} {3}" -f "Locator","Size","Bank","Manufacturer")
    Write-Host ("  " + ("-" * 60))
    foreach ($d in $populated) {
        $sz = "{0} GB" -f [math]::Round($d.Capacity / 1GB, 0)
        Write-Host ("  {0,-12} {1,-10} {2,-20} {3}" -f $d.DeviceLocator, $sz, $d.BankLabel, ($d.Manufacturer -replace '\s+$',''))
    }
}

# -- Download MLC ---------------------------------------------
function Setup-MLC {
    Hdr "Setting Up Intel MLC"
    New-Item -ItemType Directory -Path $WORKDIR -Force | Out-Null

    $tgz = Join-Path $WORKDIR "mlc.tgz"
    if (-not (Test-Path $tgz)) {
        Write-Host "  Downloading MLC from Intel..."
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
            $wc.DownloadFile($MLC_URL, $tgz)
        } catch {
            Die "Failed to download MLC: $_`n         Hint: download mlc_v3.12.tgz manually from Intel and place mlc.exe in: $WORKDIR"
        }
    }

    # Extract .tgz using tar (built-in on Windows 10 1803+)
    $tarExe = "$env:SystemRoot\System32\tar.exe"
    if (-not (Test-Path $tarExe)) { Die "tar.exe not found. Windows 10 1803+ required." }
    & $tarExe -xzf $tgz -C $WORKDIR 2>$null
    if ($LASTEXITCODE -ne 0) { Die "Failed to extract MLC archive." }

    $script:MLC_BIN = Get-ChildItem -Path $WORKDIR -Recurse -Filter "mlc.exe" | Select-Object -First 1 -ExpandProperty FullName
    if (-not $MLC_BIN) { Die "mlc.exe not found after extraction." }
    Write-Host "  MLC ready: $MLC_BIN"
}

# -- Bandwidth Tests ------------------------------------------
function Run-Bandwidth {
    Hdr "Memory & Cache Bandwidth"
    Write-Host ("  $BOLD{0,-32} {1,12} {2,12} {3,12}$RESET" -f "Level","Read","Write","Copy")
    Write-Host ("  " + ("-" * 70))

    # Full DRAM bandwidth (capture stderr too - MLC writes some output to stderr on Windows)
    $bw_out = (& $MLC_BIN --peak_injection_bandwidth 2>&1) | Out-String

    $mem_read  = if ($bw_out -match 'ALL Reads[\s:]+(\d[\d,.]*)') { "{0:F0} MB/s" -f [double]($Matches[1] -replace ',','') } else { "N/A" }
    $mem_write = if ($bw_out -match '1:1 Reads-Writes[\s:]+(\d[\d,.]*)') { "{0:F0} MB/s" -f [double]($Matches[1] -replace ',','') } else { "N/A" }
    $mem_copy  = if ($bw_out -match 'Stream-triad like[\s:]+(\d[\d,.]*)') { "{0:F0} MB/s" -f [double]($Matches[1] -replace ',','') } else { "N/A" }

    Write-Host ("  {0,-32} {1,12} {2,12} {3,12}" -f "Memory (DRAM)", (Fmt-BW $mem_read), (Fmt-BW $mem_write), (Fmt-BW $mem_copy))

    # Cache BW (read only - MLC NT writes bypass cache)
    $l3_kb = try {
        $l3 = Get-CimInstance Win32_CacheMemory | Where-Object {$_.Level -eq 5} | Select-Object -First 1
        [int]($l3.InstalledSize)
    } catch { 8192 }
    if ($l3_kb -le 0) { $l3_kb = 8192 }

    $cacheLevels = @(
        @{ Label = "L1 Cache";  Buf = "16K"  },
        @{ Label = "L2 Cache";  Buf = "512K" },
        @{ Label = "L3 Cache";  Buf = "$([int]($l3_kb/4))K" }
    )

    foreach ($lvl in $cacheLevels) {
        $cache_out = (& $MLC_BIN --peak_injection_bandwidth "-b$($lvl.Buf)" 2>&1) | Out-String
        $bw_r = if ($cache_out -match 'ALL Reads[\s:]+(\d[\d,.]*)') { "{0:F0} MB/s" -f [double]($Matches[1] -replace ',','') } else { "N/A" }
        # NT writes bypass cache - not meaningful for cache levels
        Write-Host ("  {0,-32} {1,12} {2,12} {3,12}" -f $lvl.Label, (Fmt-BW $bw_r), "N/A", "N/A")
    }
    Write-Host "    *L1/L2/L3: Only read bandwidth is meaningful (MLC uses NT stores for write/copy)."
}

# -- Latency Tests ---------------------------------------------
function Run-Latency {
    Hdr "Memory & Cache Latency"
    Write-Host ("  $BOLD{0,-32} {1,12}$RESET" -f "Level","Latency")
    Write-Host ("  " + ("-" * 46))

    function MLC-Lat([string]$bufSize) {
        $out = (& $MLC_BIN --idle_latency "-b$bufSize" 2>&1) | Out-String
        # Single-socket: "Each iteration took X clocks ( Y     ns)"
        if ($out -match '\(\s*([\d.]+)\s+ns\)') {
            return "{0:F1} ns" -f [double]$Matches[1]
        }
        # Multi-socket NUMA matrix: first data row "0  <latency>"
        if ($out -match '(?m)^\s*0\s+([\d.]+)\s*$' -and [double]$Matches[1] -gt 0) {
            return "{0:F1} ns" -f [double]$Matches[1]
        }
        return "N/A"
    }

    Write-Host ("  {0,-32} {1,12}" -f "L1 Cache",      (MLC-Lat "16K"))
    Write-Host ("  {0,-32} {1,12}" -f "L2 Cache",      (MLC-Lat "512K"))
    Write-Host ("  {0,-32} {1,12}" -f "L3 Cache",      (MLC-Lat "6M"))
    Write-Host ("  {0,-32} {1,12}" -f "Memory (DRAM)", (MLC-Lat "256M"))

    Hdr "Full Idle Latency Sweep (Buffer Size → Latency)"
    foreach ($sz in @("16K","64K","256K","1M","4M","16M","64M","256M")) {
        Write-Host ("  {0,12}   {1}" -f $sz, (MLC-Lat $sz))
    }
}

# -- Cleanup ---------------------------------------------------
function Cleanup {
    if (Test-Path $WORKDIR) { Remove-Item -Recurse -Force $WORKDIR -ErrorAction SilentlyContinue }
}

# -- Main ------------------------------------------------------
Write-Host "${GREEN}${BOLD}"
Write-Host "  ╔══════════════════════════════════════════════════╗"
Write-Host "  ║     Cache & Memory Benchmark  (Intel MLC)        ║"
Write-Host "  ║                           By @Purestreams        ║"
Write-Host "  ╚══════════════════════════════════════════════════╝"
Write-Host "$RESET"

try {
    Check-Admin
    Show-SystemInfo
    Show-CpuInfo
    Show-MemoryInfo
    Setup-MLC
    Run-Bandwidth
    Run-Latency

    Hdr "Done"
    $elapsed = [int](((Get-Date) - $START_TIME).TotalSeconds)
    Write-Host ("  Elapsed time: {0}m {1:D2}s" -f [int]($elapsed/60), ($elapsed%60))
    Write-Host "  ${GREEN}Benchmark complete.${RESET}"
} finally {
    Cleanup
}

