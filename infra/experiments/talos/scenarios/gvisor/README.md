# gvisor

```sh
nix develop .#talos --command just talos run gvisor
```

The runtime handlers of a worker on production's `orb_worker` schematic
([schematics/orb-worker.yaml](../../../../local-talos/schematics/orb-worker.yaml))
with [orb-gvisor-worker.yaml](../../../../local-talos/patches/orb-gvisor-worker.yaml),
on production's Flannel stack. Every node boots that schematic's Image Factory
initramfs, pinned in [assets.nix](../../assets.nix), and installs its
installer, which it boots from after the install; the kernel is the
release's. The worker also gets `userns-worker.yaml`, which gVisor needs, but
not `orb-dedicated-worker.yaml`, whose taint would keep the bench's probes off
it.

The test asserts:

- Image Factory gives `orb-worker.yaml` the schematic ID that `assets.nix`
  fetches, and the worker runs that schematic and the `gvisor` extension.
- The worker has `vm.max_map_count` 4194304, `/etc/runsc-docker.toml` and the
  `runsc-docker` runtime in the merged CRI configuration.
- A pod each under runc, `gvisor` (handler `runsc`) and `gvisor-docker`
  (handler `runsc-docker`), all with `NET_RAW`, runs to completion. Only the
  two gVisor pods see a kernel other than the node's, and only runc and
  `gvisor-docker` may write to a packet socket on the pod's interface.
- Under `gvisor-docker` with all capabilities, dockerd starts as gVisor's
  Docker guide starts it, and a nested container runs and reaches the external
  address through the pod's own NAT.

`results.txt` records the worker's extensions and files and each pod's log.
