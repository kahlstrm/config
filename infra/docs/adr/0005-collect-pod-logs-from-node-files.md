# 5. Collect pod logs from each node's log files

- Status: accepted
- Date: 2026-10-26

## Context

Alloy ships pod logs to Loki. It used to run `loki.source.kubernetes`, which
follows each container's logs through the Kubernetes API, the same way
`kubectl logs -f` does. Every Alloy pod in the DaemonSet followed every
container in the cluster, so each container's logs were streamed once per
Alloy pod.

The kubelet serves a follow stream with `waitLogs` in
`k8s.io/cri-client/pkg/logs`. On each entry and on each log write, it asks
containerd whether the container is still running (`ContainerStatus`). With
~50 containers on w1 that came to ~99 `ContainerStatus` calls per second, at
~3 ms of containerd CPU each on w1's i9-12900H. containerd spent ~0.3 cores
and kubelet ~0.15 cores serving under 3 KB/s of logs. A kubelet CPU profile
(`/debug/pprof/profile` through the node proxy) traced 96% of the calls to
`ReadLogs`.

## Decision

Each Alloy pod discovers only the pods on its own node
(`spec.nodeName=$HOSTNAME`) and tails their files under `/var/log/pods` with
`local.file_match` and `loki.source.file`. `stage.cri` parses the CRI log
format that kubelet used to strip
([alloy.yaml](../../local-kubernetes/platform/alloy/alloy.yaml)).

Reconsider if Alloy must run without host access, or if the kubelet stops
polling the runtime while following logs.

## Consequences

- The `alloy` namespace enforces Pod Security `privileged` for the hostPath
  mounts of `/var/log` and `/var/lib/alloy`, and holds only Alloy.
- A node's logs are readable only on that node, so the DaemonSet tolerates the
  control-plane taint and runs on every node. A new taint needs a matching
  toleration, or that node's logs stop reaching Loki without any error.
- Read positions live in `/var/lib/alloy` on the node, so a restarted Alloy pod
  resumes where it stopped. Without them, it re-reads every file from the
  start, and Loki rejects or drops entries it already has.
- Log streams carry `namespace`, `pod`, `container`, `app`, `node` and
  `stream`. The `job` and `instance` labels that `loki.source.kubernetes` added
  are gone.
- Alloy tails only the current `*.log` file. Lines written while Alloy is down
  are lost if kubelet rotates that file (at 10 MiB by default) before Alloy
  comes back.
