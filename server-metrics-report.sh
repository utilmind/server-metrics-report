#!/usr/bin/env bash
# server_report.sh
# Generates a comparable system report (hardware, OS, disk, CPU, memory, basic perf signals).
set -euo pipefail

ts="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -f 2>/dev/null || hostname)"
out="server-report_${host}_${ts}.txt"

have() { command -v "$1" >/dev/null 2>&1; }

safe() {
    # Run a command but never fail the whole script.
    # Useful on old distros where tools return non-zero even with partial output.
    "$@" || true
}

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

    # --- Memory (compat: old procps/free on Ubuntu 14.04) ---
    section "Memory"

    # Prefer /proc/meminfo as the most stable source across distros
    mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"
    mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"
    swap_total_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"
    swap_free_kb="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"

    # If MemAvailable is missing (common on old kernels), estimate it:
    # MemAvailable ~= MemFree + Buffers + Cached (rough, but better than blank)
    if [ -z "${mem_avail_kb}" ]; then
        mem_free_kb="$(awk '/^MemFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        buffers_kb="$(awk '/^Buffers:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        cached_kb="$(awk '/^Cached:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        mem_avail_kb="$((mem_free_kb + buffers_kb + cached_kb))"
        kv "MemAvailable(estimated kB)" "${mem_avail_kb}"
    else
        kv "MemAvailable(kB)" "${mem_avail_kb}"
    fi

    if [ -n "${mem_total_kb}" ]; then
        kv "MemTotal(kB)" "${mem_total_kb}"
    fi
    if [ -n "${swap_total_kb}" ]; then
        kv "SwapTotal(kB)" "${swap_total_kb}"
    fi
    if [ -n "${swap_free_kb}" ]; then
        kv "SwapFree(kB)" "${swap_free_kb}"
    fi

    # Additionally, parse 'free' if available, but do it by labels, not line numbers
    if have free; then
        # free output differs between procps versions; match by the row prefix (Mem:/Swap:)
        free -b 2>/dev/null | awk '
            $1=="Mem:" {
                printf "%-28s %s\n","MemTotal(bytes):",$2
                printf "%-28s %s\n","MemUsed(bytes):",$3
                printf "%-28s %s\n","MemFree(bytes):",$4
                # Some versions have "available" as the 7th column, some do not.
                if (NF>=7) printf "%-28s %s\n","MemAvailable(bytes):",$7
            }
            $1=="Swap:" {
                printf "%-28s %s\n","SwapTotal(bytes):",$2
                printf "%-28s %s\n","SwapUsed(bytes):",$3
                printf "%-28s %s\n","SwapFree(bytes):",$4
            }
        '
    fi

    section "Disk (filesystems)"
    if have df; then
        # Capture df output once. On old systems df can exit non-zero (e.g., for inaccessible mounts),
        # which would otherwise terminate the script due to `set -e`.
        df_out="$(safe df -B1 -T -x tmpfs -x devtmpfs -x squashfs 2>/dev/null)"
        echo "FilesystemTypeReport:"
        echo "$df_out" | tail -n +2 || true

        # Totals computed from captured output (avoid running df twice).
        echo "$df_out" | awk 'NR>1{sum+=$3; avail+=$5} END{printf "%-28s %s\n","DiskUsedTotal(bytes):",sum; printf "%-28s %s\n","DiskAvailTotal(bytes):",avail}' || true
    fi

    section "Block devices"
    if have lsblk; then
        lsblk -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,ROTA,MODEL,SERIAL 2>/dev/null || true
    fi

    section "Network (quick)"
    kv "Primary IP" "$(safe hostname -I 2>/dev/null | awk '{print $1}')"
    if have ip; then
        safe ip -o link show | awk -F': ' '{print $2}' | head -n 10 | awk '{printf "%-28s %s\n","Iface:",$1}'
    fi

    section "Load / uptime"
    kv "Uptime" "$(uptime -p 2>/dev/null || uptime)"
    kv "Loadavg" "$(cat /proc/loadavg 2>/dev/null || echo unknown)"

    section "Top processes (CPU/MEM snapshot)"
    if have ps; then
        echo "# top by CPU"
        safe ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 12
        echo
        echo "# top by MEM"
        safe ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 12
    fi

    section "Kernel / perf hints"
    kv "CPU governor" "$( (cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a) )"
    kv "Transparent HugePages" "$( (cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a) | tr -s ' ' )"
    kv "Swappiness" "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo n/a)"

    section "Quick CPU benchmark"
    # Prefer sysbench if present; fallback to openssl speed; fallback to a portable hash-throughput test.
    if have sysbench; then
        safe sysbench cpu --cpu-max-prime=20000 run 2>/dev/null | awk -F: '
            /events per second/ {gsub(/^[ 	]+/,"",$2); printf "%-28s %s
","sysbench_cpu_eps:",$2}
            /total time/ {gsub(/^[ 	]+/,"",$2); printf "%-28s %s
","sysbench_cpu_time:",$2}
        '
    elif have openssl; then
        # Short run; gives rough signal. Some old builds may not support all algorithms; ignore failures.
        safe openssl speed -seconds 3 sha256 2>/dev/null | tail -n 2 | sed 's/^/openssl_speed: /'
    else
        # Portable fallback: measure hashing throughput using sha256sum (or md5sum) over a fixed buffer.
        # This is NOT a standardized benchmark, but it provides a comparable signal across servers.
        if have sha256sum; then
            algo="sha256sum"
        elif have md5sum; then
            algo="md5sum"
        else
            algo=""
        fi

        if [ -n "$algo" ]; then
            size_mb=256
            # Prefer nanoseconds if supported; fall back to seconds.
            t0="$(date +%s%N 2>/dev/null || date +%s)"
            # Stream a fixed amount of zeros through the hash function.
            safe dd if=/dev/zero bs=1M count=$size_mb 2>/dev/null | safe "$algo" >/dev/null
            t1="$(date +%s%N 2>/dev/null || date +%s)"

            # Compute duration in seconds (as float) and throughput MB/s using awk (no bc dependency).
            awk -v t0="$t0" -v t1="$t1" -v mb="$size_mb" '
                BEGIN {
                    # If timestamps are in nanoseconds, they will be much larger.
                    dt = t1 - t0
                    if (dt > 1000000000) {
                        sec = dt / 1000000000.0
                    } else {
                        sec = dt * 1.0
                    }
                    if (sec <= 0) sec = 0.000001
                    thr = mb / sec
                    printf "%-28s %.3f
","cpu_hash_time_sec:", sec
                    printf "%-28s %.2f
","cpu_hash_mb_s:", thr
                    printf "%-28s %s
","cpu_hash_algo:", "'$algo'"
                    printf "%-28s %d
","cpu_hash_size_mb:", mb
                }
            '
        else
            kv "CPU bench" "skipped (install sysbench or openssl; no sha256sum/md5sum found)"
        fi
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