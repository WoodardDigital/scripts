#!/usr/bin/env bash
#
# gpu-diag.sh — GPU passthrough guest diagnostic
#
# Runs inside the GUEST VM to check NVIDIA GPU health/visibility.
# Produces both human-readable output (stdout) and a machine-readable
# JSON summary (written to $JSON_OUT, default ./gpu-diag-report.json).
#
# Exit codes:
#   0  = no problems detected
#   1  = warnings found (degraded but usable)
#   2  = critical problems found (GPU not usable / driver not loaded)
#   3  = script error (missing tools etc.)
#
# Usage: sudo ./gpu-diag.sh [output.json]
# this has been used and tested on consumer nvidia 3000 series cards and RTX4000 series enterprise cards; however it's still pending testing on other generations (RTX 4000, 5000, Blackwell 60000, etc)

set -uo pipefail

JSON_OUT="${1:-./gpu-diag-report.json}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"

# Severity tracking: 0=ok 1=warn 2=critical
SEVERITY=0
declare -a FINDINGS=()   # each entry: "LEVEL|check|message"

# ---- helpers ---------------------------------------------------------

note() {
  local level="$1" check="$2" msg="$3"
  FINDINGS+=("${level}|${check}|${msg}")
  case "$level" in
    CRIT) [ "$SEVERITY" -lt 2 ] && SEVERITY=2 ;;
    WARN) [ "$SEVERITY" -lt 1 ] && SEVERITY=1 ;;
  esac
  printf '[%s] %-10s %s\n' "$level" "$check" "$msg"
}

hr() { printf '%s\n' "----------------------------------------------------------------"; }
section() { echo; hr; echo "== $1"; hr; }

have() { command -v "$1" >/dev/null 2>&1; }

# JSON string escape (basic)
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }

# ---- checks ------------------------------------------------------------

section "PCI: NVIDIA device presence"
# lspci -k prints one block per PCI function (header line "BB:DD.F ..." then
# indented detail lines). Keep only the blocks whose header names NVIDIA, so a
# neighbouring device's "Kernel driver in use" is never mistaken for the GPU's.
PCI_NVIDIA="$(lspci -nnk 2>/dev/null | awk '/^[0-9a-fA-F:.]+ /{keep=(tolower($0) ~ /nvidia/)} keep')"
if [ -z "$PCI_NVIDIA" ]; then
  note CRIT pci "No NVIDIA PCI device visible to guest"
else
  echo "$PCI_NVIDIA"
  NVIDIA_COUNT="$(printf '%s\n' "$PCI_NVIDIA" | grep -cE '^[0-9a-fA-F:.]+ ')"
  note INFO pci "Found ${NVIDIA_COUNT} NVIDIA PCI function(s)"
  # Judge only the GPU itself (PCI class 03xx: VGA/3D controller). Companion
  # functions (HDMI audio 0403, USB-C 0c03) legitimately bind other drivers.
  GPU_FUNCS="$(printf '%s\n' "$PCI_NVIDIA" | grep -cE '^[0-9a-fA-F:.]+ .*\[03[0-9a-fA-F]{2}\]')"
  if [ "$GPU_FUNCS" -eq 0 ]; then
    GPU_BLOCKS="$PCI_NVIDIA"        # no class info (old lspci?) - judge every NVIDIA function
    GPU_FUNCS="$NVIDIA_COUNT"
  else
    GPU_BLOCKS="$(printf '%s\n' "$PCI_NVIDIA" | awk '/^[0-9a-fA-F:.]+ /{keep=($0 ~ /\[03[0-9a-fA-F][0-9a-fA-F]\]/)} keep')"
  fi
  GPU_DRV="$(printf '%s\n' "$GPU_BLOCKS" | awk -F': ' '/Kernel driver in use:/{print $2}' | sort -u)"
  GPU_BOUND="$(printf '%s\n' "$GPU_BLOCKS" | grep -c 'Kernel driver in use:')"
  if [ -z "$GPU_DRV" ]; then
    note CRIT pci "No kernel driver bound to the NVIDIA GPU (nouveau/nvidia not attached)"
  elif printf '%s\n' "$GPU_DRV" | grep -qvx nvidia; then
    DRV_LIST="$(printf '%s\n' "$GPU_DRV" | paste -sd, -)"
    HINT=""
    printf '%s\n' "$GPU_DRV" | grep -q '^vfio-pci$' && HINT=" (vfio-pci belongs on the hypervisor, not inside the guest)"
    printf '%s\n' "$GPU_DRV" | grep -q '^nouveau$'  && HINT=" (nouveau must be blacklisted for the nvidia driver)"
    note WARN pci "GPU bound to driver(s) other than 'nvidia': ${DRV_LIST}${HINT}"
  elif [ "$GPU_BOUND" -lt "$GPU_FUNCS" ]; then
    note WARN pci "Only ${GPU_BOUND} of ${GPU_FUNCS} NVIDIA GPU function(s) have a kernel driver bound"
  else
    note OK pci "Kernel driver in use: nvidia (${GPU_FUNCS} GPU function[s])"
  fi
