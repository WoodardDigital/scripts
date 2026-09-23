#!/usr/bin/env bash
#
# gpu-diag.sh — GPU passthrough guest diagnostic
#
# Runs inside the GUEST VM (the workload node) to check NVIDIA GPU
# health/visibility. Produces both human-readable output (stdout) and a
# machine-readable JSON summary (written to $JSON_OUT, default
# ./gpu-diag-report.json).
#
# Sections:
#   host baseline · PCI presence/driver · PCIe link & AER · kernel module ·
#   device nodes · driver version · modinfo · dmesg (this boot) ·
#   kernel journal events (all retained boots, with context) ·
#   user-space journal warnings (7 days) · processes & handles ·
#   container runtime integration (containerd / NVIDIA toolkit) ·
#   nvidia-smi: enumeration, ECC, row remapper, throttle, thermals, clocks,
#   topology, per-GPU query
#
# JSON: { timestamp, hostname, severity, severity_label, findings[],
#         sources[], host{}, pcie[], events{}, gpus[] }
#
# Every section prints the command(s) it ran as "$ ..." lines above the output.
#
# Exit codes:
#   0  = no problems detected
#   1  = warnings found (degraded but usable)
#   2  = critical problems found (GPU not usable / driver not loaded)
#   3  = script error (missing tools etc.)
#
# Usage: sudo ./gpu-diag.sh [output.json]
# Tested on consumer RTX 3000 series and RTX 4000 Ada; other generations
# (RTX 5000, Blackwell) still pending testing.

set -uo pipefail

JSON_OUT="${1:-./gpu-diag-report.json}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-30}"

# Severity tracking: 0=ok 1=warn 2=critical
SEVERITY=0
US=$'\x1f'              # field separator inside FINDINGS entries (commands contain '|')
declare -a FINDINGS=()   # each entry: "LEVEL<US>check<US>message<US>command(s)"
declare -a SOURCES=()    # each entry: "check|command", filled by src()

TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t gpu-diag)"
trap 'rm -rf "$TMPD"' EXIT

# ---- helpers ---------------------------------------------------------

# commands recorded so far for a check, joined with "; "
cmds_for() {
  local c="$1" e out=""
  for e in "${SOURCES[@]+"${SOURCES[@]}"}"; do
    [ "${e%%|*}" = "$c" ] && out="${out:+$out; }${e#*|}"
  done
  printf '%s' "$out"
}

note() {
  local level="$1" check="$2" msg="$3"
  FINDINGS+=("${level}${US}${check}${US}${msg}${US}$(cmds_for "$check")")
  case "$level" in
    CRIT) [ "$SEVERITY" -lt 2 ] && SEVERITY=2 ;;
    WARN) [ "$SEVERITY" -lt 1 ] && SEVERITY=1 ;;
  esac
  printf '[%s] %-10s %s\n' "$level" "$check" "$msg"
}

hr() { printf '%s\n' "----------------------------------------------------------------"; }
section() { echo; hr; echo "== $1"; hr; }

have() { command -v "$1" >/dev/null 2>&1; }

# run with a timeout if the timeout tool exists, otherwise plainly
tmo() { if have timeout; then timeout "$JOURNAL_TIMEOUT" "$@"; else "$@"; fi; }

# JSON string escape (basic); newlines become spaces
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
# JSON value: bare number if numeric, else quoted string; empty -> null
jval() {
  local v="$1"
  if [ -z "$v" ]; then printf 'null'
  elif printf '%s' "$v" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then printf '%s' "$v"
  else printf '"%s"' "$(jesc "$v")"; fi
}
# join lines with a separator
joinl() { paste -sd "$1" - ; }
# src <check> <command text>: print the command that produced the output that
# follows ("$ cmd") and remember it; every finding made for that check carries
# the commands recorded so far (JSON "command"), and the JSON "sources" list
# has them all.
src() { SOURCES+=("$1|$2"); printf '$ %s\n' "$2"; }
# split `nvidia-smi -q` output (stdin) into one file per GPU block ($TMPD/<prefix>.N,
# first line "GPU <bus id>") and print the file names. A VM may have several GPUs;
# every per-GPU check must loop over these instead of grepping the whole output.
split_gpu_blocks() {
  rm -f "$TMPD/$1".* 2>/dev/null
  awk -v p="$TMPD/$1" '/^GPU [0-9a-fA-F:.]+$/ {n++; f=p"."n} n>0 {print > f}'
  ls "$TMPD/$1".* 2>/dev/null
}
gpu_of() { head -1 "$1" | awk '{print $2}'; }

# ---- host baseline ---------------------------------------------------------

section "Host baseline"
src baseline ". /etc/os-release; uname -rm; cat /proc/uptime /proc/sys/kernel/random/boot_id /proc/cmdline; systemd-detect-virt; nproc; grep MemTotal /proc/meminfo; cat /sys/module/nvidia/version; modinfo -F vermagic nvidia"
HOST_OS="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" )"
HOST_KERNEL="$(uname -r 2>/dev/null)"
HOST_ARCH="$(uname -m 2>/dev/null)"
HOST_UPTIME_S="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
HOST_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
HOST_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
[ -z "$HOST_VIRT" ] && HOST_VIRT="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | joinl ' ')"
HOST_CMDLINE="$(cat /proc/cmdline 2>/dev/null)"
HOST_CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
HOST_MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
NV_MOD_VER="$(cat /sys/module/nvidia/version 2>/dev/null)"
NV_VERMAGIC="$(modinfo -F vermagic nvidia 2>/dev/null | awk '{print $1}')"

