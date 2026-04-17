#!/usr/bin/env bash
# ============================================================
#  mlc_benchmark.sh  –  AIDA64-style Cache & Memory Benchmark
#  Uses Intel MLC v3.12  https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
# ============================================================
set -euo pipefail

MLC_URL="https://downloadmirror.intel.com/866182/mlc_v3.12.tgz"
WORKDIR="${TMPDIR:-/tmp}/mlc_bench_$$"
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ── helpers ────────────────────────────────────────────────
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
hdr()  { echo -e "\n${CYAN}━━━  $*  ━━━${RESET}"; }
row()  { printf "  %-30s %s\n" "$1" "$2"; }

require() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
    done
}

# ── check privileges (MLC needs root for some tests) ───────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Warning: running without root. Some MLC tests may be restricted.${RESET}"
        echo -e "         Re-run with: ${BOLD}sudo $0${RESET}\n"
    fi
}

# ── CPU info ────────────────────────────────────────────────
show_cpu_info() {
    hdr "CPU Information"
    local model cores threads sockets freq_min freq_max
    model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
    cores=$(grep -c "^processor" /proc/cpuinfo)
    sockets=$(grep -c "^physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l || echo 1)
    # physical cores (unique core id per physical id)
    phys_cores=$(awk '/^core id/{core[$0]=1}/^physical id/{phys[$0]=1}END{print length(core)}' /proc/cpuinfo 2>/dev/null || echo "?")
    freq_min=$(awk '/^cpu MHz/{m=$4} END{printf "%.0f", m}' /proc/cpuinfo)
    freq_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null \
               | awk '{printf "%.1f", $1/1000}' || \
               awk '/^cpu MHz/{if($4>m)m=$4}END{printf "%.1f",m}' /proc/cpuinfo)

    row "CPU Model"          "$model"
    row "Physical Cores"     "$phys_cores"
    row "Logical CPUs"       "$cores"
    row "Max Frequency"      "${freq_max} MHz"

    # Stepping / Family / Model
    local stepping family cpu_model
    stepping=$(grep -m1 "^stepping"   /proc/cpuinfo | awk '{print $NF}')
    family=$(  grep -m1 "^cpu family" /proc/cpuinfo | awk '{print $NF}')
    cpu_model=$(grep -m1 "^model"     /proc/cpuinfo | grep -v "model name" | awk '{print $NF}')
    row "CPU Family / Model / Stepping" "$family / $cpu_model / $stepping"

    # Cache sizes from /proc/cpuinfo
    local l1d l1i l2 l3
    l1d=$(grep -m1 "cache size" /proc/cpuinfo | awk '{print $4, $5}')
    l2=$(lscpu 2>/dev/null | awk '/^L2 cache/{print $3}' || echo "?")
    l3=$(lscpu 2>/dev/null | awk '/^L3 cache/{print $3}' || echo "?")
    row "L2 Cache"           "${l2}"
    row "L3 Cache"           "${l3}"

    # NUMA / Memory info
    local mem_total mem_type mem_speed
    mem_total=$(awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)
    mem_type=$(dmidecode -t memory 2>/dev/null | awk '/^\s+Type:/{print $2;exit}' || echo "N/A")
    mem_speed=$(dmidecode -t memory 2>/dev/null | awk '/Speed:/{gsub(/[^0-9]/,"",$0); if($0+0>0){print $0" MT/s";exit}}' || echo "N/A")
    row "Memory Total"       "$mem_total"
    row "Memory Type"        "$mem_type"
    row "Memory Speed"       "$mem_speed"
}

# ── download + extract MLC ──────────────────────────────────
setup_mlc() {
    hdr "Setting Up Intel MLC"
    mkdir -p "$WORKDIR"
    local tgz="$WORKDIR/mlc.tgz"

    if [[ ! -f "$tgz" ]]; then
        echo "  Downloading MLC from Intel..."
        if command -v curl &>/dev/null; then
            curl -fsSL --retry 3 -o "$tgz" "$MLC_URL"
        else
            wget -q --tries=3 -O "$tgz" "$MLC_URL"
        fi
    fi

    tar -xzf "$tgz" -C "$WORKDIR"
    MLC_BIN=$(find "$WORKDIR" -name "mlc" -type f | head -1)
    [[ -n "$MLC_BIN" ]] || die "mlc binary not found after extraction."
    chmod +x "$MLC_BIN"
    echo "  MLC ready: $MLC_BIN"
}

