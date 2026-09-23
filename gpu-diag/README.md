
# GPU Diag

Contained here is a couple testing tools for Nvidia hardware running on Linux servers, they've mostly been testing on Consumer RTX 3XXX series along with RTX 4000 Ada series machines. Testing for RTX 6000 Blackwells is in progress. 

gpu-diag.sh is the primary troubleshooting tool. It scans every NVIDIA GPU in the VM and checks: PCI presence and bound driver, PCIe link/AER (where the guest exposes it), kernel module and device nodes, kernel events across all retained boots (Xid codes, fallen-off-bus, AER, driver init failures, with context), user-space journal warnings, containerd/NVIDIA Container Toolkit wiring, and per-GPU nvidia-smi state (ECC, row remapping, throttling, thermals, clocks). Every section prints the exact command it ran as a `$ …` line above its output, so any finding can be reproduced by hand on the node. It exits 0/1/2 for OK/WARN/CRIT and writes a JSON report with `findings[]` (each with the `command` that gathered its evidence), `sources[]` (check name → command), `host{}`, `pcie[]`, `events{}` and one object per GPU in `gpus[]`. The container for k8s runs the same script; however, it will run it as an ephemeral pod on a specific node, then save the report locally for the cluster operator. This is designed for Linode Kubernetes Engine Clusters; however, it can be used anywhere post through testing is completed. 

## Running it on a Kubernetes node

The `k8s/` directory is only a wrapper around `kubectl debug`. The image is
`busybox` plus a small shell script. When it starts on a node it downloads
the **current** `gpu-diag.sh` from this repo and runs it on the node itself,
with the node's own `bash`, `nvidia-smi`, `lspci`, `dmesg`, `journalctl` and
friends. The wrapper does not need to change when the script does.

**Deploy command.** From any machine with `kubectl` access to the cluster,
no checkout needed:

```
curl -fsSL https://raw.githubusercontent.com/WoodardDigital/scripts/main/gpu-diag/k8s/run.sh | bash -s -- <node>
```

That runs the diagnostic on the node and saves
`./reports/<node>-<utc-timestamp>.log` and `.json` on **your machine**, then
deletes the debug pod. From a checkout the same thing is `k8s/run.sh <node>`.

If you only want to poke at a node interactively, the underlying command is:

```
kubectl debug node/<node> -it --profile=sysadmin --image=ghcr.io/woodarddigital/gpu-diag
```

It streams the report and drops you into a shell on the pod with the files in
`/output`, but nothing is copied off the pod: you would `kubectl cp` them from
a second terminal before typing `exit`, then delete the `node-debugger-…`
pod. Inside that shell, `host <command>` runs a command on the node, e.g.
`host nvidia-smi`.

### What run.sh does