printf '%-15s %s\n' "OS:" "${HOST_OS:-unknown}"
printf '%-15s %s (%s)\n' "Kernel:" "${HOST_KERNEL:-unknown}" "${HOST_ARCH:-?}"
printf '%-15s %s\n' "Virtualization:" "${HOST_VIRT:-unknown}"
printf '%-15s %s s (boot id %s)\n' "Uptime:" "${HOST_UPTIME_S:-?}" "${HOST_BOOT_ID:-?}"
printf '%-15s %s vCPU, %s MiB RAM\n' "Resources:" "${HOST_CPUS:-?}" "${HOST_MEM_MB:-?}"
printf '%-15s %s\n' "Cmdline:" "${HOST_CMDLINE:-unknown}"
printf '%-15s %s (vermagic %s)\n' "nvidia module:" "${NV_MOD_VER:-not loaded}" "${NV_VERMAGIC:-?}"
if [ -n "$NV_VERMAGIC" ] && [ -n "$HOST_KERNEL" ] && [ "$NV_VERMAGIC" != "$HOST_KERNEL" ]; then
  note WARN baseline "nvidia module vermagic ${NV_VERMAGIC} does not match running kernel ${HOST_KERNEL}"
fi
src baseline "lsmod | grep '^nouveau'; grep -rlE 'blacklist +nouveau' /etc/modprobe.d /usr/lib/modprobe.d"
if lsmod 2>/dev/null | grep -q '^nouveau'; then
  note WARN baseline "nouveau kernel module is loaded (conflicts with the nvidia driver)"
fi
BLACKLIST="$(grep -rlsE '^[[:space:]]*blacklist[[:space:]]+nouveau' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null | joinl ',')"
if [ -n "$BLACKLIST" ]; then printf '%-15s blacklisted in %s\n' "nouveau:" "$BLACKLIST"; else printf '%-15s no blacklist entry found\n' "nouveau:"; fi
echo "Driver packages:"
if have dpkg-query; then
  src baseline "dpkg-query -W -f='\${Package} \${Version} \${db:Status-Abbrev}' 'nvidia*' 'libnvidia*' 'cuda*' 'nvidia-container*'"
  dpkg-query -W -f='  ${Package} ${Version} ${db:Status-Abbrev}\n' 'nvidia*' 'libnvidia*' 'cuda*' 'nvidia-container*' 2>/dev/null | grep -E ' (ii|hi) *$' | head -25
elif have rpm; then
  src baseline "rpm -qa 'nvidia*' 'cuda*' 'libnvidia*'"
  rpm -qa 'nvidia*' 'cuda*' 'libnvidia*' 2>/dev/null | sed 's/^/  /' | head -25
else
  echo "  (no dpkg/rpm)"
fi
note INFO baseline "${HOST_OS:-unknown OS}, kernel ${HOST_KERNEL:-?}, ${HOST_VIRT:-unknown virt}, up ${HOST_UPTIME_S:-?}s"

# ---- PCI ------------------------------------------------------------------

section "PCI: NVIDIA device presence"
# lspci -k prints one block per PCI function (header line "BB:DD.F ..." then
# indented detail lines). Keep only the blocks whose header names NVIDIA, so a
# neighbouring device's "Kernel driver in use" is never mistaken for the GPU's.
src pci "lspci -nnk   # keeping only the blocks whose header line mentions NVIDIA"
PCI_NVIDIA="$(lspci -nnk 2>/dev/null | awk '/^[0-9a-fA-F:.]+ /{keep=(tolower($0) ~ /nvidia/)} keep')"
GPU_BDFS=""
if [ -z "$PCI_NVIDIA" ]; then
  if have lspci; then
    note CRIT pci "No NVIDIA PCI device visible to guest"
  else
    src tooling "command -v lspci"
    note WARN tooling "lspci not available (install pciutils); PCI checks skipped"
  fi
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
  GPU_BDFS="$(printf '%s\n' "$GPU_BLOCKS" | grep -oE '^[0-9a-fA-F:.]+ ' | tr -d ' ')"
  GPU_DRV="$(printf '%s\n' "$GPU_BLOCKS" | awk -F': ' '/Kernel driver in use:/{print $2}' | sort -u)"
  GPU_BOUND="$(printf '%s\n' "$GPU_BLOCKS" | grep -c 'Kernel driver in use:')"
  if [ -z "$GPU_DRV" ]; then
    note CRIT pci "No kernel driver bound to the NVIDIA GPU (nouveau/nvidia not attached)"
  elif printf '%s\n' "$GPU_DRV" | grep -qvx nvidia; then
    DRV_LIST="$(printf '%s\n' "$GPU_DRV" | joinl ,)"
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

# ---- PCIe link / AER per GPU -------------------------------------------------

section "PCIe link / AER per GPU (guest view)"
PCIE_JSON=""
if [ -z "$GPU_BDFS" ]; then
  echo "(no NVIDIA GPU function to inspect)"
