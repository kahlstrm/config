# orb-storage

```sh
nix develop .#talos --command just talos run orb-storage
```

w3's `orb-storage` user volume on a worker running production's stack. The
worker gets production's template on a second disk, but not
`orb-dedicated-worker.yaml`, whose taint would keep the bench's probes off it.

The test asserts:

- The volume is mounted without project quotas. After its document gains
  [templates/project-quota.yaml](../../../../local-talos/templates/project-quota.yaml)
  as w3's does, and the worker reboots, it reports `projectQuotaSupport: true`
  and still holds a file written before, so it was not reformatted.
- With production's OpenEBS installed through Flux, a hostpath class on that
  volume with `XFSQuota` stops writes to a 1 GiB claim at 1 GiB.

`results.txt` records the volume's mount status and each pod's log.
