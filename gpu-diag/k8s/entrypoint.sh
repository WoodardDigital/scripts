#!/bin/sh
#
# entrypoint.sh — gpu-diag.sh wrapper for `kubectl debug node/<node>`
#
#   kubectl debug node/<node> -it --profile=sysadmin --image=ghcr.io/woodarddigital/gpu-diag
#
# kubectl debug gives this container the node's PID/network namespaces and
# the node's root filesystem at /host. This script downloads the current
# gpu-diag.sh from the scripts repo and runs it ON THE NODE — with the node's
# own bash, nvidia-smi, lspci, dmesg, journalctl — via nsenter (privileged,
# --profile=sysadmin) or, failing that, chroot /host (unprivileged; GPU and
# dmesg access is then blocked and the report is incomplete).
#
# Env (override with `kubectl debug --env KEY=VALUE`):
#   SCRIPT_REF          git ref of gpu-diag.sh to fetch            (default: main)
#   SCRIPT_URL          fetch from this URL instead                (default: derived from SCRIPT_REF)
#   SCRIPT_SOURCE       auto | url | image                         (default: auto = url, fall back to image copy)
#   KEEP_ALIVE_SECONDS  non-interactive: wait this long after the run so a report can be copied out (default: 0)
#   FAIL_ON_SEVERITY    true: exit with gpu-diag's severity code   (default: false)
#
# Output:  <node>-<utc-ts>.log and .json in /output (copy with kubectl cp);
#          everything is also printed to stdout.
#
set -u

SCRIPT_REF="${SCRIPT_REF:-main}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/WoodardDigital/scripts/${SCRIPT_REF}/gpu-diag/gpu-diag.sh}"
SCRIPT_SOURCE="${SCRIPT_SOURCE:-auto}"
IMAGE_SCRIPT="${IMAGE_SCRIPT:-/opt/gpu-diag/gpu-diag.sh}"
OUT_DIR="${OUT_DIR:-/output}"
STATE_DIR="${STATE_DIR:-/tmp}"
HOST_ROOT="${HOST_ROOT:-/host}"
KEEP_ALIVE_SECONDS="${KEEP_ALIVE_SECONDS:-0}"
FAIL_ON_SEVERITY="${FAIL_ON_SEVERITY:-false}"
HOST_TOOLS="bash nvidia-smi lspci lsmod modinfo dmesg journalctl ps fuser lsof"

NODE_NAME="${NODE_NAME:-$(hostname 2>/dev/null || echo unknown)}"   # hostNetwork => node hostname
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_NODE="$(printf '%s' "$NODE_NAME" | tr -c 'A-Za-z0-9._-' '_')"
REPORT="${SAFE_NODE}-${TS}"
BASE="${OUT_DIR}/${REPORT}"
DONE_FILE="${STATE_DIR}/gpu-triage.done"
RELEASE_FILE="${STATE_DIR}/gpu-triage.release"
SCRIPT_FILE="${STATE_DIR}/gpu-diag.sh"

log() { printf '[gpu-diag] %s\n' "$*"; }
hr()  { printf '%s\n' "================================================================"; }

interactive() { [ -t 0 ] && [ -t 1 ]; }

wait_release() {
  if [ "${KEEP_ALIVE_SECONDS}" -gt 0 ] 2>/dev/null; then
    log "waiting up to ${KEEP_ALIVE_SECONDS}s for the report to be copied out (touch ${RELEASE_FILE} to end)"
    end=$(( $(date +%s) + KEEP_ALIVE_SECONDS ))
    while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$RELEASE_FILE" ]; do sleep 2; done
  fi
}

fail() {
  log "ERROR: $*"
  printf 'FAILED\n' > "$DONE_FILE"
  if interactive; then log "dropping into a shell"; exec sh; fi
  wait_release
  exit 3
}

mkdir -p "$OUT_DIR" /usr/local/bin || fail "cannot create $OUT_DIR"

# ---- 1. how do we reach the node? ---------------------------------------------
if nsenter -t 1 -m -u -i -n -p true 2>/dev/null; then
  MODE=nsenter
  printf '#!/bin/sh\nexec nsenter -t 1 -m -u -i -n -p "$@"\n' > /usr/local/bin/host
elif [ -e "$HOST_ROOT/proc/self" ] && chroot "$HOST_ROOT" true 2>/dev/null; then
  MODE=chroot
  printf '#!/bin/sh\nexec chroot %s "$@"\n' "$HOST_ROOT" > /usr/local/bin/host
else
  fail "cannot reach the node: nsenter failed and $HOST_ROOT is not a usable host root. Use: kubectl debug node/<node> -it --profile=sysadmin --image=..."
fi
chmod 0755 /usr/local/bin/host
host() { /usr/local/bin/host "$@"; }

host sh -c 'command -v bash >/dev/null 2>&1' || fail "node has no bash; gpu-diag.sh needs bash on the host OS"