else
  for bdf in $GPU_BDFS; do
    src pcie "lspci -vv -s $bdf   # LnkCap/LnkSta, UESta/CESta, Region lines"
    VV="$(lspci -vv -s "$bdf" 2>/dev/null)"
    [ -n "$VV" ] || { echo "$bdf: lspci -vv returned nothing (need root?)"; continue; }
    LNKCAP="$(printf '%s\n' "$VV" | grep -m1 'LnkCap:')"
    LNKSTA="$(printf '%s\n' "$VV" | grep -m1 'LnkSta:')"
    UESTA="$(printf '%s\n' "$VV" | grep -m1 'UESta:')"
    CESTA="$(printf '%s\n' "$VV" | grep -m1 'CESta:')"
    REGIONS="$(printf '%s\n' "$VV" | grep -E '^[[:space:]]*Region [0-9]+:')"
    cap_speed="$(printf '%s' "$LNKCAP" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}')"
    cap_width="$(printf '%s' "$LNKCAP" | grep -oE 'Width x[0-9]+' | awk '{print $2}')"
    sta_speed="$(printf '%s' "$LNKSTA" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}')"
    sta_width="$(printf '%s' "$LNKSTA" | grep -oE 'Width x[0-9]+' | awk '{print $2}')"
    ue_flags="$(printf '%s' "$UESTA" | grep -oE '[A-Za-z]+\+' | tr -d '+' | joinl ,)"
    ce_flags="$(printf '%s' "$CESTA" | grep -oE '[A-Za-z]+\+' | tr -d '+' | joinl ,)"
    bad_bars="$(printf '%s\n' "$REGIONS" | grep -ciE 'virtual|ignored|unassigned|disabled')"
    echo "$bdf"
    printf '  %-8s cap %s %s / now %s %s\n' "Link:" "${cap_speed:-?}" "${cap_width:-?}" "${sta_speed:-?}" "${sta_width:-?}"
    if [ -n "$UESTA" ]; then printf '  %-8s %s\n' "UESta:" "${ue_flags:-none set}"; else printf '  %-8s not exposed\n' "UESta:"; fi
    if [ -n "$CESTA" ]; then printf '  %-8s %s\n' "CESta:" "${ce_flags:-none set}"; else printf '  %-8s not exposed\n' "CESta:"; fi
    printf '%s\n' "$REGIONS" | sed 's/^[[:space:]]*/  /'
    if [ "${bad_bars:-0}" -gt 0 ]; then
      printf '%s\n' "$REGIONS" | grep -iE 'virtual|ignored|unassigned|disabled' | sed 's/^[[:space:]]*/  !! /'
    fi

    if [ -z "$LNKSTA" ]; then
      note INFO pcie "$bdf: link status not exposed to the guest"
    else
      if [ -n "$cap_width" ] && [ -n "$sta_width" ] && [ "$cap_width" != "$sta_width" ]; then
        note WARN pcie "$bdf: PCIe link width ${sta_width} of ${cap_width} (degraded link)"
      fi
      if [ -n "$cap_speed" ] && [ -n "$sta_speed" ] && [ "$cap_speed" != "$sta_speed" ]; then
        note INFO pcie "$bdf: link speed ${sta_speed} of ${cap_speed} (normal at idle; verify under load)"
      fi
      if [ -n "$cap_width" ] && [ "$cap_width" = "$sta_width" ] && [ "$cap_speed" = "$sta_speed" ]; then
        note OK pcie "$bdf: link at full ${sta_speed} ${sta_width}"
      fi
    fi
    [ -n "$ue_flags" ] && note WARN pcie "$bdf: uncorrectable AER status flags latched: ${ue_flags}"
    [ -n "$ce_flags" ] && note INFO pcie "$bdf: correctable AER status flags latched: ${ce_flags}"
    [ -z "$UESTA" ] && note INFO pcie "$bdf: AER capability not exposed to the guest (hypervisor owns it)"
    [ "${bad_bars:-0}" -gt 0 ] && note CRIT pcie "$bdf: ${bad_bars} BAR(s) unassigned/disabled (device memory not mapped)"

    aer_exposed=false; [ -n "$UESTA" ] && aer_exposed=true
    PCIE_JSON="${PCIE_JSON:+$PCIE_JSON,}{\"bdf\":\"$(jesc "$bdf")\",\"link_cap_speed\":$(jval "$cap_speed"),\"link_cap_width\":$(jval "$cap_width"),\"link_speed\":$(jval "$sta_speed"),\"link_width\":$(jval "$sta_width"),\"aer_exposed\":${aer_exposed},\"aer_uncorrectable_flags\":$(jval "$ue_flags"),\"aer_correctable_flags\":$(jval "$ce_flags"),\"bars_unassigned\":${bad_bars:-0}}"
  done
fi

# ---- kernel module / device nodes / driver -----------------------------------

section "Kernel module: nvidia"
src module "lsmod | grep -i nvidia"
MOD="$(lsmod 2>/dev/null | grep -i nvidia)"
if [ -z "$MOD" ]; then
  note CRIT module "nvidia kernel module not loaded"
else
  echo "$MOD"
  note OK module "nvidia kernel module loaded"
fi

section "Device nodes: /dev/nvidia*"
src devnode "ls -l /dev/nvidia*"
DEVNODES="$(ls -l /dev/nvidia* 2>/dev/null)"
if [ -z "$DEVNODES" ]; then
  note CRIT devnode "No /dev/nvidia* device nodes present"
else
  echo "$DEVNODES"
  note OK devnode "/dev/nvidia* nodes present"
fi

section "Driver version"
src driver "cat /proc/driver/nvidia/version"
if [ -r /proc/driver/nvidia/version ]; then
  cat /proc/driver/nvidia/version
  note OK driver "/proc/driver/nvidia/version readable"
else
  note WARN driver "/proc/driver/nvidia/version not readable (driver may not be loaded)"
fi

section "modinfo nvidia"
if have modinfo; then
  src driver "modinfo nvidia | head -30"
  modinfo nvidia 2>/dev/null | head -30
else
  note WARN tooling "modinfo not available"
fi

# ---- kernel logs -----------------------------------------------------------------

