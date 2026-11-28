# Remove the descheduler from klusse

- Status: accepted
- Date: 2026-11-21
- Related: [the Docker orbs ADR](2026-11-19-docker-orbs-in-runner-vms.md)

## Context

The descheduler was added in #144. Every 10 minutes it ran one profile,
`rebalance-workers`, with `LowNodeUtilization`. That profile balanced the two
workers by pod count, with 20 % low and 25 % target thresholds of the 110 pods a
node allows. It ignored control-plane nodes, evicted at most 5 pods per node
and left pods with volume claims alone. Its job was to spread pods out again
after a rolling reboot left most of them on the worker that rebooted first.

klusse is being refocused on hosting orbs, and the descheduler never moved pods
with volume claims. That left it rebalancing only stateless pods, whose
placement after a reboot matters little on a two-worker cluster. Nothing else
in the repository depends on it.

## Decision

Remove the descheduler's HelmRepository and HelmRelease
(`infrastructure/controllers/descheduler.yaml`). Flux prunes both, and
helm-controller uninstalls the chart's CronJob and RBAC. The descheduler holds no
state, Secrets, alerts or dashboards.

## Consequences

- After a rolling reboot, pods stay where they were rescheduled until they
  restart or a maintainer deletes them so their controllers place them again.
- To restore it, bring back `descheduler.yaml` from #144, list it in
  `infrastructure/controllers/kustomization.yaml` and restore its sentence in
  `local-kubernetes/README.md`. Check the chart version and the
  `DefaultEvictor` arguments against the current upstream release first.
