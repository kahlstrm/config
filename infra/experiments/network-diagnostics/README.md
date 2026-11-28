# Network diagnostics

Record test conditions, configuration changes and conclusions in [JOURNAL.md](JOURNAL.md).
Keep raw measurements under `~/.local/state/` on the host running the test.

## Router throughput tests

The in-cluster router throughput endpoint and its iperf3 image are gone; see
[the Harbor removal ADR](../../docs/adr/2026-11-21-remove-harbor-from-klusse.md).
For a one-off routed LAN test, run an ad hoc iperf3 pod with host networking in
`monitoring-privileged` on a worker and delete it afterwards. Before testing
from pannu, pause the WAN sweeps and verify the routes cross the physical
transit link in both directions. Check the worker's link speed, both router
transit speeds and FastTrack counters. FastTracked LAN traffic does not
reproduce the WAN firewall/CAKE processing path.

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