# Event patterns (used case-insensitively)
P_XID='NVRM: Xid'
P_FALLEN='fallen off the bus'
P_AER='AER:|PCIe Bus Error|Uncorrected \((Non-)?Fatal\)'
P_INITFAIL='Rm_?Init_?Adapter failed|failed to initialize the NVIDIA|NVRM: .*No NVIDIA .*found'
P_KERNEL_INTEREST='nvrm|nvidia|nouveau|xid|fallen off|aer:|pcieport|pcie bus error|pci.*(error|failed)'

section "dmesg (this boot): NVRM / Xid / PCIe / AER"
src dmesg "dmesg -T | grep -iE '${P_KERNEL_INTEREST}' | tail -100"
SOURCES+=("events|dmesg -T | grep -ciE '<pattern>'   # this-boot counts for Xid / fallen off / AER / driver init")
DMESG_ALL="$(dmesg -T 2>/dev/null || dmesg 2>/dev/null)"
DMESG_HITS="$(printf '%s\n' "$DMESG_ALL" | grep -iE "$P_KERNEL_INTEREST")"
if [ -z "$DMESG_ALL" ]; then
  note INFO dmesg "dmesg unavailable (no permission or empty ring buffer)"
elif [ -n "$DMESG_HITS" ]; then
  printf '%s\n' "$DMESG_HITS" | tail -100
else
  echo "(no matching lines)"
fi
CUR_XID="$(printf '%s\n' "$DMESG_ALL" | grep -ciE "$P_XID")"
CUR_FALLEN="$(printf '%s\n' "$DMESG_ALL" | grep -ciE "$P_FALLEN")"
CUR_AER="$(printf '%s\n' "$DMESG_ALL" | grep -ciE "$P_AER")"
CUR_INITFAIL="$(printf '%s\n' "$DMESG_ALL" | grep -ciE "$P_INITFAIL")"

section "journal: kernel GPU events (all retained boots)"
KJ="$TMPD/kjournal"
JOURNAL_OK=false
if have journalctl; then
  src events "journalctl -k --no-pager -q -o short-iso   # all retained boots; counted with: Xid='${P_XID}' fallen='${P_FALLEN}' AER='${P_AER}' init='${P_INITFAIL}' (this-boot counts come from dmesg above)"
  if tmo journalctl -k --no-pager -q -o short-iso > "$KJ" 2>/dev/null; then
    JOURNAL_OK=true
  else
    rc=$?
    [ "$rc" -eq 124 ] && note WARN tooling "journalctl -k timed out after ${JOURNAL_TIMEOUT}s (large journal); kernel event history skipped"
  fi
else
  note WARN tooling "journalctl not available; kernel event history limited to this boot (dmesg)"
fi

# event totals across retention (falls back to this boot's dmesg when no journal)
EV_xid_TOTAL=0;       EV_xid_LAST=""
EV_fallenoff_TOTAL=0; EV_fallenoff_LAST=""
EV_aer_TOTAL=0;       EV_aer_LAST=""
EV_initfail_TOTAL=0;  EV_initfail_LAST=""
summarize_event() {
  # $1 var-suffix, $2 label, $3 pattern, $4 this-boot count
  local key="$1" label="$2" pat="$3" cur="$4" total last
  if [ "$JOURNAL_OK" = true ]; then
    total="$(grep -ciE "$pat" "$KJ")"
    last="$(grep -iE "$pat" "$KJ" | tail -1 | awk '{print $1}')"
  else
    total="$cur"
    last=""
    [ "$cur" -gt 0 ] && last="$(printf '%s\n' "$DMESG_ALL" | grep -iE "$pat" | tail -1 | grep -oE '^\[[^]]*\]')"
  fi
  printf '  %-18s total %-5s this boot %-5s last: %s\n' "$label" "${total:-0}" "${cur:-0}" "${last:-none}"
  eval "EV_${key}_TOTAL=\${total:-0}; EV_${key}_LAST=\${last:-}"
}
echo "Event summary:"
summarize_event xid       "Xid"            "$P_XID"      "$CUR_XID"
summarize_event fallenoff "fallen off bus" "$P_FALLEN"   "$CUR_FALLEN"
summarize_event aer       "PCIe AER"       "$P_AER"      "$CUR_AER"
summarize_event initfail  "driver init"    "$P_INITFAIL" "$CUR_INITFAIL"
xid_source() { if [ "$JOURNAL_OK" = true ]; then cat "$KJ"; else printf '%s\n' "$DMESG_ALL"; fi; }
XID_CODES="$(xid_source | grep -iE "$P_XID" | grep -oE 'Xid \([^)]*\): [0-9]+' | awk '{print $NF}' | sort | uniq -c | sort -rn | awk '{printf "%s(x%s) ", $2, $1}' | sed 's/ *$//')"
[ -n "$XID_CODES" ] && echo "  Xid codes: ${XID_CODES}"

if [ "$JOURNAL_OK" = true ]; then
  echo
  src events "journalctl --list-boots; journalctl --disk-usage"
  echo "Journal: $(journalctl --list-boots --no-pager -q 2>/dev/null | wc -l | tr -d ' ') boot(s) retained; $(journalctl --disk-usage 2>/dev/null | sed 's/Archived and active journals take up //')"
  echo
  echo "Matching kernel lines (last 100 across retention):"
  src events "journalctl -k -o short-iso | grep -iE '${P_KERNEL_INTEREST}' | tail -100"
  grep -iE "$P_KERNEL_INTEREST" "$KJ" | tail -100
  # context around the most recent Xid / fallen-off events
  CTX_LINES="$(grep -niE "$P_XID|$P_FALLEN" "$KJ" | tail -3 | cut -d: -f1)"
  if [ -n "$CTX_LINES" ]; then
    echo
    echo "Context around the most recent Xid / fallen-off events:"
    for n in $CTX_LINES; do
      s=$((n-3)); [ "$s" -lt 1 ] && s=1
      echo "  --- line $n"
      sed -n "${s},$((n+5))p" "$KJ" | sed 's/^/  /'
    done
  fi
