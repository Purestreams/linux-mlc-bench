#!/usr/bin/env bash
# ============================================================
#  mlc_benchmark.sh  –  AIDA64-style Cache & Memory Benchmark
#  Uses Intel MLC v3.12  https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
# ============================================================
set -euo pipefail

MLC_URL="https://downloadmirror.intel.com/866182/mlc_v3.12.tgz"
WORKDIR="${TMPDIR:-/tmp}/mlc_bench_$$"
VIRT="unknown"   # set by show_system_info, used by other sections
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ── helpers ────────────────────────────────────────────────
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }
hdr()  { echo -e "\n${CYAN}━━━  $*  ━━━${RESET}"; }
row()  { printf "  %-30s %s\n" "$1" "$2"; }

# Convert "NNN MB/s" → "X.X GB/s" when NNN >= 100000, else leave unchanged
fmt_bw() {
    awk '{
        if ($1 ~ /^[0-9]+$/ && $1+0 >= 100000)
            printf "%.1f GB/s", $1/1000
        else
            print
    }' <<< "$1"
}

require() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
    done
}

# ── detect package manager ──────────────────────────────────
_pkg_install() {
    local pkg="$1"
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq "$pkg" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg" >/dev/null 2>&1
    elif command -v pacman &>/dev/null; then
        pacman -Sq --noconfirm "$pkg" >/dev/null 2>&1
    elif command -v zypper &>/dev/null; then
        zypper install -y -q "$pkg" >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add -q "$pkg" >/dev/null 2>&1
    else
        return 1
    fi
}

# Try to install optional tools if root; silently skip if unavailable
ensure_optional() {
    # cmd:package pairs (package name may differ per distro but usually matches)
    local pairs=(
        "dmidecode:dmidecode"
        "numactl:numactl"
        "systemd-detect-virt:systemd"
        "lscpu:util-linux"
    )
    if [[ $EUID -ne 0 ]]; then return; fi
    for pair in "${pairs[@]}"; do
        local cmd="${pair%%:*}" pkg="${pair##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            printf "  Installing %s..." "$pkg"
            if _pkg_install "$pkg" && command -v "$cmd" &>/dev/null; then
                echo " done"
            else
                echo " skipped (not found in repos)"
            fi
        fi
    done
}

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
    l2=$(lscpu 2>/dev/null | awk '/^L2 cache/{$1=$2=""; gsub(/^[[:space:]]*/,""); print; exit}' || echo "?")
    l3=$(lscpu 2>/dev/null | awk '/^L3 cache/{$1=$2=""; gsub(/^[[:space:]]*/,""); print; exit}' || echo "?")
    row "L2 Cache"           "${l2}"
    row "L3 Cache"           "${l3}"
}

