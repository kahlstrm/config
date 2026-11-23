# Make room on pannu for the runner's test VMs

- Status: accepted
- Date: 2026-11-23
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the temporary compute runners ADR](2026-11-14-temporary-compute-runners.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the agent VM placement ADR](2026-11-08-agent-vm-placement.md)

## Context

pannu's host runner, as the `amp` user, runs test VMs such as a Kata and Talos
lab, with a 40 GiB disk for Kata. The agents VM took 32 GiB of pannu's memory,
which left such a VM about 20 GiB, and the runner's home,
`/var/lib/amp-runner`, sat on `/`, which had about 75 GB free.

The agents partition (`/mnt/agents`, 341 GiB) holds the VMs' disk images,
which include the agents and ops VMs' credentials, so `amp` must not read
them. On 2026-11-23 it had 131 GiB free with 192 GiB used. The VMs' volumes
total 270 GiB and each VM reserves its volumes in full when it starts, so they
may still take about 78 GiB of that, leaving about 53 GiB. The runner's home
held 186 MiB.

## Decision

- **The agents VM shrinks to 8 cores and 16 GiB** (`local.agentVMs.agents` in
  `machines/pannu.nix`; its QEMU unit's `MemoryMax` follows at 18 GiB).
- **The runner lives on the agents partition.** A plain directory,
  `/mnt/agents/amp` (owned by `amp`, mode 0700), is bind-mounted at
  `/var/lib/amp-runner`, the runner's state directory, home and working
  directory, so the runner's paths stay as they were. Its first start copies
  the old home into it.
- **No size limit.** The runner shares the partition's unreserved space with
  the VMs' volumes.
- **`/mnt/agents` stays 0750 `microvm:kvm`.** `amp` reaches its directory only
  through the bind mount, so it needs no search right on `/mnt/agents`, and the
  VMs' disks stay protected by that directory's mode alone, whatever their own
  modes. `tests/agent-storage.nix` checks, with pannu's `amp` user and groups,
  that `amp` writes to its home and can neither list `/mnt/agents` nor read or
  write any VM image in pannu's configuration.
- **Setting up the mount never fails a switch.** `amp-runner-storage` mounts
  the directory only once it is complete, and on any failure, such as a missing
  partition, it warns and leaves the runner on `/`, so a deploy run from the
  runner does not roll back over it.

## Consequences

- The agents VM's T3 agent and its `pannu-agents` runner share 16 GiB. The new
  size takes effect only on `systemctl restart microvm@agents`, which ends the
  VM's sessions; a host switch only stages it.
- The runner can fill the partition. A VM that starts after that cannot
  reserve its volumes, gets a warning, and its guest may hit write errors when
  its images grow. The agents VM's next restart reserves its remaining volume
  space, so running it before the runner's labs grow keeps the VMs' share.
- The runner's old home stays on `/` beneath the mount until removed by hand.
  If the mount is missing at a later start, the runner works from that old
  copy.
- Opening `/mnt/agents` to `amp` (mode 0711) would let it reach its directory
  by that path too, but then each VM image's own mode would protect it, and
  nothing in the configuration sets those modes.