fi

# findings from events: this boot => real severity; only in earlier boots => informational
if [ "${CUR_FALLEN:-0}" -gt 0 ]; then
  note CRIT events "GPU 'fallen off the bus' this boot (${CUR_FALLEN} occurrence[s])"
elif [ "${EV_fallenoff_TOTAL:-0}" -gt 0 ]; then
  note WARN events "GPU 'fallen off the bus' in earlier boot(s): ${EV_fallenoff_TOTAL} occurrence[s], last ${EV_fallenoff_LAST}"
fi
if [ "${CUR_XID:-0}" -gt 0 ]; then
  note WARN events "Xid error(s) this boot: ${CUR_XID} — codes ${XID_CODES:-?}"
elif [ "${EV_xid_TOTAL:-0}" -gt 0 ]; then
  note INFO events "Xid error(s) in earlier boot(s): ${EV_xid_TOTAL}, last ${EV_xid_LAST} — codes ${XID_CODES:-?}"
fi
if [ "${CUR_INITFAIL:-0}" -gt 0 ]; then
  note CRIT events "NVIDIA driver failed to initialize the GPU this boot (${CUR_INITFAIL} message[s])"
elif [ "${EV_initfail_TOTAL:-0}" -gt 0 ]; then
  note INFO events "driver init failures in earlier boot(s): ${EV_initfail_TOTAL}, last ${EV_initfail_LAST}"
fi
if [ "${CUR_AER:-0}" -gt 0 ]; then
  note WARN events "PCIe AER error(s) this boot: ${CUR_AER}"
elif [ "${EV_aer_TOTAL:-0}" -gt 0 ]; then
  note INFO events "PCIe AER error(s) in earlier boot(s): ${EV_aer_TOTAL}, last ${EV_aer_LAST}"
fi
if [ "${CUR_FALLEN:-0}" -eq 0 ] && [ "${CUR_XID:-0}" -eq 0 ] && [ "${CUR_INITFAIL:-0}" -eq 0 ] && [ "${CUR_AER:-0}" -eq 0 ]; then
  note OK events "No Xid / fallen-off-bus / init-failure / AER events this boot"
fi

section "journal: user-space warnings+ mentioning NVIDIA/CUDA (last 7 days)"
UJ_COUNT=0
if have journalctl; then
  UJ="$TMPD/ujournal"
  src journal "journalctl --no-pager -q -o short-iso --since '7 days ago' -p warning | grep -v ' kernel: ' | grep -iE 'cuda|nvidia|nvrm|xid|nvml|dcgm|gpu-operator|device-plugin|nvidia\.com/gpu' | tail -100"
  if tmo journalctl --no-pager -q -o short-iso --since "7 days ago" -p warning > "$UJ" 2>/dev/null; then
    grep -v ' kernel: ' "$UJ" | grep -iE 'cuda|nvidia|nvrm|xid|nvml|dcgm|gpu-operator|device-plugin|nvidia\.com/gpu' > "$UJ.hits" || true
    UJ_COUNT="$(wc -l < "$UJ.hits" | tr -d ' ')"
    if [ "$UJ_COUNT" -gt 0 ]; then
      tail -100 "$UJ.hits"
      note INFO journal "${UJ_COUNT} warning-or-worse user-space line(s) mention NVIDIA/CUDA in the last 7 days (see log)"
    else
      echo "(none)"
    fi
  else
    rc=$?
    [ "$rc" -eq 124 ] && note WARN tooling "journalctl (user-space) timed out after ${JOURNAL_TIMEOUT}s; skipped"
  fi
fi

# ---- processes / handles -----------------------------------------------------------

section "Processes using GPU-related tools"
src processes "ps aux | grep -iE 'cuda|python|torch|tensorflow|nvidia'"
ps aux 2>/dev/null | grep -iE 'cuda|python|torch|tensorflow|nvidia' | grep -v grep

section "Open handles on /dev/nvidia*"
if have fuser; then
  src handles "fuser -v /dev/nvidia*"
  fuser -v /dev/nvidia* 2>/dev/null
fi
if have lsof; then
  src handles "lsof /dev/nvidia*"
  lsof /dev/nvidia* 2>/dev/null
fi

# ---- container runtime integration ----------------------------------------------------

section "Container runtime: containerd / NVIDIA Container Toolkit"
src runtime "command -v containerd; ls /etc/containerd/config.toml /var/lib/rancher/{k3s,rke2}/agent/etc/containerd/config.toml"
CT_CFG="${CONTAINERD_CONFIG:-}"
if [ -z "$CT_CFG" ]; then
  for f in /etc/containerd/config.toml /var/lib/rancher/k3s/agent/etc/containerd/config.toml /var/lib/rancher/rke2/agent/etc/containerd/config.toml; do
    [ -r "$f" ] && { CT_CFG="$f"; break; }
  done
fi
if [ -z "$CT_CFG" ] && ! have containerd; then
  echo "containerd not present; skipping (not a Kubernetes node, or a different runtime)"
  note INFO runtime "containerd not present; runtime integration checks skipped"
