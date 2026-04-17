# mlc_benchmark.sh

An AIDA64-like cache and memory benchmark for Linux, powered by [Intel Memory Latency Checker (MLC) v3.12](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).


## Quick Run


```bash
curl -fsSL https://raw.githubusercontent.com/Purestreams/linux-mlc-bench/master/mlc_benchmark.sh | sudo bash
```

without sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Purestreams/linux-mlc-bench/master/mlc_benchmark.sh | bash
```

## Example

```

  ╔══════════════════════════════════════════════════╗
  ║     Cache & Memory Benchmark  (Intel MLC)        ║
  ╚══════════════════════════════════════════════════╝


━━━  System Information  ━━━
  Hostname                       epyc7551p-pve
  OS                             Debian GNU/Linux 12 (bookworm)
  Kernel                         6.8.12-15-pve
  Architecture                   x86_64
  Virtualization                 none
  Uptime                         up 5 weeks, 6 days, 19 hours, 17 minutes
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
  MLC ready: /tmp/mlc_bench_2437540/Linux/mlc

━━━  Memory & Cache Bandwidth  ━━━
  Level                                    Read        Write         Copy
  ──────────────────────────────────────────────────────────────────────
  Memory (DRAM)                      133.0 GB/s   127.8 GB/s   128.7 GB/s
  L1 Cache                          2804.2 GB/s   126.6 GB/s   376.6 GB/s
  L2 Cache                          1818.7 GB/s   123.9 GB/s   368.7 GB/s
  L3 Cache                           133.2 GB/s   126.6 GB/s   128.3 GB/s

━━━  Memory & Cache Latency  ━━━
  Level                                 Latency
  ──────────────────────────────────────────────
  L1 Cache                               1.2    ns
  L2 Cache                               7.6    ns
  L3 Cache                              13.5    ns
  Memory (DRAM)                        131.5    ns

━━━  Full Idle Latency Sweep (Buffer Size → Latency)  ━━━
           16K   1.2    ns
           64K   3.7    ns
          256K   4.5    ns
            1M   12.4   ns
            4M   13.3   ns
           16M   76.4   ns
           64M   129.4  ns
          256M   131.2  ns

━━━  Done  ━━━
  Elapsed time: 3m 14s
  Benchmark complete.
```

## Features

- **System Information** — OS, kernel, virtualization, uptime, disk, network interfaces, CPU frequency governor
- **CPU Information** — model, core/thread count, frequency, cache sizes, memory type and speed
- **Cache & Memory Bandwidth** — read, write, and copy throughput for DRAM, L1, L2, and L3 cache
- **Cache & Memory Latency** — idle latency for L1/L2/L3/DRAM, plus a full buffer-size sweep table
- Auto-downloads MLC at runtime (no manual install required)
- Auto-converts bandwidth ≥ 100,000 MB/s to GB/s for readability

## Requirements

| Tool | Notes |
|------|-------|
| `bash` | v4+ |
| `curl` or `wget` | For downloading MLC |
| `awk`, `grep`, `sed` | Standard GNU coreutils |
| `lscpu` | Part of `util-linux` |
| `sudo` / root | Required for full MLC access (MSR prefetcher control) |

Optional (improves output quality):
- `dmidecode` — memory type and speed detection
- `numactl` — NUMA node count
- `systemd-detect-virt` — virtualization detection

## Usage

```bash
# Basic run (some MLC tests may be restricted without root)
bash mlc_benchmark.sh

# Recommended: run as root for full results
sudo bash mlc_benchmark.sh
```


## Notes

- MLC is downloaded to a temporary directory (`/tmp/mlc_bench_<PID>`) and deleted automatically on exit.
- Without root, MLC cannot load the `msr` kernel module to disable hardware prefetchers, which may affect bandwidth and latency accuracy. A warning is printed in this case.
- Cache bandwidth write/copy columns show `N/A` for cache levels because MLC's `--peak_injection_bandwidth` with a restricted buffer size only reliably measures read throughput for those levels.
- The latency sweep uses `--idle_latency` with fixed buffer sizes to target each cache level: L1=16K, L2=512K, L3=6M, DRAM=256M.

## License

This script is provided as-is under the [MIT License](https://opensource.org/licenses/MIT). Intel MLC is subject to Intel's own [license terms](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).
