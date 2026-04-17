<h1 align="center">mlc_benchmark</h1>

```
  ╔══════════════════════════════════════════════════╗
  ║                                                  ║
  ║   ███╗   ███╗██╗      ██████╗                    ║
  ║   ████╗ ████║██║     ██╔════╝                    ║
  ║   ██╔████╔██║██║     ██║                         ║
  ║   ██║╚██╔╝██║██║     ██║                         ║
  ║   ██║ ╚═╝ ██║███████╗╚██████╗                    ║
  ║   ╚═╝     ╚═╝╚══════╝ ╚═════╝  benchmark         ║
  ║                                                  ║
  ║      Cache & Memory Benchmark  (Intel MLC)       ║
  ╚══════════════════════════════════════════════════╝
```

An AIDA64-like cache and memory benchmark for **Linux and Windows**, powered by [Intel Memory Latency Checker (MLC) v3.12](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).


## Quick Run

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/Purestreams/linux-mlc-bench/master/mlc_benchmark.sh | sudo bash
```

without sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Purestreams/linux-mlc-bench/master/mlc_benchmark.sh | bash
```

### Windows (PowerShell)

Run as Administrator for full MLC access:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Invoke-WebRequest -Uri https://raw.githubusercontent.com/Purestreams/linux-mlc-bench/master/mlc_benchmark.ps1 -OutFile mlc_benchmark.ps1
.\mlc_benchmark.ps1
```

## Example

```

  ╔══════════════════════════════════════════════════╗
  ║     Cache & Memory Benchmark  (Intel MLC)        ║
  ║                           By @Purestreams        ║
  ╚══════════════════════════════════════════════════╝


━━━  System Information  ━━━
  Hostname                       epyc7551p-pve
  OS                             Debian GNU/Linux 12 (bookworm)
  Kernel                         6.8.12-15-pve
  Architecture                   x86_64
  Virtualization                 none
  Uptime                         up 5 weeks, 6 days, 21 hours, 5 minutes
  NUMA Nodes                     1
  Root Disk                      94G total, 59G used, 31G avail
  CPU Freq Governor              performance

━━━  CPU Information  ━━━
  CPU Model                      AMD EPYC 7532 32-Core Processor
  Physical Cores                 32
  Logical CPUs                   64
  Max Frequency                  2400.0 MHz
  CPU Family / Model / Stepping  23 / 49 / 0
  L2 Cache                       16 MiB (32 instances)
  L3 Cache                       256 MiB (16 instances)

━━━  Memory Information  ━━━
  Memory Total                   125.6 GiB
  Memory Type                    DDR4 (Synchronous Registered (Buffered))
  Configured Speed               2667 MT/s
  Rated Speed                    2133 MT/s
  DIMMs Installed                8 x 16 GB (8 slots total)
  Manufacturer                   Micron
  Part Number                    36ASF2G72PZ-2G1A2
  ECC                            Multi-bit ECC
  Channels In Use                8

  Locator      Size       Bank                           Manufacturer
  ────────────────────────────────────────────────────────────────────
  DIMMA1       16 GB      P0_Node0_Channel0_Dimm0        Micron
  DIMMB1       16 GB      P0_Node0_Channel1_Dimm0        Micron
  DIMMC1       16 GB      P0_Node0_Channel2_Dimm0        Micron
  DIMMD1       16 GB      P0_Node0_Channel3_Dimm0        Micron
  DIMME1       16 GB      P0_Node0_Channel4_Dimm0        Micron
  DIMMF1       16 GB      P0_Node0_Channel5_Dimm0        Micron
  DIMMG1       16 GB      P0_Node0_Channel6_Dimm0        Micron
  DIMMH1       16 GB      P0_Node0_Channel7_Dimm0        Micron

━━━  Setting Up Intel MLC  ━━━
  Downloading MLC from Intel...
  MLC ready: /tmp/mlc_bench_2470333/Linux/mlc