else
  echo "containerd config: ${CT_CFG:-not found}"
  if [ -n "$CT_CFG" ]; then
    CT_DIR="$(dirname "$CT_CFG")"
    CT_FILES="$CT_CFG $(ls "$CT_DIR"/conf.d/*.toml 2>/dev/null | tr '\n' ' ')"
    src runtime "grep -nHE 'default_runtime_name|runtimes\.nvidia|nvidia-container-runtime|BinaryName' $CT_FILES"
    # shellcheck disable=SC2086
    grep -nHE 'default_runtime_name|runtimes\.nvidia|nvidia-container-runtime|BinaryName' $CT_FILES 2>/dev/null | head -20
    # shellcheck disable=SC2086
    if grep -qsE 'runtimes\.nvidia|nvidia-container-runtime' $CT_FILES 2>/dev/null; then
      # shellcheck disable=SC2086
      # conf.d drop-ins are imported after the main file, so the last match wins
      DEF_RT="$(grep -shE 'default_runtime_name' $CT_FILES 2>/dev/null | tail -1 | sed 's/.*= *//; s/"//g')"
      note OK runtime "containerd has an nvidia runtime handler (default runtime: ${DEF_RT:-runc/unspecified})"
    else
      note WARN runtime "containerd config has no nvidia runtime handler (NVIDIA Container Toolkit not wired in)"
    fi
  else
    note WARN runtime "containerd present but no config.toml found at the usual paths"
  fi
  NCCLI=""
  for c in "$(command -v nvidia-container-cli 2>/dev/null)" /usr/local/nvidia/toolkit/nvidia-container-cli /usr/bin/nvidia-container-cli; do
    [ -n "$c" ] && [ -x "$c" ] && { NCCLI="$c"; break; }
  done
  if [ -n "$NCCLI" ]; then
    echo; src runtime "$NCCLI info   # falls back to --root /run/nvidia/driver when a driver container is present"
    if "$NCCLI" info > "$TMPD/nccli" 2>&1 || { [ -d /run/nvidia/driver/usr ] && "$NCCLI" --root /run/nvidia/driver info > "$TMPD/nccli" 2>&1; }; then
      head -40 "$TMPD/nccli"
      note OK runtime "nvidia-container-cli can see the driver ($(grep -m1 -iE 'NVRM version' "$TMPD/nccli" | sed 's/.*: *//'))"
    else
      head -20 "$TMPD/nccli"
      note WARN runtime "nvidia-container-cli info failed — toolkit cannot query the driver"
    fi
  else
    note WARN runtime "nvidia-container-cli not found (NVIDIA Container Toolkit not installed?)"
  fi
  for f in /etc/nvidia-container-runtime/config.toml /usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml; do
    [ -r "$f" ] && { echo; src runtime "grep -vE '^\s*(#|$)' $f"; grep -vE '^[[:space:]]*(#|$)' "$f" | head -20; }
  done
  if [ -d /usr/local/nvidia/toolkit ]; then
    echo; src runtime "ls -la /usr/local/nvidia/toolkit"; ls -la /usr/local/nvidia/toolkit 2>/dev/null | head -15
  fi
  if [ -d /run/nvidia ]; then
    echo; src runtime "ls -la /run/nvidia"; ls -la /run/nvidia 2>/dev/null | head -10
    [ -d /run/nvidia/driver/usr ] && echo "(driver container root present at /run/nvidia/driver)"
  fi
fi

# ---- nvidia-smi checks ---------------------------------------------

section "nvidia-smi: base enumeration"
SMI_OK=false
if have nvidia-smi; then
  src smi "nvidia-smi"
  if nvidia-smi > "$TMPD/smi" 2>&1; then
    cat "$TMPD/smi"
    note OK smi "nvidia-smi ran successfully"
    SMI_OK=true
  else
    cat "$TMPD/smi"
    note CRIT smi "nvidia-smi failed to run (driver/device communication failure)"
  fi
else
  note CRIT smi "nvidia-smi binary not found (driver/toolkit not installed)"
fi

