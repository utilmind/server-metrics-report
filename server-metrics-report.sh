#!/usr/bin/env bash
# server_report.sh
# Generates a comparable system report (hardware, OS, disk, CPU, memory, basic perf signals).
set -euo pipefail

ts="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -f 2>/dev/null || hostname)"
out="server-report_${host}_${ts}.txt"

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  echo
  echo "### $1"
}

kv() {
  # Print as key: value (stable format for diff)
  printf "%-28s %s\n" "$1:" "$2"
}

{
  echo "# Server report"
  kv "UTC time" "$(date -u -Is)"
  kv "Host" "$host"
  kv "Kernel" "$(uname -r)"
  kv "Uname" "$(uname -a)"

  section "OS"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    kv "OS" "${PRETTY_NAME:-unknown}"
  fi

  section "CPU"
  if have lscpu; then
    # Stable subset for compare
    lscpu | awk -F: '
      BEGIN { keep["Model name"]=1; keep["CPU(s)"]=1; keep["Thread(s) per core"]=1; keep["Core(s) per socket"]=1; keep["Socket(s)"]=1; keep["CPU MHz"]=1; keep["L1d cache"]=1; keep["L1i cache"]=1; keep["L2 cache"]=1; keep["L3 cache"]=1; keep["NUMA node(s)"]=1 }
      { gsub(/^[ \t]+/,"",$1); gsub(/^[ \t]+/,"",$2); if (keep[$1]) printf "%-28s %s\n", $1":", $2 }
    '
  else
    kv "CPU(s)" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
    kv "Model" "$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ *//')"
  fi

  section "Memory"
  if have free; then
    free -b | awk 'NR==2{printf "%-28s %s\n","MemTotal(bytes):",$2} NR==2{printf "%-28s %s\n","MemUsed(bytes):",$3} NR==2{printf "%-28s %s\n","MemFree(bytes):",$4} NR==2{printf "%-28s %s\n","MemAvailable(bytes):",$7}'
    free -b | awk 'NR==3{printf "%-28s %s\n","SwapTotal(bytes):",$2} NR==3{printf "%-28s %s\n","SwapUsed(bytes):",$3} NR==3{printf "%-28s %s\n","SwapFree(bytes):",$4}'
  fi
  if [ -r /proc/meminfo ]; then
    awk -F: '/MemTotal|MemAvailable|SwapTotal|SwapFree/ {gsub(/^[ \t]+/,"",$2); printf "%-28s %s\n",$1":",$2}' /proc/meminfo
  fi

  section "Disk (filesystems)"
  if have df; then
    # Exclude pseudo filesystems for readability
    df -B1 -T -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed '1s/.*/FilesystemTypeReport:/'
    df -B1 -T -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1{sum+=$3; avail+=$5} END{printf "%-28s %s\n","DiskUsedTotal(bytes):",sum; printf "%-28s %s\n","DiskAvailTotal(bytes):",avail}'
  fi

  section "Block devices"
  if have lsblk; then
    lsblk -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,ROTA,MODEL,SERIAL 2>/dev/null || true
  fi

  section "Network (quick)"
  kv "Primary IP" "$(hostname -I 2>/dev/null | awk '{print $1}')"
  if have ip; then
    ip -o link show | awk -F': ' '{print $2}' | head -n 10 | awk '{printf "%-28s %s\n","Iface:",$1}'
  fi

  section "Load / uptime"
  kv "Uptime" "$(uptime -p 2>/dev/null || uptime)"
  kv "Loadavg" "$(cat /proc/loadavg 2>/dev/null || echo unknown)"

  section "Top processes (CPU/MEM snapshot)"
  if have ps; then
    echo "# top by CPU"
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 12
    echo
    echo "# top by MEM"
    ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 12
  fi

  section "Kernel / perf hints"
  kv "CPU governor" "$( (cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a) )"
  kv "Transparent HugePages" "$( (cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a) | tr -s ' ' )"
  kv "Swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo n/a)"

  section "Quick CPU benchmark"
  # Prefer sysbench if present; fallback to openssl speed; else skip.
  if have sysbench; then
    sysbench cpu --cpu-max-prime=20000 run 2>/dev/null | awk -F: '
      /events per second/ {gsub(/^[ \t]+/,"",$2); printf "%-28s %s\n","sysbench_cpu_eps:",$2}
      /total time/ {gsub(/^[ \t]+/,"",$2); printf "%-28s %s\n","sysbench_cpu_time:",$2}
    '
  elif have openssl; then
    # Short run; gives rough signal
    openssl speed -seconds 3 sha256 2>/dev/null | tail -n 2 | sed 's/^/openssl_speed: /'
  else
    kv "CPU bench" "skipped (install sysbench for comparable metric)"
  fi

  section "Quick memory bandwidth-ish test"
  # dd to /dev/shm (RAM) gives very rough upper bound if tmpfs is available.
  if [ -d /dev/shm ]; then
    sync
    dd if=/dev/zero of=/dev/shm/.memtest.$$ bs=64M count=4 conv=fdatasync 2>&1 | awk '/copied/ {print "dd_shm_write:", $0}'
    rm -f /dev/shm/.memtest.$$ || true
  else
    kv "Mem bench" "skipped (/dev/shm not present)"
  fi

  section "Quick disk write test (DANGEROUS on busy prod if run on slow disk)"
  # Writes 1 GiB to /tmp; you can disable by setting SKIP_DISK_TEST=1
  if [ "${SKIP_DISK_TEST:-0}" = "1" ]; then
    kv "Disk bench" "skipped (SKIP_DISK_TEST=1)"
  else
    if [ -d /tmp ]; then
      sync
      dd if=/dev/zero of=/tmp/.disktest.$$ bs=64M count=16 conv=fdatasync 2>&1 | awk '/copied/ {print "dd_tmp_write:", $0}'
      rm -f /tmp/.disktest.$$ || true
    else
      kv "Disk bench" "skipped (/tmp not present)"
    fi
  fi

  section "Notes"
  echo "- For deeper IO: install fio and run a consistent profile."
  echo "- For CPU: sysbench output is the most comparable if available."
} | tee "$out"

echo
echo "Saved: $out"