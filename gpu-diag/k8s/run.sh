#!/usr/bin/env bash
#
# run.sh — non-interactive wrapper around `kubectl debug node/…` that runs
#          gpu-diag.sh on a node and saves the report to your machine.
#
#   kubectl debug node/<node> -it --profile=sysadmin --image=ghcr.io/woodarddigital/gpu-diag
#
# does the same thing interactively; this script adds: a cluster-side view of
# the node (GPU capacity/allocatable, operator pods, validator results, events),
# streams the report, kubectl cp's the .log/.json into --out-dir, and deletes
# the debug pod.
#
# Usage:
#   ./run.sh [options] <node> [<node> ...]
#   ./run.sh [options] -l <label-selector>       # e.g. -l nvidia.com/gpu.present=true
#
# Options:
#   -o, --out-dir DIR        save reports to this local directory (default: ./reports)
#   -n, --namespace NS       namespace for the debug pod (default: current context's)
#       --local              no published image needed: start a stock busybox pod and
#                            kubectl cp this checkout's entrypoint.sh + gpu-diag.sh into it
#   -r, --ref REF            git ref of gpu-diag.sh to fetch (default: main)
#       --script-url URL     fetch gpu-diag.sh from this URL instead
#       --image-script       use the copy of gpu-diag.sh built into the image (offline)
#   -i, --image IMAGE        image (default: ghcr.io/woodarddigital/gpu-diag:latest,
#                            busybox:1.36.1 with --local)
#       --profile PROFILE    kubectl debug profile (default: sysadmin)
#   -k, --keep SECONDS       max time the pod waits for the report to be fetched (default 600)
#   -t, --timeout SECONDS    wait this long for the pod to start (default 300)
#   -l, --selector SELECTOR  run on every node matching this label selector
#       --context CTX        kubectl context
#       --cuda-test          also run a short CUDA vectorAdd pod on the node (needs a free nvidia.com/gpu)
#       --cuda-image IMAGE   image for --cuda-test (default: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0)
#       --no-cluster-view    skip the kubectl-side node/operator summary
#       --keep-pod           do not delete the debug pod afterwards
#       --dry-run            print the kubectl debug command(s), change nothing
#   -h, --help
#
# Requires kubectl >= 1.28 (for --profile=sysadmin) with rights to create
# privileged pods in the namespace, plus pods/exec and pods/log.
#
set -euo pipefail

# works from a checkout or piped from the repo URL (then $HERE is "." and --local is unavailable)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"
REPO_RAW="https://raw.githubusercontent.com/WoodardDigital/scripts"

OUT_DIR="./reports"
LOCAL=false
NAMESPACE=""
REF="main"
SCRIPT_URL=""
IMAGE_SCRIPT=false
IMAGE=""
PROFILE="sysadmin"
KEEP_ALIVE=600
TIMEOUT=300
SELECTOR=""
CONTEXT=""
KEEP_POD=false
DRY_RUN=false
CUDA_TEST=false
CUDA_IMAGE="nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0"
CLUSTER_VIEW=true
NODES=()

usage() {
  if [ -r "$0" ] && grep -q '^set -euo' "$0" 2>/dev/null; then
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  else
    echo "usage: run.sh [options] <node> [<node> ...]   (see https://github.com/WoodardDigital/scripts/tree/main/gpu-diag#readme)"
  fi
}
die()   { printf 'run.sh: %s\n' "$*" >&2; exit 1; }
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out-dir)   OUT_DIR="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --local)        LOCAL=true; shift ;;
    -r|--ref)       REF="$2"; shift 2 ;;
    --script-url)   SCRIPT_URL="$2"; shift 2 ;;
    --image-script) IMAGE_SCRIPT=true; shift ;;
    -i|--image)     IMAGE="$2"; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    -k|--keep)      KEEP_ALIVE="$2"; shift 2 ;;
    -t|--timeout)   TIMEOUT="$2"; shift 2 ;;
    -l|--selector)  SELECTOR="$2"; shift 2 ;;
    --context)      CONTEXT="$2"; shift 2 ;;
    --cuda-test)    CUDA_TEST=true; shift ;;
    --cuda-image)   CUDA_IMAGE="$2"; shift 2 ;;
    --no-cluster-view) CLUSTER_VIEW=false; shift ;;
    --keep-pod)     KEEP_POD=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1 (see --help)" ;;
    *)              NODES+=("$1"); shift ;;
  esac