# ── bandwidth tests ─────────────────────────────────────────
run_bandwidth() {
    hdr "Memory & Cache Bandwidth (like AIDA64)"
    echo -e "  ${BOLD}$(printf '%-32s %12s %12s %12s' 'Level' 'Read' 'Write' 'Copy')${RESET}"
    echo    "  $(printf '%0.s─' {1..70})"

    # MLC --bandwidth_matrix gives per-socket read BW
    # MLC --peak_injection_bandwidth gives peak read/write/copy/triad
    local bw_out
    bw_out=$("$MLC_BIN" --peak_injection_bandwidth 2>/dev/null || true)

    # Peak memory BW (all-read, all-write, 1:1 r+w streams simulate Copy/Triad)
    local mem_read mem_write mem_copy
    mem_read=$(  echo "$bw_out" | awk '/ALL Reads/{printf "%.0f MB/s", $NF*1}' 2>/dev/null || echo "N/A")
    mem_write=$( echo "$bw_out" | awk '/ALL Writes/{printf "%.0f MB/s", $NF*1}' 2>/dev/null || echo "N/A")
    mem_copy=$(  echo "$bw_out" | awk '/2:1 Reads-Writes/{printf "%.0f MB/s", $NF*1}' 2>/dev/null || echo "N/A")

    printf "  %-32s %12s %12s %12s\n" "Memory (DRAM)"  "$mem_read" "$mem_write" "$mem_copy"

    # Cache BW via --loaded_latency with buffer sizes
    # L1 ≈ 16 KB, L2 ≈ 256 KB, L3 ≈ 8 MB (auto-detect)
    local l1_size l2_size l3_size
    l1_size=$(lscpu 2>/dev/null | awk '/^L1d cache/{gsub(/[^0-9]/,"",$3); print $3+0}' || echo 32)
    l2_size=$(lscpu 2>/dev/null | awk '/^L2 cache/{gsub(/[^0-9KkMm]/,"",$3); v=$3; if(v~/[Mm]/)v=v*1024; print v+0}' || echo 256)
    l3_size=$(lscpu 2>/dev/null | awk '/^L3 cache/{gsub(/[^0-9KkMm]/,"",$3); v=$3; if(v~/[Mm]/)v=v*1024; print v+0}' || echo 8192)

    for level_label in "L1 Cache:$((l1_size/2))K" "L2 Cache:$((l2_size/2))K" "L3 Cache:$((l3_size*3/4))K"; do
        local label buf_k bw_r
        label="${level_label%%:*}"
        buf_k="${level_label##*:}"
        bw_r=$("$MLC_BIN" --peak_injection_bandwidth -b"${buf_k}" 2>/dev/null \
               | awk '/ALL Reads/{printf "%.0f MB/s", $NF}' || echo "N/A")
        printf "  %-32s %12s %12s %12s\n" "$label"  "$bw_r" "N/A" "N/A"
    done
}

# ── latency tests ────────────────────────────────────────────
run_latency() {
    hdr "Memory & Cache Latency"
    echo -e "  ${BOLD}$(printf '%-32s %12s' 'Level' 'Latency')${RESET}"
    echo    "  $(printf '%0.s─' {1..46})"

    # --idle_latency gives loaded latency sweep across buffer sizes
    # We run a quick idle latency sweep with --idle_latency
    local lat_out
    lat_out=$("$MLC_BIN" --idle_latency 2>/dev/null || true)

    # Parse the table: columns are "Size(KB)  Latency(ns)"
    # Find the last line before DRAM plateau for L3, then step back for L2/L1
    local l1_lat l2_lat l3_lat mem_lat
    l1_lat=$( echo "$lat_out" | awk 'NR>3 && $1+0 <= 32          {last=$2} END{print last" ns"}' 2>/dev/null || echo "N/A")
    l2_lat=$( echo "$lat_out" | awk 'NR>3 && $1+0 > 32  && $1+0 <= 512   {last=$2} END{print last" ns"}' 2>/dev/null || echo "N/A")
    l3_lat=$( echo "$lat_out" | awk 'NR>3 && $1+0 > 512 && $1+0 <= 32768 {last=$2} END{print last" ns"}' 2>/dev/null || echo "N/A")
    mem_lat=$(echo "$lat_out" | awk 'NR>3 && $1+0 > 32768               {last=$2} END{print last" ns"}' 2>/dev/null || echo "N/A")

    printf "  %-32s %12s\n" "L1 Cache"  "$l1_lat"
    printf "  %-32s %12s\n" "L2 Cache"  "$l2_lat"
    printf "  %-32s %12s\n" "L3 Cache"  "$l3_lat"
    printf "  %-32s %12s\n" "Memory (DRAM)"  "$mem_lat"

    # Full loaded latency sweep table
    hdr "Full Idle Latency Sweep (Buffer Size → Latency)"
    echo "$lat_out" | awk 'NR>2 && NF==2 {printf "  %10s KB   %s ns\n", $1, $2}'
}

# ── cleanup ─────────────────────────────────────────────────
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ── main ─────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     Cache & Memory Benchmark  (Intel MLC)        ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

check_root
require awk grep sed

show_cpu_info
setup_mlc
run_bandwidth
run_latency

hdr "Done"
echo -e "  ${GREEN}Benchmark complete.${RESET}"