GPUS_JSON=""
if [ "$SMI_OK" = true ]; then

  section "nvidia-smi: per-GPU query (feeds JSON and the checks below)"
  Q_FULL="index,name,uuid,serial,pci.bus_id,vbios_version,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,utilization.gpu,memory.used,memory.total,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,retired_pages.sbe,retired_pages.dbe,retired_pages.pending,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure,persistence_mode,compute_mode"
  Q_CORE="index,name,pci.bus_id,pstate,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,utilization.gpu,memory.used,memory.total,persistence_mode"
  Q_USED="$Q_FULL"
  if ! nvidia-smi --query-gpu="$Q_FULL" --format=csv,noheader,nounits > "$TMPD/q" 2>/dev/null; then
    Q_USED="$Q_CORE"
    nvidia-smi --query-gpu="$Q_CORE" --format=csv,noheader,nounits > "$TMPD/q" 2>&1 || : > "$TMPD/q"
    note INFO smi "full --query-gpu field set rejected by this nvidia-smi; using core fields"
  fi
  src smi "nvidia-smi --query-gpu=$Q_USED --format=csv,noheader,nounits"
  cat "$TMPD/q"
  # one JSON object per GPU; numeric-looking values become numbers, N/A becomes null, '.' in keys becomes '_'
  GPUS_JSON="$(awk -F', *' -v keys="$Q_USED" '
    BEGIN { n = split(keys, K, ",") }
    NF >= 2 {
      out = "{"
      for (i = 1; i <= n && i <= NF; i++) {
        k = K[i]; gsub(/\./, "_", k)
        v = $i; gsub(/^ +| +$/, "", v); gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
        if (v ~ /^-?[0-9]+(\.[0-9]+)?$/) val = v
        else if (v == "" || v == "[N/A]" || v == "N/A" || v == "[Not Supported]") val = "null"
        else val = "\"" v "\""
        out = out (i > 1 ? "," : "") "\"" k "\":" val
      }
      print out "}"
    }' "$TMPD/q" | joinl ,)"

  # qfield <pci bus id> <field name>: one value from the per-GPU query above
  qfield() {
    awk -F', *' -v keys="$Q_USED" -v bus="$1" -v want="$2" '
      BEGIN { n = split(keys, K, ","); for (i = 1; i <= n; i++) { if (K[i] == "pci.bus_id") bi = i; if (K[i] == want) wi = i } }
      bi && wi && $bi == bus { v = $wi; gsub(/^ +| +$/, "", v); print v; exit }' "$TMPD/q"
  }

  section "nvidia-smi: ECC / page retirement"
  src ecc "nvidia-smi -q -d ECC,PAGE_RETIREMENT"
  ECC_OUT="$(nvidia-smi -q -d ECC,PAGE_RETIREMENT 2>&1)"
  echo "$ECC_OUT"
  ECC_BLOCKS="$(printf '%s\n' "$ECC_OUT" | split_gpu_blocks ecc)"
  if [ -z "$ECC_BLOCKS" ]; then
    note INFO ecc "could not parse per-GPU ECC blocks from nvidia-smi -q"
  fi
  for blk in $ECC_BLOCKS; do
    g="$(gpu_of "$blk")"
    mode="$(grep -m1 -E '^[[:space:]]+Current[[:space:]]*:' "$blk" | sed 's/.*: *//')"
    [ -n "$mode" ] && note INFO ecc "${g}: ECC mode ${mode}"
    if grep -qiE '(Double Bit|Uncorrectable)[^:]*: *[1-9]' "$blk"; then
      note CRIT ecc "${g}: uncorrectable ECC errors detected"
    fi
    if grep -qiE 'Pending( Page Blacklist)?[[:space:]]*: *Yes' "$blk"; then
      note WARN ecc "${g}: pending retired pages / ECC action pending (reboot recommended)"
    fi
    if grep -qiE '(Single Bit|Correctable)[^:]*: *[1-9]' "$blk"; then
      note WARN ecc "${g}: correctable ECC errors present"
    fi
    if ! grep -qiE 'Retired Pages' "$blk" || grep -A3 'Retired Pages' "$blk" | grep -qE ': *N/A'; then
      echo "(${g}: page retirement not supported; see row remapper below)"
    fi
  done

  section "nvidia-smi: row remapper (Ampere and newer)"
  src rowremap "nvidia-smi -q -d ROW_REMAPPER"
  RR_OUT="$(nvidia-smi -q -d ROW_REMAPPER 2>&1)"
  echo "$RR_OUT"
  RR_BLOCKS="$(printf '%s\n' "$RR_OUT" | split_gpu_blocks rr)"
  [ -z "$RR_BLOCKS" ] && note INFO rowremap "row remapper not reported by this nvidia-smi"
  for blk in $RR_BLOCKS; do
    g="$(gpu_of "$blk")"
    if ! grep -qiE 'Remapped Rows|Row Remapper' "$blk" || grep -A2 -iE 'Remapped Rows|Row Remapper' "$blk" | grep -qiE 'N/A|Not Supported'; then
      note INFO rowremap "${g}: row remapper not supported on this GPU"
      continue
    fi
    corr="$(grep -m1 -E '^[[:space:]]+Correctable Error[[:space:]]*:' "$blk" | sed 's/.*: *//')"
    uncorr="$(grep -m1 -E '^[[:space:]]+Uncorrectable Error[[:space:]]*:' "$blk" | sed 's/.*: *//')"
    if grep -qiE 'Remapping Failure Occurred[[:space:]]*:[[:space:]]*Yes' "$blk"; then
      note CRIT rowremap "${g}: row remapping FAILURE occurred — memory cannot be repaired, RMA candidate"
    elif grep -qiE '^[[:space:]]+Pending[[:space:]]*:[[:space:]]*Yes' "$blk"; then
      note WARN rowremap "${g}: row remap pending — GPU reset/reboot required to apply"
    elif printf '%s' "$uncorr" | grep -qE '^[1-9]'; then
      note WARN rowremap "${g}: rows remapped for uncorrectable errors: ${uncorr} (correctable: ${corr:-0})"
    elif printf '%s' "$corr" | grep -qE '^[1-9]'; then
      note INFO rowremap "${g}: rows remapped for correctable errors: ${corr}"
    else
      note OK rowremap "${g}: no remapped rows, none pending"
    fi
  done

  section "nvidia-smi: performance / throttle reasons"
  src throttle "nvidia-smi -q -d PERFORMANCE   # judged together with power.draw/power.limit/utilization.gpu from the query above"
  PERF_OUT="$(nvidia-smi -q -d PERFORMANCE 2>&1)"
  echo "$PERF_OUT"
  PERF_BLOCKS="$(printf '%s\n' "$PERF_OUT" | split_gpu_blocks perf)"
  for blk in $PERF_BLOCKS; do
    g="$(gpu_of "$blk")"
    pstate="$(grep -m1 -E 'Performance State[[:space:]]*:' "$blk" | sed 's/.*: *//')"
    draw="$(qfield "$g" power.draw)"; limit="$(qfield "$g" power.limit)"; util="$(qfield "$g" utilization.gpu)"; sm="$(qfield "$g" clocks.sm)"
    capus="$(grep -m1 -E 'SW Power Capping[[:space:]]*:' "$blk" | sed 's/.*: *//; s/ us//')"
    if grep -qiE '(HW Slowdown|HW Thermal Slowdown|SW Thermal Slowdown|HW Power Brake Slowdown) *: *Active' "$blk"; then
      note CRIT throttle "${g}: hardware/thermal slowdown currently ACTIVE (${pstate:-?}, ${draw:-?}/${limit:-?} W, ${util:-?}% util)"
    elif grep -qiE 'SW Power Cap *: *Active' "$blk"; then
      # At idle (near-zero draw, 0% util, clocks on the floor) the SW power-scaling
      # algorithm is often named as the active clock reason. That is a reporting
      # quirk, not throttling. Only warn when the GPU is actually working near its cap.
      busy=false
      if [ -n "$draw" ] && [ -n "$limit" ] && awk -v d="$draw" -v l="$limit" 'BEGIN{exit !(l>0 && d/l>=0.85)}'; then busy=true; fi
      [ "${util:-0}" != "0" ] && [ -n "$util" ] && busy=true
      if [ "$busy" = true ]; then
        note WARN throttle "${g}: SW power cap throttling active (${pstate:-?}, ${draw:-?}/${limit:-?} W, ${util:-?}% util, SM ${sm:-?} MHz)"
      else
        note INFO throttle "${g}: 'SW Power Cap' flag set while idle (${draw:-?}/${limit:-?} W, ${util:-?}% util, SM ${sm:-?} MHz; capped ${capus:-?} us) — idle reporting quirk, not throttling"
      fi
    else
      note OK throttle "${g}: no slowdown/power-cap throttling (${pstate:-?}, ${draw:-?}/${limit:-?} W)"
    fi
  done

  section "nvidia-smi: temperature / power"
  src thermal "nvidia-smi -q -d TEMPERATURE,POWER"
  nvidia-smi -q -d TEMPERATURE,POWER 2>&1
  echo "(note: 'T.Limit' temperature specifications are offsets relative to the throttle limit, not absolute readings)"

  section "nvidia-smi: clocks"
  src clocks "nvidia-smi -q -d CLOCK"
  nvidia-smi -q -d CLOCK 2>&1

  section "nvidia-smi: topology"
  src topology "nvidia-smi topo -m"
  nvidia-smi topo -m 2>&1

  section "nvidia-smi: supported clocks"
  src clocks "nvidia-smi -q -d SUPPORTED_CLOCKS | head -60"
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
    level="${f%%"$US"*}"; rest="${f#*"$US"}"
    check="${rest%%"$US"*}"; rest="${rest#*"$US"}"
    msg="${rest%%"$US"*}"; cmd="${rest#*"$US"}"
    comma=","
    [ "$i" -eq "$n" ] && comma=""
    printf '    {"level": "%s", "check": "%s", "message": "%s", "command": %s}%s\n' \
      "$(jesc "$level")" "$(jesc "$check")" "$(jesc "$msg")" "$(jval "$cmd")" "$comma"
  done
  echo "  ],"
  echo "  \"sources\": ["
  n=${#SOURCES[@]}; i=0
  for f in "${SOURCES[@]}"; do
    i=$((i+1)); comma=","; [ "$i" -eq "$n" ] && comma=""
    printf '    {"check": "%s", "command": "%s"}%s\n' "$(jesc "${f%%|*}")" "$(jesc "${f#*|}")" "$comma"
  done
  echo "  ],"
  echo "  \"host\": {"
  echo "    \"os\": $(jval "$HOST_OS"),"
  echo "    \"kernel\": $(jval "$HOST_KERNEL"),"
  echo "    \"arch\": $(jval "$HOST_ARCH"),"
  echo "    \"virtualization\": $(jval "$HOST_VIRT"),"
  echo "    \"uptime_seconds\": $(jval "$HOST_UPTIME_S"),"
  echo "    \"boot_id\": $(jval "$HOST_BOOT_ID"),"
  echo "    \"cpus\": $(jval "$HOST_CPUS"),"
  echo "    \"memory_mib\": $(jval "$HOST_MEM_MB"),"
  echo "    \"nvidia_module_version\": $(jval "$NV_MOD_VER"),"
  echo "    \"nvidia_module_vermagic\": $(jval "$NV_VERMAGIC"),"
  echo "    \"cmdline\": $(jval "$HOST_CMDLINE")"
  echo "  },"
  echo "  \"pcie\": [${PCIE_JSON}],"
  echo "  \"events\": {"
  echo "    \"journal_available\": $JOURNAL_OK,"
  echo "    \"xid\": {\"this_boot\": ${CUR_XID:-0}, \"total\": ${EV_xid_TOTAL:-0}, \"last\": $(jval "${EV_xid_LAST:-}"), \"codes\": $(jval "$XID_CODES")},"
  echo "    \"fallen_off_bus\": {\"this_boot\": ${CUR_FALLEN:-0}, \"total\": ${EV_fallenoff_TOTAL:-0}, \"last\": $(jval "${EV_fallenoff_LAST:-}")},"
  echo "    \"aer\": {\"this_boot\": ${CUR_AER:-0}, \"total\": ${EV_aer_TOTAL:-0}, \"last\": $(jval "${EV_aer_LAST:-}")},"
  echo "    \"driver_init_failure\": {\"this_boot\": ${CUR_INITFAIL:-0}, \"total\": ${EV_initfail_TOTAL:-0}, \"last\": $(jval "${EV_initfail_LAST:-}")},"
  echo "    \"userspace_warnings_7d\": ${UJ_COUNT:-0}"
  echo "  },"
  echo "  \"gpus\": [${GPUS_JSON}]"
  echo "}"
} > "$JSON_OUT"

section "SUMMARY"
echo "Severity: ${SEVERITY} ($( [ $SEVERITY -eq 0 ] && echo OK || { [ $SEVERITY -eq 1 ] && echo WARNINGS || echo CRITICAL; } ))"
echo "Findings: ${#FINDINGS[@]}"
echo "JSON report written to: ${JSON_OUT}"

exit "$SEVERITY"
