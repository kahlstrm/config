# Network diagnostics

Record test conditions, configuration changes and conclusions in [JOURNAL.md](JOURNAL.md).
Keep raw measurements under `~/.local/state/` on the host running the test.

## Minimal iperf image

`iperf3-image.nix` builds iperf3 and its runtime closure from this repository's
locked nixpkgs. It runs as UID/GID 65532 and needs writable `/tmp` for stream
buffers. The image contains no general-purpose diagnostic toolkit.

```sh
nix build .#iperf3-image --out-link /tmp/infra-iperf3-image
docker load -i /tmp/infra-iperf3-image
docker run --rm harbor.kube.kalski.xyz/library/iperf3:3.19 --version
docker push harbor.kube.kalski.xyz/library/iperf3:3.19
```

The tag follows the iperf3 version in the lock file. When updating it, validate
both sending and receiving with a read-only root filesystem, all capabilities
dropped, and a writable `/tmp` tmpfs. Update the workload's image digest to the
digest returned by Harbor after pushing.

## Router throughput endpoint

Flux deploys it from `local-kubernetes/apps/router-throughput/`.
Merge the Git change and let Flux reconcile it; do not apply the workload directly.
The existing `monitoring-privileged` namespace permits host networking. The
containers themselves are non-root, have no capabilities, and are not privileged.

The deployment runs on w1, whose LAN address is `10.10.10.21`, and listens on
TCP ports 5201 and 5202. Host networking avoids the CNI and Service path.
`Recreate` prevents an update from launching competing listeners on the same node.
There is no CPU limit, to avoid measuring container CPU throttling as a router limit.

Before testing from pannu, pause the WAN sweeps and verify the routes cross the
physical transit link in both directions. Check w1's link speed, both router
transit speeds and FastTrack counters. Record separate upload/download and
simultaneous runs, including per-core router CPU samples. FastTracked LAN traffic
does not reproduce the WAN firewall/CAKE processing path.

To retire the endpoint through GitOps, set its deployment replicas to zero and
merge that change first. Then remove the application and workload manifests.

## Daytime CAKE monitor

`daytime-cake-monitor.py` periodically runs simultaneous iperf transfers while
measuring latency to the router, modem and two public resolvers. With
`--diagnose-drops`, a flagged trial immediately triggers separate upload,
download and simultaneous retries. Store its raw output outside the repository:

```sh
python3 experiments/network-diagnostics/daytime-cake-monitor.py \
  --output ~/.local/state/cake-day-monitor \
  --host poenttoe \
  --hours 24 \
  --interval-seconds 600 \
  --interval-jitter-seconds 180 \
  --minimum-download-mbps 450 \
  --minimum-upload-mbps 42 \
  --maximum-latency-delta-ms 10 \
  --diagnose-drops
```