━━━  Memory & Cache Bandwidth  ━━━
  Level                                    Read        Write         Copy
  ──────────────────────────────────────────────────────────────────────
  Memory (DRAM)                      132.3 GB/s   124.9 GB/s   128.1 GB/s
  L1 Cache                          2795.4 GB/s   126.5 GB/s   352.7 GB/s
  L2 Cache                          1819.6 GB/s   121.3 GB/s   368.5 GB/s
  L3 Cache                           131.6 GB/s   125.3 GB/s   127.7 GB/s
    *L1/L2/L3: Only the read bandwidth is meaningful for cache levels.

━━━  Memory & Cache Latency  ━━━
  Level                                 Latency
  ──────────────────────────────────────────────
  L1 Cache                               1.2    ns
  L2 Cache                               6.6    ns
  L3 Cache                              13.4    ns
  Memory (DRAM)                        130.9    ns

━━━  Full Idle Latency Sweep (Buffer Size → Latency)  ━━━
           16K   1.2    ns
           64K   3.7    ns
          256K   4.1    ns
            1M   12.6   ns
            4M   13.3   ns
           16M   74.7   ns
           64M   129.5  ns
          256M   131.6  ns

━━━  Done  ━━━
  Elapsed time: 3m 14s
  Benchmark complete.
```

## Features

- **System Information** — OS, kernel, virtualization, uptime, disk, CPU frequency governor / power plan
- **CPU Information** — model, core/thread count, frequency, cache sizes
- **Memory Information** — type, speed, DIMM count/size, manufacturer, ECC, channel topology
- **Cache & Memory Bandwidth** — read, write, and copy throughput for DRAM, L1, L2, and L3 cache
- **Cache & Memory Latency** — idle latency for L1/L2/L3/DRAM, plus a full buffer-size sweep table
- Auto-downloads MLC at runtime (no manual install required)
- Auto-converts bandwidth ≥ 100,000 MB/s to GB/s for readability
- **Linux** (`mlc_benchmark.sh`) and **Windows** (`mlc_benchmark.ps1`) support

## Requirements

### Linux (`mlc_benchmark.sh`)

| Tool | Notes |
|------|-------|
| `bash` | v4+ |
| `curl` or `wget` | For downloading MLC |
| `awk`, `grep`, `sed` | Standard GNU coreutils |
| `lscpu` | Part of `util-linux` |
| `sudo` / root | Required for full MLC access (MSR prefetcher control) |

Optional (auto-installed if running as root on supported distros):
- `dmidecode` — memory type, speed, and DIMM topology
- `numactl` — NUMA node count
- `systemd-detect-virt` — virtualization detection (via `systemd`)

Supported package managers for auto-install: `apt`, `dnf`, `yum`, `pacman`, `zypper`, `apk`

### Windows (`mlc_benchmark.ps1`)

| Requirement | Notes |
|-------------|-------|
| Windows 10 1803+ / Windows 11 | `tar.exe` required for extraction |
| PowerShell 5.1+ | Built into Windows |
| Administrator (recommended) | Required for full MLC access |

## Usage

### Linux

```bash
# Basic run (some MLC tests may be restricted without root)
bash mlc_benchmark.sh

# Recommended: run as root for full results
sudo bash mlc_benchmark.sh
```

### Windows

```powershell
# Run directly (Administrator recommended)
.\mlc_benchmark.ps1

# Or elevate automatically
Start-Process powershell -Verb RunAs -ArgumentList "-File `"$PWD\mlc_benchmark.ps1`""
```


## Notes

- MLC is downloaded to a temporary directory (`/tmp/mlc_bench_<PID>`) and deleted automatically on exit.
- Without root, MLC cannot load the `msr` kernel module to disable hardware prefetchers, which may affect bandwidth and latency accuracy. A warning is printed in this case.
- Cache bandwidth write/copy columns show `N/A` for cache levels because MLC's `--peak_injection_bandwidth` with a restricted buffer size only reliably measures read throughput for those levels.
- The latency sweep uses `--idle_latency` with fixed buffer sizes to target each cache level: L1=16K, L2=512K, L3=6M, DRAM=256M.

## License

This script is provided as-is under the [MIT License](https://opensource.org/licenses/MIT). Intel MLC is subject to Intel's own [license terms](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).