PRESENT=""; ABSENT=""
for t in $HOST_TOOLS; do
  if host sh -c "command -v $t >/dev/null 2>&1"; then PRESENT="$PRESENT $t"; else ABSENT="$ABSENT $t"; fi
done

# ---- 2. get the script -----------------------------------------------------------
fetch() {
  rm -f "$SCRIPT_FILE"
  wget -q -O "$SCRIPT_FILE" "$SCRIPT_URL" 2>/dev/null && [ -s "$SCRIPT_FILE" ] && return 0
  # pod egress may be blocked; try from the node
  host sh -c "command -v curl >/dev/null 2>&1 && exec curl -fsSL '$SCRIPT_URL'; exec wget -qO- '$SCRIPT_URL'" \
    > "$SCRIPT_FILE" 2>/dev/null && [ -s "$SCRIPT_FILE" ]
}

SOURCE=""
case "$SCRIPT_SOURCE" in
  image) ;;
  url)   fetch && SOURCE="$SCRIPT_URL" || fail "could not download $SCRIPT_URL" ;;
  *)     fetch && SOURCE="$SCRIPT_URL" || log "WARN: could not download $SCRIPT_URL; using the copy built into this image" ;;
esac
if [ -z "$SOURCE" ]; then
  [ -s "$IMAGE_SCRIPT" ] || fail "no script: download failed and $IMAGE_SCRIPT is missing"
  cp "$IMAGE_SCRIPT" "$SCRIPT_FILE"
  if [ "$IMAGE_SCRIPT" = /opt/gpu-diag/gpu-diag.sh ]; then
    SOURCE="built into image ($(cat /opt/gpu-diag/VERSION 2>/dev/null || echo unknown build))"
  else
    SOURCE="local file ${IMAGE_SCRIPT} (copied into the pod)"
  fi
fi
head -c 2 "$SCRIPT_FILE" | grep -q '^#!' || fail "fetched content is not a script: $SOURCE"
SIZE="$(wc -c < "$SCRIPT_FILE" | tr -d ' ')"
[ "$SIZE" -lt 120000 ] || fail "script is ${SIZE} bytes; too large to pass to bash -c"
SHA="$(sha256sum "$SCRIPT_FILE" | cut -c1-12)"

# ---- 3. run it on the node --------------------------------------------------------
# The script text is handed to the node's bash as an argument, and its JSON
# output goes to fd 3 (our staged .json) — the node's filesystem never sees
# either file.
exec 3>"${BASE}.json"
{
  hr
  log "node:          ${NODE_NAME}"
  log "started (UTC): ${TS}"
  log "access:        ${MODE}"
  if [ "$MODE" = chroot ]; then
    log "WARNING: container is not privileged. /dev/nvidia* and dmesg are blocked,"
    log "         so nvidia-smi/dmesg findings below are NOT trustworthy."
    log "         Re-run with:  kubectl debug node/<node> -it --profile=sysadmin --image=..."
  fi
  log "script:        ${SOURCE}"
  log "script sha256: ${SHA}  (${SIZE} bytes)"
  log "on node:      ${PRESENT}"
  log "missing:      ${ABSENT:- none}"
  log "report:        ${REPORT}.log / .json"
  hr
  echo
  host bash -c "$(cat "$SCRIPT_FILE")" gpu-diag.sh /proc/self/fd/3
  echo "$?" > "${STATE_DIR}/gpu-triage.rc"
  echo
  hr
  log "JSON summary:"
  cat "${BASE}.json" 2>/dev/null || log "WARN: JSON report missing"
  hr
} 2>&1 | tee "${BASE}.log"
exec 3>&-

RC="$(cat "${STATE_DIR}/gpu-triage.rc" 2>/dev/null || echo 3)"
case "$RC" in
  0) LABEL="OK" ;;
  1) LABEL="WARNINGS" ;;
  2) LABEL="CRITICAL" ;;
  *) LABEL="SCRIPT ERROR (rc=$RC)" ;;
esac
log "RESULT: ${LABEL} on ${NODE_NAME}"
printf '%s\n' "$REPORT" > "$DONE_FILE"

# ---- 4. hand over -------------------------------------------------------------------
if interactive; then
  cat <<MSG

Report files (inside this pod):
    ${BASE}.log
    ${BASE}.json

Copy them to your machine from ANOTHER terminal while this shell is open —
the pod name is the node-debugger-... one kubectl debug printed:
    kubectl cp [-n <namespace>] <pod>:${OUT_DIR}/${REPORT}.log  ./${REPORT}.log
    kubectl cp [-n <namespace>] <pod>:${OUT_DIR}/${REPORT}.json ./${REPORT}.json

'host <command>' runs a command on the node, e.g.  host nvidia-smi
Type 'exit' when done, then remove the debug pod:  kubectl delete pod <pod>

MSG
  export PS1="gpu-diag@${NODE_NAME}:\$PWD# "
  cd "$OUT_DIR" && exec sh
fi

wait_release
[ "$FAIL_ON_SEVERITY" = "true" ] && exit "$RC"
exit 0