# ── memory information ───────────────────────────────────────
show_memory_info() {
    hdr "Memory Information"

    local dmi_out
    dmi_out=$(dmidecode -t memory 2>/dev/null || true)

    # Total installed memory
    local mem_total
    mem_total=$(awk '/MemTotal/{printf "%.1f GiB", $2/1024/1024}' /proc/meminfo)
    row "Memory Total"         "$mem_total"

    # Type + detail (from first populated DIMM)
    local mem_type
    mem_type=$(echo "$dmi_out" | awk '
        /Memory Device/{in_dev=1; type=""; detail=""; has_size=0}
        in_dev && /^[[:space:]]+Type:/ && $2!="Unknown" && $2!="Other" {type=$2}
        in_dev && /^[[:space:]]+Type Detail:/{detail=substr($0,index($0,$3))}
        in_dev && /^[[:space:]]+Size:/ && $2~/^[0-9]/ && $2+0>0 {has_size=1}
        in_dev && has_size && type!="" && /^[[:space:]]+Speed:/ {
            if(detail!="") print type" ("detail")"
            else print type
            exit
        }
    ')
    row "Memory Type"          "${mem_type:-N/A}"

    # Configured speed (first populated DIMM)
    local mem_speed
    mem_speed=$(echo "$dmi_out" | awk '/Configured Memory Speed:/{for(i=4;i<=NF;i++) printf "%s ",$i; print ""; exit}' | xargs)
    row "Configured Speed"     "${mem_speed:-N/A}"

    # Rated speed (skip "Unknown" values)
    local mem_rated
    mem_rated=$(echo "$dmi_out" | awk '/^[[:space:]]+Speed:/{if($2~/^[0-9]/) {for(i=2;i<=NF;i++) printf "%s ",$i; print ""; exit}}' | xargs)
    row "Rated Speed"          "${mem_rated:-N/A}"

    # DIMM count, size per DIMM, total slots
    local dimm_count dimm_size total_slots
    dimm_count=$(echo "$dmi_out" | awk '/^[[:space:]]+Size:/{if($2~/^[0-9]/ && $2+0>0) count++} END{print count+0}')
    dimm_size=$( echo "$dmi_out" | awk '/^[[:space:]]+Size:/{if($2~/^[0-9]/ && $2+0>0){print $2" "$3; exit}}')
    total_slots=$(echo "$dmi_out" | awk '/Number Of Devices:/{print $NF; exit}')
    row "DIMMs Installed"      "${dimm_count} x ${dimm_size} (${total_slots} slots total)"

    # Manufacturer
    local mfr
    mfr=$(echo "$dmi_out" | awk '/^[[:space:]]+Manufacturer:/ && $2!="Unknown" && $2!="" {print $2; exit}')
    row "Manufacturer"         "${mfr:-N/A}"

    # Part number
    local part
    part=$(echo "$dmi_out" | awk '/^[[:space:]]+Part Number:/{$1=$2=""; gsub(/^[[:space:]]*/,""); print; exit}' | xargs)
    row "Part Number"          "${part:-N/A}"

    # ECC
    local ecc
    ecc=$(echo "$dmi_out" | awk '/Error Correction Type:/{$1=$2=$3=""; gsub(/^[[:space:]]*/,""); print; exit}')
    row "ECC"                  "${ecc:-N/A}"

    # Memory channels in use (unique channel indices from Bank Locator field)
    # Use POSIX awk (no 3-arg match) for mawk compatibility
    local channels
    channels=$(echo "$dmi_out" | awk '
        /Bank Locator:/ {
            s=$0
            while (match(s,/Channel[0-9]+/)) {
                key=substr(s,RSTART+7,RLENGTH-7)
                ch[key]=1
                s=substr(s,RSTART+RLENGTH)
            }
        }
        END{print length(ch)}
    ')
    row "Channels In Use"      "${channels:-N/A}"

    # Per-DIMM topology table
    echo
    printf "  %-12s %-10s %-30s %s\n" "Locator" "Size" "Bank" "Manufacturer"
    echo "  $(printf '%0.s─' {1..68})"
    echo "$dmi_out" | awk '
        /Memory Device/{loc=""; bank=""; size=""; speed=""; mfr=""}
        /^[[:space:]]+Locator:/ && !/Bank/{loc=$2}
        /^[[:space:]]+Bank Locator:/{bank=substr($0,index($0,$3))}
        /^[[:space:]]+Size:/{size=$2" "$3}
        /^[[:space:]]+Manufacturer:/{mfr=$2}
        /^[[:space:]]+Part Number:/ && loc!="" && size+0>0 {
            printf "  %-12s %-10s %-30s %s\n", loc, size, bank, mfr
        }
    '
}

# ── system information ───────────────────────────────────────
show_system_info() {
    hdr "System Information"

    # OS / Kernel
    local os_name kernel hostname_str
    os_name=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -o)
    kernel=$(uname -r)
    hostname_str=$(hostname 2>/dev/null || echo "N/A")
    row "Hostname"            "$hostname_str"
    row "OS"                  "$os_name"
    row "Kernel"              "$kernel"

    # Architecture / Virtualization
    local arch virt
    arch=$(uname -m)
    if command -v systemd-detect-virt &>/dev/null; then
        virt=$(systemd-detect-virt 2>/dev/null; true)
    elif grep -qi "hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt="hypervisor"
    else
        virt="none"
    fi
    VIRT="$virt"
    row "Architecture"        "$arch"
    row "Virtualization"      "$virt"

    # Uptime
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    row "Uptime"              "$uptime_str"

    # NUMA topology
    local numa_nodes
    if command -v numactl &>/dev/null; then
        numa_nodes=$(numactl --hardware 2>/dev/null | awk '/available:/{print $2}')
    else
        numa_nodes=$(ls /sys/devices/system/node/ 2>/dev/null | grep -c '^node[0-9]' || echo "N/A")
    fi
    row "NUMA Nodes"          "${numa_nodes:-N/A}"

    # Disk (root fs)
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s total, %s used, %s avail", $2,$3,$4}' || echo "N/A")
    row "Root Disk"           "$disk_info"

    # Network interfaces (non-loopback)
    #local ifaces
    #ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '!/loopback/{gsub(/@.*/,"",$2); printf "%s ", $2}' | sed 's/ $//' || echo "N/A")
    #row "Network Interfaces"  "$ifaces"

    # Scaling governor (skip in VMs — usually not controllable)
    if [[ "$VIRT" == "none" ]]; then
        local governor
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
        row "CPU Freq Governor"   "$governor"
    fi
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
    hdr "Memory & Cache Bandwidth"
    echo -e "  ${BOLD}$(printf '%-32s %12s %12s %12s' 'Level' 'Read' 'Write' 'Copy')${RESET}"
    echo    "  $(printf '%0.s─' {1..70})"

    # MLC --bandwidth_matrix gives per-socket read BW
    # MLC --peak_injection_bandwidth gives peak read/write/copy/triad
    local bw_out
    bw_out=$("$MLC_BIN" --peak_injection_bandwidth 2>/dev/null || true)

    # Peak memory BW (all-read, all-write, 1:1 r+w streams simulate Copy/Triad)
    # MLC v3.12 output lines: "ALL Reads", "All NT writes", "Stream-triad like"
    local mem_read mem_write mem_copy
    mem_read=$(  echo "$bw_out" | awk '/ALL Reads/{printf "%.0f MB/s", $NF}' 2>/dev/null || echo "N/A")
    mem_write=$( echo "$bw_out" | awk '/All NT writes/{printf "%.0f MB/s", $NF}' 2>/dev/null || echo "N/A")
    mem_copy=$(  echo "$bw_out" | awk '/Stream-triad like/{printf "%.0f MB/s", $NF}' 2>/dev/null || echo "N/A")

    printf "  %-32s %12s %12s %12s\n" "Memory (DRAM)"  "$(fmt_bw "$mem_read")" "$(fmt_bw "$mem_write")" "$(fmt_bw "$mem_copy")"

    # Cache BW: use fixed per-thread buffer sizes that stay within each cache level.
    # L1: 16K  (L1d ≥ 32KB), L2: 512K (L2 ≥ 1MB per core), L3: detected_l3/4
    local l3_kb
    l3_kb=$(lscpu 2>/dev/null | awk '/^L3 cache/{v=$3; u=$4;
        if(u~/[Gg]/) v=v*1024*1024; else if(u~/[Mm]/) v=v*1024; print int(v)}' || echo 8192)
    [[ "$l3_kb" -gt 0 ]] 2>/dev/null || l3_kb=8192

    for level_label in "L1 Cache:16K" "L2 Cache:512K" "L3 Cache:$((l3_kb/4))K"; do
        local label buf_k bw_r bw_w bw_c cache_out
        label="${level_label%%:*}"
        buf_k="${level_label##*:}"
        cache_out=$("$MLC_BIN" --peak_injection_bandwidth -b"${buf_k}" 2>/dev/null || true)
        bw_r=$(echo "$cache_out" | awk '/ALL Reads/{printf "%.0f MB/s", $NF}')
        bw_w=$(echo "$cache_out" | awk '/All NT writes/{printf "%.0f MB/s", $NF}')
        bw_c=$(echo "$cache_out" | awk '/Stream-triad like/{printf "%.0f MB/s", $NF}')
        printf "  %-32s %12s %12s %12s\n" "$label" "$(fmt_bw "${bw_r:-N/A}")" "$(fmt_bw "${bw_w:-N/A}")" "$(fmt_bw "${bw_c:-N/A}")"
    done
    printf "    *L1/L2/L3: Only the read bandwidth is meaningful for cache levels.\n"
}

# ── latency tests ────────────────────────────────────────────
run_latency() {
    hdr "Memory & Cache Latency"
    echo -e "  ${BOLD}$(printf '%-32s %12s' 'Level' 'Latency')${RESET}"
    echo    "  $(printf '%0.s─' {1..46})"

    # Run --idle_latency with a specific buffer size (-b) so data fits in target cache.
    # Output is a NUMA latency matrix; extract the local-node value (first numeric row).
    # Falls back to parsing "Each iteration took X clocks ( Y ns)" format.
    mlc_lat() {
        "$MLC_BIN" --idle_latency -b"$1" 2>/dev/null \
            | awk 'NF==2 && $1~/^[[:space:]]*[0-9]/ && $2+0>0 {printf "%.1f ns", $2; exit}
                  /ns\)/{match($0,/[0-9]+\.[0-9]+[[:space:]]*ns/); if(RSTART){print substr($0,RSTART,RLENGTH); exit}}'
    }

    printf "  %-32s %12s\n" "L1 Cache"      "$(mlc_lat 16K)"
    printf "  %-32s %12s\n" "L2 Cache"      "$(mlc_lat 512K)"
    printf "  %-32s %12s\n" "L3 Cache"      "$(mlc_lat 6M)"
    printf "  %-32s %12s\n" "Memory (DRAM)" "$(mlc_lat 256M)"

    hdr "Full Idle Latency Sweep (Buffer Size → Latency)"
    for sz in 16K 64K 256K 1M 4M 16M 64M 256M; do
        printf "  %12s   %s\n" "$sz" "$(mlc_lat $sz)"
    done
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
echo "  ║                           By @Purestreams        ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

check_root
require awk grep sed
ensure_optional

START_TIME=$(date +%s)

show_system_info
show_cpu_info
[[ "$VIRT" == "none" ]] && show_memory_info || echo -e "\n${YELLOW}  (Memory Information skipped — running inside VM: $VIRT)${RESET}"
setup_mlc
run_bandwidth
run_latency

hdr "Done"
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
printf "  Elapsed time: %dm %02ds\n" $((ELAPSED/60)) $((ELAPSED%60))
echo -e "  ${GREEN}Benchmark complete.${RESET}"