done
[ "$KEEP_ALIVE" -gt 0 ] 2>/dev/null || die "--keep must be > 0"
if [ -z "$IMAGE" ]; then
  if [ "$LOCAL" = true ]; then IMAGE="busybox:1.36.1"; else IMAGE="ghcr.io/woodarddigital/gpu-diag:latest"; fi
fi
LOCAL_ENTRYPOINT="$HERE/entrypoint.sh"
LOCAL_SCRIPT="$HERE/../gpu-diag.sh"
if [ "$LOCAL" = true ]; then
  [ -r "$LOCAL_ENTRYPOINT" ] || die "--local needs a checkout: $LOCAL_ENTRYPOINT not found"
  [ -r "$LOCAL_SCRIPT" ]     || die "--local: $LOCAL_SCRIPT not found"
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
KUBECTL=(kubectl)
[ -n "$CONTEXT" ]   && KUBECTL+=(--context "$CONTEXT")
kc() { "${KUBECTL[@]}" "$@"; }                      # cluster-scoped / -A queries
[ -n "$NAMESPACE" ] && KUBECTL+=(-n "$NAMESPACE")
k() { "${KUBECTL[@]}" "$@"; }                       # namespaced (debug pod)

ENV_ARGS=(--env "KEEP_ALIVE_SECONDS=$KEEP_ALIVE")
if [ "$LOCAL" = true ]; then
  # stock image: the entrypoint and script are copied in after the pod starts
  ENV_ARGS=(--env "NVIDIA_VISIBLE_DEVICES=void"); SCRIPT_DESC="local $LOCAL_SCRIPT (copied into the pod)"
elif [ "$IMAGE_SCRIPT" = true ]; then
  ENV_ARGS+=(--env "SCRIPT_SOURCE=image"); SCRIPT_DESC="copy built into $IMAGE"
elif [ -n "$SCRIPT_URL" ]; then
  ENV_ARGS+=(--env "SCRIPT_URL=$SCRIPT_URL" --env "SCRIPT_SOURCE=url"); SCRIPT_DESC="$SCRIPT_URL"
elif [ "$REF" != "main" ]; then
  ENV_ARGS+=(--env "SCRIPT_REF=$REF" --env "SCRIPT_SOURCE=url"); SCRIPT_DESC="${REPO_RAW}/${REF}/gpu-diag/gpu-diag.sh"
else
  # default: fetch main, fall back to the copy in the image if the download fails
  SCRIPT_DESC="${REPO_RAW}/main/gpu-diag/gpu-diag.sh (image copy as fallback)"
fi