fi

section "Kernel module: nvidia"
MOD="$(lsmod 2>/dev/null | grep -i nvidia)"
if [ -z "$MOD" ]; then
  note CRIT module "nvidia kernel module not loaded"
else
  echo "$MOD"
  note OK module "nvidia kernel module loaded"
fi

section "Device nodes: /dev/nvidia*"
DEVNODES="$(ls -l /dev/nvidia* 2>/dev/null)"
if [ -z "$DEVNODES" ]; then
  note CRIT devnode "No /dev/nvidia* device nodes present"
else
  echo "$DEVNODES"
  note OK devnode "/dev/nvidia* nodes present"
fi

section "Driver version"
if [ -r /proc/driver/nvidia/version ]; then
  cat /proc/driver/nvidia/version
  note OK driver "/proc/driver/nvidia/version readable"
else
  note WARN driver "/proc/driver/nvidia/version not readable (driver may not be loaded)"
fi

section "modinfo nvidia"
if have modinfo; then
  modinfo nvidia 2>/dev/null | head -30
else
  note WARN tooling "modinfo not available"
fi

section "dmesg: NVRM / xid / gpu / pcie / aer / fallen off / error"
DMESG_HITS="$(dmesg -T 2>/dev/null | grep -iE 'nvrm|nvidia|xid|gpu|pcie|aer|fallen off|error')"
if [ -n "$DMESG_HITS" ]; then
  echo "$DMESG_HITS" | tail -100
  XID_HITS="$(echo "$DMESG_HITS" | grep -ic 'xid')"
  FALLEN_HITS="$(echo "$DMESG_HITS" | grep -ic 'fallen off')"
  if [ "$FALLEN_HITS" -gt 0 ]; then
    note CRIT dmesg "GPU 'fallen off the bus' detected (${FALLEN_HITS} occurrence[s])"
  fi
  if [ "$XID_HITS" -gt 0 ]; then
    note WARN dmesg "Xid error(s) found in dmesg (${XID_HITS} occurrence[s]) — check codes"
  fi
  if [ "$FALLEN_HITS" -eq 0 ] && [ "$XID_HITS" -eq 0 ]; then
    note OK dmesg "No Xid / fallen-off-bus events found"
  fi
else
  note INFO dmesg "No matching dmesg lines (or dmesg unavailable/empty ring buffer)"
fi

section "journalctl -k: NVRM / xid / gpu / pcie / aer / fallen off / error"
if have journalctl; then
  timeout 30 journalctl -k --no-pager -q 2>/dev/null | grep -iE 'nvrm|nvidia|xid|gpu|pcie|aer|fallen off|error' | tail -100
  if [ $? -eq 124 ]; then
    note WARN tooling "journalctl -k timed out after 30s (large journal) — skipped"
  fi
else
  note WARN tooling "journalctl not available"
fi

section "journalctl: cuda / nvidia / nvrm / xid / gpu (last 7 days)"
if have journalctl; then
  timeout 30 journalctl --no-pager -q --since "7 days ago" 2>/dev/null | grep -iE 'cuda|nvidia|nvrm|xid|gpu' | tail -100
  if [ $? -eq 124 ]; then
    note WARN tooling "journalctl (full) timed out after 30s (large journal) — skipped"
  fi
fi

section "Processes using GPU-related tools"
ps aux 2>/dev/null | grep -iE 'cuda|python|torch|tensorflow|nvidia' | grep -v grep

section "Open handles on /dev/nvidia*"
if have fuser; then
  fuser -v /dev/nvidia* 2>/dev/null
fi
if have lsof; then
  lsof /dev/nvidia* 2>/dev/null
fi

# ---- nvidia-smi checks ---------------------------------------------

