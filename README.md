# Server Metrics Report (SSH-Friendly) — `server-metrics-report.sh`

Generate a **consistent, comparable** system report from any Linux server via SSH.
The report is designed to be easy to **diff** between two servers to compare:

- **CPU**: model, cores/threads, sockets, caches, NUMA (when available)
- **Memory**: total/used/available + swap
- **Disk**: filesystem usage, block devices (size, type, mountpoints, model)
- **Load**: uptime + load average
- **Processes**: top CPU and memory consumers (snapshot)
- **Perf hints**: governor, THP, swappiness
- **Quick benchmarks** (optional / best-effort):
  - CPU: `sysbench` if installed, otherwise `openssl speed` (if available)
  - Memory: quick `/dev/shm` write test (very rough signal)
  - Disk: optional `/tmp` write test (can be disabled)

> ⚠️ Note: The “benchmarks” are **quick signals**, not lab-grade performance testing.
> For serious IO testing, use `fio` with a controlled profile.

---

## Files

- `server-metrics-report.sh` — the report generator script

---

## Requirements

- Linux (Debian/Ubuntu/RHEL/CentOS/Amazon Linux, etc.)
- Common tools are used when present (`lscpu`, `free`, `df`, `lsblk`, `ps`, `ip`)
- Optional:
  - `sysbench` (recommended for comparable CPU metric)
  - `openssl` (fallback CPU speed metric)

No installation is required for basic reporting.

---

## Usage

### 1) Run locally on the server

```bash
chmod +x server-metrics-report.sh
./server-metrics-report.sh
```

This creates a file like:

```
server-report_<hostname>_<timestamp>.txt
```

---

### 2) Recommended for production: disable disk test

The disk test writes ~1 GiB to `/tmp`. On busy production systems it may be undesirable.

```bash
SKIP_DISK_TEST=1 ./server-metrics-report.sh
```

---

### 3) Run over SSH (no copying needed)

From your local machine:

```bash
ssh user@server1 'bash -s' < server-metrics-report.sh > server1.txt
ssh user@server2 'bash -s' < server-metrics-report.sh > server2.txt
```

---

### 4) Compare two servers (diff)

```bash
diff -u server1.txt server2.txt | less
```

---

## What the script outputs

The report is split into sections:

- **HOST / OS**
  - Hostname, UTC time, kernel, OS release
- **CPU**
  - `lscpu` key fields (model, cores/threads, caches, NUMA)
- **Memory**
  - `free` + selected `/proc/meminfo`
- **Disk**
  - `df` filesystem usage (excluding tmpfs/devtmpfs)
  - `lsblk` block device inventory (size/type/model/rotational/etc.)
- **Network (quick)**
  - Primary IP and basic interface list
- **Load / uptime**
  - Uptime and `/proc/loadavg`
- **Top processes**
  - Top CPU and top memory (snapshot)
- **Kernel / performance hints**
  - CPU governor, THP, swappiness
- **Quick benchmarks**
  - CPU: `sysbench` if present, else `openssl speed` if present
  - Memory: `dd` write test to `/dev/shm`
  - Disk: `dd` write test to `/tmp` (optional)

---

## Safety notes

- The disk benchmark writes a temporary file to `/tmp` and removes it afterwards.
  - Disable it with `SKIP_DISK_TEST=1`.
- The script does **not** require root, but some fields may be limited without privileges.
- Running on heavily loaded hosts can produce noisy benchmark numbers.

---

## Tips for better comparability

- Run reports at similar load levels (ideally low load).
- Prefer installing `sysbench` on both servers to compare CPU consistently.
- If IO matters, use `fio` with identical parameters (block size, queue depth, runtime, file size).

---

## Example output snippet

```text
# Server report
UTC time:                    2026-03-03T12:34:56Z
Host:                        example.host
Kernel:                      5.15.0-...
...
### CPU
Model name:                  Intel(R) Xeon(R) ...
CPU(s):                      16
Thread(s) per core:          2
Core(s) per socket:          8
Socket(s):                   1
...
### Quick CPU benchmark
sysbench_cpu_eps:            1234.56
sysbench_cpu_time:           10.00s
```

---

## License

MIT