if [ -n "$SELECTOR" ]; then
  while IFS= read -r n; do [ -n "$n" ] && NODES+=("$n"); done < <(
    k get nodes -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ ${#NODES[@]} -gt 0 ] || die "no nodes match selector '$SELECTOR'"
fi
[ ${#NODES[@]} -gt 0 ] || { usage; die "no node given"; }

# --- helpers ---------------------------------------------------------------

debug_args() {
  # kubectl debug node/<node> ... ; with --local the container just sleeps until we exec into it
  DEBUG_ARGS=(debug "node/$1" --image="$IMAGE" --profile="$PROFILE" "${ENV_ARGS[@]}")
  if [ "$LOCAL" = true ]; then
    DEBUG_ARGS+=(-- sleep 7200)
  else
    DEBUG_ARGS+=(--image-pull-policy=Always)
  fi
}

debug_cmd() {
  debug_args "$1"
  printf '%q ' "${KUBECTL[@]}" "${DEBUG_ARGS[@]}"
  echo
  if [ "$LOCAL" = true ]; then
    printf '%q ' "${KUBECTL[@]}" cp -c debugger "$LOCAL_ENTRYPOINT" '<pod>:/tmp/entrypoint.sh'; echo
    printf '%q ' "${KUBECTL[@]}" cp -c debugger "$LOCAL_SCRIPT" '<pod>:/tmp/gpu-diag.sh'; echo
    printf '%q ' "${KUBECTL[@]}" exec '<pod>' -c debugger -- env "KEEP_ALIVE_SECONDS=$KEEP_ALIVE" SCRIPT_SOURCE=image IMAGE_SCRIPT=/tmp/gpu-diag.sh sh /tmp/entrypoint.sh; echo
  fi
}

# --local: put this checkout's wrapper and script into the running pod, then run it
run_local() {
  local pod="$1"
  k cp -c debugger "$LOCAL_ENTRYPOINT" "$pod:/tmp/entrypoint.sh" >/dev/null || return 1
  k cp -c debugger "$LOCAL_SCRIPT"     "$pod:/tmp/gpu-diag.sh"   >/dev/null || return 1
  k exec "$pod" -c debugger -- env "KEEP_ALIVE_SECONDS=$KEEP_ALIVE" SCRIPT_SOURCE=image \
      IMAGE_SCRIPT=/tmp/gpu-diag.sh sh /tmp/entrypoint.sh
}

pod_phase() { k get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true; }

# newest node-debugger pod for a node (fallback when the kubectl message can't be parsed)
find_debug_pod() {
  k get pods -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep " node-debugger-$1-" | sort | tail -1 | awk '{print $2}'
}

wait_for_pod() {
  local pod="$1" deadline phase
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    phase="$(pod_phase "$pod")"
    case "$phase" in Running|Succeeded|Failed) return 0 ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'run.sh: pod %s did not start within %ss\n' "$pod" "$TIMEOUT" >&2
      k describe pod "$pod" | sed -n '/^Events:/,$p' >&2
      return 1
    fi
    sleep 2
  done
}

copy_reports() {
  local pod="$1" base
  base="$(k exec "$pod" -c debugger -- sh -c \
    'i=0; while [ ! -f /tmp/gpu-triage.done ]; do i=$((i+1)); [ $i -gt 1800 ] && exit 1; sleep 1; done; cat /tmp/gpu-triage.done' 2>/dev/null)" \
    || { printf 'run.sh: timed out waiting for the report inside %s\n' "$pod" >&2; return 1; }
  if [ "$base" = "FAILED" ]; then
    k exec "$pod" -c debugger -- touch /tmp/gpu-triage.release >/dev/null 2>&1 || true
    return 1
  fi
  mkdir -p "$OUT_DIR"
  for ext in log json; do
    k cp -c debugger "$pod:/output/${base}.${ext}" "$OUT_DIR/${base}.${ext}" >/dev/null 2>&1 \
      || k exec "$pod" -c debugger -- cat "/output/${base}.${ext}" > "$OUT_DIR/${base}.${ext}"
    SAVED+=("$OUT_DIR/${base}.${ext}")
  done
  # the cluster-side view goes at the top of the saved .log
  if [ -s "${CVFILE:-}" ]; then
    cat "$CVFILE" "$OUT_DIR/${base}.log" > "$OUT_DIR/${base}.log.tmp" && mv "$OUT_DIR/${base}.log.tmp" "$OUT_DIR/${base}.log"
  fi
  k exec "$pod" -c debugger -- touch /tmp/gpu-triage.release >/dev/null 2>&1 || true
}

# --- cluster view ------------------------------------------------------------------
# What Kubernetes thinks of this node's GPU: capacity/allocatable, who holds the
# GPUs, GFD labels, operator pods, the operator's own CUDA validator, events.
# Findings are prefixed [cluster] so they can be grepped like the script's.

cnote() { printf '[cluster] %-5s %s\n' "$1" "$2"; }

cluster_view() {
  local node="$1" cap alloc req ready unsched pods_holding
  echo "================================================================"
  echo "[cluster] node: $node   (context: $(kc config current-context 2>/dev/null || echo ?))"
  echo "================================================================"
  kc get node "$node" -o custom-columns='READY:.status.conditions[?(@.type=="Ready")].status,UNSCHEDULABLE:.spec.unschedulable,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion' 2>/dev/null
  ready="$(kc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  unsched="$(kc get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)"
  [ "$ready" = "True" ] || cnote WARN "node Ready condition is '${ready:-unknown}'"
  [ "$unsched" = "true" ] && cnote WARN "node is cordoned (unschedulable)"

  echo
  cap="$(kc get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null)"
  alloc="$(kc get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
  req="$(kc get pods -A --field-selector "spec.nodeName=$node" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.nvidia\.com/gpu}{"\n"}{end}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  echo "nvidia.com/gpu   capacity: ${cap:-none}   allocatable: ${alloc:-none}   requested by pods on node: ${req:-0}"
  if [ -z "$alloc" ] || [ "$alloc" = "0" ]; then
    cnote WARN "node advertises no allocatable nvidia.com/gpu (device plugin not registered or GPU unhealthy)"
  elif [ "${req:-0}" -ge "$alloc" ]; then
    cnote INFO "all ${alloc} GPU(s) are allocated to pods; a --cuda-test would not schedule"
  else
    cnote OK "${alloc} GPU(s) allocatable, ${req:-0} in use"
  fi
  pods_holding="$(kc get pods -A --field-selector "spec.nodeName=$node" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk -F'\t' '$2!="" {print "  " $1 "  (" $2 ")"}')"
  [ -n "$pods_holding" ] && { echo "pods holding GPUs:"; echo "$pods_holding"; }

  echo
  echo "taints:"
  kc get node "$node" -o jsonpath='{range .spec.taints[*]}  {.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null | grep . || echo "  (none)"

  echo
  echo "nvidia.com/* labels (GPU Feature Discovery):"
  kc get node "$node" -o go-template='{{range $k,$v := .metadata.labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null | grep '^nvidia\.com/' | sed 's/^/  /' | head -40
  # (capture first: kubectl | grep -q trips pipefail via SIGPIPE)
  local labels; labels="$(kc get node "$node" -o go-template='{{range $k,$v := .metadata.labels}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)"
  printf '%s\n' "$labels" | grep -q '^nvidia\.com/gpu\.present' || cnote INFO "no GPU Feature Discovery labels on the node"

  echo
  echo "NVIDIA / GPU Operator pods on this node:"
  kc get pods -A --field-selector "spec.nodeName=$node" -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,IMAGE:.spec.containers[*].image' 2>/dev/null \
    | grep -iE '^NAMESPACE|nvidia|gpu-operator|gpu-feature|dcgm|device-plugin' > "$TMP_CV" || true
  if [ "$(wc -l < "$TMP_CV" | tr -d ' ')" -le 1 ]; then
    echo "  (none)"; cnote INFO "no NVIDIA/GPU Operator pods on this node"
  else
    cat "$TMP_CV"
    awk 'NR>1 && $3!="Running" && $3!="Succeeded" {print $1"/"$2" is "$3}' "$TMP_CV" | while read -r l; do cnote WARN "$l"; done
    awk 'NR>1 {n=split($5,r,","); for(i=1;i<=n;i++) if (r[i]+0>0) {print $1"/"$2" restarts: "$5; break}}' "$TMP_CV" | while read -r l; do cnote WARN "$l"; done
  fi

  echo
  echo "operator validators on this node (CUDA / driver / toolkit checks the operator already ran):"
  local found=false p ns name
  for p in $(kc get pods -A --field-selector "spec.nodeName=$node" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '/nvidia-(cuda|operator)-validator'); do
    found=true; ns="${p%/*}"; name="${p#*/}"
    echo "--- $p  phase: $(kc -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
    local vlogs; vlogs="$(kc -n "$ns" logs "$name" --all-containers 2>&1 || true)"
    printf '%s\n' "$vlogs" | tail -15 | sed 's/^/  /'
    if printf '%s\n' "$vlogs" | grep -qiE 'Test PASSED|all validations are successful|validation.*success'; then
      cnote OK "$name passed"
    else
      cnote INFO "$name: no explicit pass marker in logs (see above)"
    fi
  done
  [ "$found" = true ] || cnote INFO "no operator validator pods on this node"

  echo
  echo "recent Warning events for the node:"
  local ev; ev="$(kc get events -A --field-selector "involvedObject.name=$node,involvedObject.kind=Node,type=Warning" --sort-by=.lastTimestamp \
    -o custom-columns='LAST:.lastTimestamp,REASON:.reason,MESSAGE:.message' --no-headers 2>/dev/null || true)"
  if [ -n "$ev" ]; then printf '%s\n' "$ev" | tail -10 | sed 's/^/  /'; else echo "  (none)"; fi
  echo "================================================================"
}

# --- optional CUDA test pod -----------------------------------------------------------

cuda_test() {
  local node="$1" name="gpu-diag-cuda-$(date +%s)" phase deadline reason
  echo "================================================================"
  echo "[cluster] CUDA test: vectorAdd on $node via $CUDA_IMAGE (requests nvidia.com/gpu: 1)"
  echo "================================================================"
  k apply -f - >/dev/null <<EOF_POD
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels: {app.kubernetes.io/name: gpu-diag-cuda-test}
spec:
  restartPolicy: Never
  nodeName: $node
  tolerations: [{operator: Exists}]
  containers:
  - name: vectoradd
    image: $CUDA_IMAGE
    resources: {limits: {nvidia.com/gpu: 1}}
EOF_POD
  deadline=$(( $(date +%s) + 240 ))
  while :; do
    phase="$(k get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
    case "$phase" in Succeeded|Failed) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
    sleep 3
  done
  case "$phase" in
    Succeeded)
      k logs "$name" 2>&1 | tail -15 | sed 's/^/  /'
      if k logs "$name" 2>/dev/null > "$TMP_CV" && grep -q 'Test PASSED' "$TMP_CV"; then cnote OK "CUDA vectorAdd passed on $node"; else cnote WARN "CUDA pod succeeded but no 'Test PASSED' in output"; fi ;;
    Failed)
      k logs "$name" 2>&1 | tail -20 | sed 's/^/  /'
      cnote CRIT "CUDA vectorAdd pod FAILED on $node (exit $(k get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null))" ;;
    *)
      reason="$(k get events --field-selector "involvedObject.name=$name" -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null | tail -3)"
      echo "$reason" | sed 's/^/  /'
      if echo "$reason" | grep -q 'Insufficient nvidia.com/gpu'; then
        cnote INFO "CUDA test could not schedule: no free nvidia.com/gpu on $node (GPU held by another pod)"
      else
        cnote WARN "CUDA test pod did not finish within 240s (phase: ${phase:-none}); see events above"
      fi ;;
  esac
  k delete pod "$name" --wait=false >/dev/null 2>&1 || true
  echo "================================================================"
}