section "nvidia-smi: base enumeration"
if have nvidia-smi; then
  if nvidia-smi >/tmp/gpu-diag-smi.$$  2>&1; then
    cat /tmp/gpu-diag-smi.$$
    note OK smi "nvidia-smi ran successfully"
  else
    cat /tmp/gpu-diag-smi.$$
    note CRIT smi "nvidia-smi failed to run (driver/device communication failure)"
  fi
  rm -f /tmp/gpu-diag-smi.$$
else
  note CRIT smi "nvidia-smi binary not found (driver/toolkit not installed)"
fi

if have nvidia-smi; then

  section "nvidia-smi: ECC / page retirement"
  ECC_OUT="$(nvidia-smi -q -d ECC,PAGE_RETIREMENT 2>&1)"
  echo "$ECC_OUT"
  if echo "$ECC_OUT" | grep -qiE 'Double Bit.*: *[1-9]'; then
    note CRIT ecc "Uncorrectable (double-bit) ECC errors detected"
  fi
  if echo "$ECC_OUT" | grep -qiE 'Pending *: *Yes'; then
    note WARN ecc "Pending retired pages / ECC action pending (reboot recommended)"
  fi
  if echo "$ECC_OUT" | grep -qiE 'Single Bit.*: *[1-9]'; then
    note WARN ecc "Correctable (single-bit) ECC errors present"
  fi

  section "nvidia-smi: performance / throttle reasons"
  PERF_OUT="$(nvidia-smi -q -d PERFORMANCE 2>&1)"
  echo "$PERF_OUT"
  if echo "$PERF_OUT" | grep -qiE 'HW Slowdown *: *Active|HW Thermal Slowdown *: *Active|SW Thermal Slowdown *: *Active'; then
    note CRIT throttle "Hardware/thermal slowdown currently ACTIVE"
  elif echo "$PERF_OUT" | grep -qiE 'SW Power Cap *: *Active'; then
    note WARN throttle "SW power cap throttling active"
  fi

  section "nvidia-smi: temperature / power"
  nvidia-smi -q -d TEMPERATURE,POWER 2>&1

  section "nvidia-smi: clocks"
  nvidia-smi -q -d CLOCK 2>&1

  section "nvidia-smi: topology"
  nvidia-smi topo -m 2>&1

  section "nvidia-smi: CSV summary (machine-parseable)"
  CSV_OUT="$(nvidia-smi --query-gpu=index,name,pci.bus_id,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,utilization.gpu,memory.used,memory.total,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,retired_pages.sbe,retired_pages.dbe,persistence_mode --format=csv 2>&1)"
  echo "$CSV_OUT"

  section "nvidia-smi: supported clocks"
  nvidia-smi -q -d SUPPORTED_CLOCKS 2>&1 | head -60
fi

# ---- JSON output -----------------------------------------------------

{
  echo "{"
  echo "  \"timestamp\": \"${TS}\","
  echo "  \"hostname\": \"$(jesc "$HOSTNAME_")\","
  echo "  \"severity\": ${SEVERITY},"
  echo "  \"severity_label\": \"$( [ $SEVERITY -eq 0 ] && echo ok || { [ $SEVERITY -eq 1 ] && echo warn || echo critical; } )\","
  echo "  \"findings\": ["
  n=${#FINDINGS[@]}
  i=0
  for f in "${FINDINGS[@]}"; do
    i=$((i+1))
    level="${f%%|*}"; rest="${f#*|}"
    check="${rest%%|*}"; msg="${rest#*|}"
    comma=","
    [ "$i" -eq "$n" ] && comma=""
    printf '    {"level": "%s", "check": "%s", "message": "%s"}%s\n' \
      "$(jesc "$level")" "$(jesc "$check")" "$(jesc "$msg")" "$comma"
  done
  echo "  ],"
  if have nvidia-smi; then
    echo "  \"nvidia_smi_csv\": \"$(jesc "${CSV_OUT:-}")\""
  else
    echo "  \"nvidia_smi_csv\": null"
  fi
  echo "}"
} > "$JSON_OUT"

section "SUMMARY"
echo "Severity: ${SEVERITY} ($( [ $SEVERITY -eq 0 ] && echo OK || { [ $SEVERITY -eq 1 ] && echo WARNINGS || echo CRITICAL; } ))"
echo "Findings: ${#FINDINGS[@]}"
echo "JSON report written to: ${JSON_OUT}"

exit "$SEVERITY"
