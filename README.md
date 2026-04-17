# mlc_benchmark.sh

An AIDA64-style cache and memory benchmark for Linux, powered by [Intel Memory Latency Checker (MLC) v3.12](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).

## Features

- **System Information** — OS, kernel, virtualization, uptime, disk, network interfaces, CPU frequency governor
- **CPU Information** — model, core/thread count, frequency, cache sizes, memory type and speed
- **Cache & Memory Bandwidth** — read, write, and copy throughput for DRAM, L1, L2, and L3 cache
- **Cache & Memory Latency** — idle latency for L1/L2/L3/DRAM, plus a full buffer-size sweep table
- Auto-downloads MLC at runtime (no manual install required)
- Auto-converts bandwidth ≥ 100,000 MB/s to GB/s for readability

## Quick Run

```bash
wget -qO- https://raw.githubusercontent.com/miozhu/linux-mlc-bench/main/mlc_benchmark.sh | sudo bash
```

Or with `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/miozhu/linux-mlc-bench/main/mlc_benchmark.sh | sudo bash
```

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

On WSL:
```bash
wsl -e bash -c "sudo bash /mnt/c/path/to/mlc_benchmark.sh"
```

## Sample Output

```
━━━  System Information  ━━━
  Hostname                       Mio-PC
  OS                             Ubuntu 22.04.5 LTS
  Kernel                         6.6.87.2-microsoft-standard-WSL2
  Architecture                   x86_64
  Virtualization                 wsl

━━━  CPU Information  ━━━
  CPU Model                      Intel(R) Core(TM) Ultra 5 235
  Physical Cores                 14
  Logical CPUs                   14
  L2 Cache                       42 MiB (14 instances)
  L3 Cache                       24 MiB (1 instance)
  Memory Total                   15.3 GiB

━━━  Memory & Cache Bandwidth  ━━━
  Level                                    Read        Write         Copy
  ──────────────────────────────────────────────────────────────────────
  Memory (DRAM)                      76448 MB/s   58278 MB/s   66205 MB/s
  L1 Cache                          1951.3 GB/s          N/A          N/A
  L2 Cache                          1250.5 GB/s          N/A          N/A
  L3 Cache                           157.0 GB/s          N/A          N/A

━━━  Memory & Cache Latency  ━━━
  Level                                 Latency
  ──────────────────────────────────────────────
  L1 Cache                               0.8 ns
  L2 Cache                               3.7 ns
  L3 Cache                              10.9 ns
  Memory (DRAM)                         76.0 ns

━━━  Full Idle Latency Sweep (Buffer Size → Latency)  ━━━
           16K   0.9 ns
           64K   1.9 ns
          256K   3.1 ns
            1M   3.8 ns
            4M   9.3 ns
           16M   66.5 ns
           64M   78.2 ns
          256M   76.0 ns
```

## Notes

- MLC is downloaded to a temporary directory (`/tmp/mlc_bench_<PID>`) and deleted automatically on exit.
- Without root, MLC cannot load the `msr` kernel module to disable hardware prefetchers, which may affect bandwidth and latency accuracy. A warning is printed in this case.
- Cache bandwidth write/copy columns show `N/A` for cache levels because MLC's `--peak_injection_bandwidth` with a restricted buffer size only reliably measures read throughput for those levels.
- The latency sweep uses `--idle_latency` with fixed buffer sizes to target each cache level: L1=16K, L2=512K, L3=6M, DRAM=256M.

## License

This script is provided as-is under the [MIT License](https://opensource.org/licenses/MIT). Intel MLC is subject to Intel's own [license terms](https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html).