# --- main ---------------------------------------------------------------------

if [ "$DRY_RUN" = true ]; then
  [ "$CLUSTER_VIEW" = true ] && echo "# (cluster view: kubectl get node/pods/events for each node, printed and prepended to the .log)"
  for node in "${NODES[@]}"; do debug_cmd "$node"; done
  [ "$CUDA_TEST" = true ] && echo "# (--cuda-test: one-shot pod $CUDA_IMAGE with nvidia.com/gpu: 1 on each node)"
  exit 0
fi
TMP_CV="$(mktemp "${TMPDIR:-/tmp}/gpu-diag-cv.XXXXXX")"
trap 'rm -f "$TMP_CV"' EXIT

info "image $IMAGE (profile $PROFILE), script: $SCRIPT_DESC, reports -> $OUT_DIR"

RESULTS=()
SAVED=()
FAILED=0
for node in "${NODES[@]}"; do
  echo
  info "node: $node"
  if ! k get node "$node" >/dev/null 2>&1; then
    printf 'run.sh: node %s not found (kubectl get nodes)\n' "$node" >&2
    RESULTS+=("$node: NODE NOT FOUND"); FAILED=1; continue
  fi

  # kubectl debug prints: Creating debugging pod node-debugger-<node>-xxxxx with container debugger on node <node>.
  cvfile="$(mktemp "${TMPDIR:-/tmp}/gpu-diag-cluster.XXXXXX")"
  if [ "$CLUSTER_VIEW" = true ] || [ "$CUDA_TEST" = true ]; then
    {
      [ "$CLUSTER_VIEW" = true ] && cluster_view "$node"
      [ "$CUDA_TEST" = true ]    && cuda_test "$node"
      echo
    } 2>&1 | tee "$cvfile"
  fi

  debug_args "$node"
  msg="$(k "${DEBUG_ARGS[@]}" 2>&1)" \
    || { printf '%s\n' "$msg" >&2; RESULTS+=("$node: kubectl debug failed"); FAILED=1; continue; }
  pod="$(printf '%s\n' "$msg" | grep -o 'node-debugger-[^ ]*' | head -1 || true)"
  [ -n "$pod" ] || pod="$(find_debug_pod "$node")"
  [ -n "$pod" ] || { printf '%s\n' "$msg" >&2; RESULTS+=("$node: could not find debug pod"); FAILED=1; continue; }
  info "debug pod $pod"

  if ! wait_for_pod "$pod"; then
    RESULTS+=("$node: POD DID NOT START"); FAILED=1
    [ "$KEEP_POD" = true ] || k delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    continue
  fi
  echo

  logfile="$(mktemp "${TMPDIR:-/tmp}/gpu-diag.XXXXXX")"
  CVFILE="$cvfile"
  if [ "$LOCAL" = true ]; then
    run_local "$pod" 2>&1 | tee "$logfile" &
  else
    k logs -f "$pod" -c debugger | tee "$logfile" &
  fi
  follower=$!
  copy_reports "$pod" || FAILED=1
  sleep 2; kill "$follower" 2>/dev/null || true; wait "$follower" 2>/dev/null || true

  result="$(grep -m1 '^\[gpu-diag\] RESULT:' "$logfile" | sed 's/^\[gpu-diag\] RESULT: //')"
  if [ -z "$result" ]; then
    result="$(grep -m1 '^\[gpu-diag\] ERROR:' "$logfile" | sed 's/^\[gpu-diag\] //')"
    result="$node: ${result:-no RESULT line in pod output (pod phase: $(pod_phase "$pod"))}"
    FAILED=1
  fi
  rm -f "$logfile" "$cvfile"
  case "$result" in *CRITICAL*|*"SCRIPT ERROR"*) FAILED=1 ;; esac
  RESULTS+=("$result")

  if [ "$KEEP_POD" = true ]; then
    info "keeping debug pod $pod (delete with: kubectl delete pod $pod)"
  else
    k delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  fi
done

echo
info "summary"
for r in "${RESULTS[@]}"; do printf '    %s\n' "$r"; done
if [ ${#SAVED[@]} -gt 0 ]; then
  echo
  info "reports saved locally:"
  for f in "${SAVED[@]}"; do printf '    %s\n' "$f"; done
fi
exit "$FAILED"