`k8s/run.sh` wraps the same `kubectl debug` call non-interactively. Before
launching the pod it prints a cluster-side view of the node (Ready/cordon
state, `nvidia.com/gpu` capacity vs allocatable vs requested, which pods hold
GPUs, taints, GPU Feature Discovery labels, NVIDIA/GPU Operator pod health,
the operator's own CUDA/driver validator logs, node Warning events). Then it
streams the node report, copies the `.log`/`.json` into `./reports/` on your
machine with the cluster view prepended to the `.log`, and deletes the debug
pod. `--cuda-test` additionally runs a one-shot vectorAdd pod requesting one
`nvidia.com/gpu` (it reports "GPU held by another pod" rather than failing
when none is free).

```
cd gpu-diag/k8s                              # or: curl -fsSL <run.sh url> | bash -s -- <args>
./run.sh <node>                              # one node
./run.sh node-a node-b                       # several, one after another
./run.sh -l nvidia.com/gpu.present=true      # every node matching a label selector
./run.sh -o ~/cases/1234 <node>              # save reports somewhere else
./run.sh --cuda-test <node>                  # also run a CUDA vectorAdd pod on the node
./run.sh --dry-run <node>                    # just print the kubectl debug command
```

```
==> summary
    CRITICAL on lke12345-67890-abcdef

==> reports saved locally:
    ./reports/lke12345-67890-abcdef-20260923T131004Z.log
    ./reports/lke12345-67890-abcdef-20260923T131004Z.json
```

`.log` is the full output as shown in the terminal, `.json` is the script's
machine-readable summary.

### Trying it without publishing anything

Nothing has to be pushed to GitHub or GHCR. `--local` starts a stock
`busybox` pod with `kubectl debug`, copies this checkout's `entrypoint.sh`
and `gpu-diag.sh` into it with `kubectl cp`, and runs them there:

```
cd gpu-diag/k8s
./run.sh --local <node>
./run.sh --local --dry-run <node>     # shows the four kubectl commands it will run
```

The same thing by hand, interactively (ends in a shell on the pod):

```
kubectl debug node/<node> --profile=sysadmin --image=busybox:1.36.1 --env NVIDIA_VISIBLE_DEVICES=void -- sleep 7200
kubectl cp k8s/entrypoint.sh <pod>:/tmp/entrypoint.sh
kubectl cp gpu-diag.sh       <pod>:/tmp/gpu-diag.sh
kubectl exec -it <pod> -- env SCRIPT_SOURCE=image IMAGE_SCRIPT=/tmp/gpu-diag.sh sh /tmp/entrypoint.sh
kubectl delete pod <pod>                # when done
```

This is also the way to test an edited `gpu-diag.sh` or `entrypoint.sh`
before committing.

### Which script version runs

| | `kubectl debug … --env` | `run.sh` |
|---|---|---|
| `main` of this repo (default) | — | — |
| another branch/tag/commit | `--env SCRIPT_REF=<ref>` | `--ref <ref>` |
| any URL | `--env SCRIPT_URL=<url>` | `--script-url <url>` |
| copy baked into the image (offline) | `--env SCRIPT_SOURCE=image` | `--image-script` |

If the download fails the wrapper falls back to the copy baked into the
image and says so. The report header always prints the source and the
sha256 of the script that actually ran.

### How it works

- `kubectl debug node/…` gives the pod the node's PID and network
  namespaces and mounts the node's root at `/host`. `--profile=sysadmin`
  makes it privileged, which is what lets the wrapper `nsenter` into PID 1
  and run the script with the node's tools and full access to `/dev/nvidia*`
  and `dmesg`. Without `sysadmin` (the default `general` profile) the wrapper
  falls back to `chroot /host`; GPU device and kernel-log access are then
  blocked and the report header says loudly that those findings cannot be
  trusted.
- The script text is fetched with busybox `wget` (falling back to the node's
  `curl`/`wget` if the pod has no egress) and passed to the node's `bash` as
  an argument; its JSON is written through an inherited file descriptor. The
  wrapper writes nothing to the node's filesystem.
- The image sets `NVIDIA_VISIBLE_DEVICES=void` so the NVIDIA container
  runtime hook stays out of the way and the pod starts even when the driver
  is broken, which is exactly when you need it.
- The image is built by `.github/workflows/gpu-diag-image.yml` on every push
  to `main` that touches `gpu-diag/k8s/` or the script, and pushed to
  `ghcr.io/woodarddigital/gpu-diag` (`latest` plus a short-sha tag).

### Requirements and caveats

- kubectl 1.28 or newer for `--profile=sysadmin`, and rights to create a
  privileged pod in the target namespace (`-n`). If Pod Security Admission
  enforces `restricted`/`baseline` there, use a namespace labelled
  `pod-security.kubernetes.io/enforce=privileged`, or `kube-system`.
  OpenShift needs the `privileged` SCC.
- The node OS must have `bash` (LKE Debian/Ubuntu images do). Talos and
  Bottlerocket do not; the wrapper reports that and stops.
- The GHCR package must be public (or nodes need an image pull secret).
- `kubectl debug node` never cleans up its pods. `run.sh` deletes them;
  after an interactive session delete the `node-debugger-…` pod yourself.
