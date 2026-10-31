# Talos Cluster

Apply `local-networking` first. Node configuration and installer images live in
[main.tf](main.tf), which passes them to the
[talos-cluster](../modules/talos-cluster) module, which owns the secrets,
machine configurations, nodes and bootstrap. [flux.tf](flux.tf) adds the Flux Operator and
[the FluxInstance](manifests/flux-instance.yaml) to the control-plane config;
Talos creates them and Flux then reconciles
[local-kubernetes](../local-kubernetes/README.md).

## Apply

Run from this directory:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

For new nodes, configure networking first, boot Talos, and add the node to
`main.tf`. Check installation disks with `talosctl get disks --insecure --nodes <node-ip>`.

## External Secrets Access

[external-secrets.tf](external-secrets.tf) creates the `local-kubernetes`
secret and lets the External Secrets Operator read it through workload identity
federation. GCP checks the operator's service-account tokens against
[the cluster's public keys](service-account-jwks.json); there is no key file.
The ClusterSecretStore in `local-kubernetes` uses the
`external_secrets_audience` output.

## Access

```bash
terraform output -raw talosconfig > ~/.talos/config
terraform output -raw kubeconfig > ~/.kube/talos-config
export KUBECONFIG=~/.kube/talos-config
talosctl -n 10.10.10.11 health   # health takes exactly one node
kubectl get nodes
```

The Kubernetes API endpoint is `https://api.k8s.kalski.xyz:6443`, a DNS name
for a shared address (`k8s_api` in local-networking) that Talos moves to a
healthy control plane, so the API stays reachable while one is down. Point
`talosctl` at the node addresses instead; the shared address only works while
etcd is healthy. Service-account tokens keep the original issuer,
`https://10.10.10.11:6443`, which workload identity federation trusts.

Talos also derives the API server's accepted token audience (`api-audiences`)
from the endpoint. Changing the endpoint therefore rejects every token issued
before the change until it rotates, and processes that keep the token in memory
fail until restarted. To change the endpoint, first list both audiences in
`cluster.apiServer.extraArgs["api-audiences"]` (comma-separated), and drop the
old one once all tokens have rotated.

## Network Policies

Flannel enforces Kubernetes NetworkPolicies through
[kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies),
which Talos runs as a second container in the Flannel DaemonSet
([flannel-controlplane.yaml](../modules/talos-cluster/cni/flannel-controlplane.yaml)).
It checks the first packet of each new connection against the policies. If the
container stops, traffic is allowed rather than dropped. Traffic from root
processes on the node, such as kubelet probes, always passes.

The kernel silently drops new connections from policed pods while a node-wide
packet socket is open, such as FRR's or `tcpdump -i any`; see
[ADR 2](../docs/adr/0002-no-node-wide-packet-sockets-under-network-policies.md).
Policies also apply to a new pod only after about two seconds; see
[ADR 4](../docs/adr/0004-network-policies-apply-seconds-after-pod-start.md).

Talos only creates missing manifests on its own, so after changing the Flannel
settings, sync the running cluster with `talosctl upgrade-k8s --to <current
Kubernetes version>`.

## Cilium

`cni` in [main.tf](main.tf) selects the pod network, and the
[talos-cluster](../modules/talos-cluster) module adds its patches:

- `flannel`: Talos's Flannel with kube-network-policies, and kube-proxy, as
  described above.
- `cilium`: no Talos CNI (`cluster.network.cni.name: none`) and no kube-proxy
  on every node, and [manifests/cilium.yaml](manifests/cilium.yaml) as an
  inline manifest on the control planes, so Talos owns Cilium as it owns the
  Flux Operator ([ADR 8](../docs/adr/0008-replace-flannel-with-cilium.md)).

The switch exists for the migration from Flannel. Changing it is not a plain
apply. The first control plane's new config makes Talos install the new CNI on
every node at once, and each node's pods lose their network as its agent
starts, until they are recreated. Every control plane must render the same
manifests before `upgrade-k8s` prunes the old CNI, and every node needs a
reboot afterwards; going back to Flannel also needs one before new pods start
again. The
[cilium-terraform](../experiments/talos/scenarios/cilium-terraform/README.md)
lab scenario rehearses the gated sequence on production's topology, and
[cilium-terraform-abort](../experiments/talos/scenarios/cilium-terraform-abort/README.md)
going back after the first control plane.

Pods left on the previous network are recreated through their owners with
`cni-pods`, which lists Job, standalone and other pods it leaves alone; see
[Recreating pods](../experiments/talos/README.md#recreating-pods-after-the-switch).
`recreate` needs a cluster administrator's kubeconfig, as it reads
CiliumEndpoints; `plan` and `verify` also run with read-only access. All
three find Flannel's leftover `cni0` bridges with `talosctl`:

```bash
nix run .#cni-pods -- plan       # from infra/
nix run .#cni-pods -- recreate   # administrator; -include namespace/pod,... for report-only pods
nix run .#cni-pods -- verify -cni flannel   # after going back to Flannel
```

After going back to Flannel, a node whose Cilium agent was killed can keep
Cilium's CNI config; inspect and repair each node with
[cni-repair.yaml](cni-repair.yaml), as its header shows.

[cilium/chart.json](cilium/chart.json) pins the chart version and hash, and
[cilium/values.yaml](cilium/values.yaml) holds the values: IPAM from
Kubernetes, kube-proxy replacement, the API through KubePrism
(`localhost:7445`), Talos's capabilities and cgroup settings, Hubble relay
with certificates from a CronJob (so no keys land in the machine config), and
pod restarts when their configuration changes. The operator, whose garbage
collection removes stale CiliumEndpoints, gets CPU and memory requests (no
CPU limit), prefers the workers over the control planes, and keeps its two
replicas on different nodes; Hubble Relay gets requests too. Hubble serves drop, flow and
policy-verdict metrics on each node's port 9965; nothing scrapes them yet,
because the chart's ServiceMonitor needs the Prometheus Operator CRDs, which
Flux installs after Cilium. The [Talos lab](../experiments/talos/README.md)
uses the same pin, values and manifest.

`manifests/cilium.yaml` is the `helm template` output, passed through
[cilium/post-render.yq](cilium/post-render.yq) for what the chart's values
cannot set (the operator's liveness probe tolerates two minutes of failures
instead of 30 s), committed so reviews show what reaches the cluster.
Re-render it after changing the pin, the values, the post-render or
`kubernetes` in [versions.json](versions.json):

```bash
nix develop --command just cilium-render   # from infra/
```

The `cilium-manifest` flake check, which CI runs, fails while the committed
render is stale.

To upgrade Cilium or change its values while `cni` is `cilium`:

1. Bump `version` in `cilium/chart.json`, set `hash` to the one Nix reports
   for the new chart, re-render and review the manifest diff. Bump the lab's
   older release (`ciliumPrevious` in
   [assets.nix](../experiments/talos/assets.nix)) to the previous pin, so its
   `cilium-upgrade` scenario rehearses this upgrade.
2. Apply the control planes one at a time, as in [OS upgrades](#os-upgrades).
   Workers do not carry the manifest. Talos only creates missing objects, so
   running Cilium is unchanged so far.
3. Update the running cluster:

   ```bash
   talosctl -n 10.10.10.11 upgrade-k8s --to <current Kubernetes version> --dry-run
   talosctl -n 10.10.10.11 upgrade-k8s --to <current Kubernetes version>
   ```

   The agents and operator restart on the new configuration.

## Rebooting Nodes

Reboot one node at a time, and a control plane only while all three etcd
members are healthy, so two stay up throughout:

```bash
CPS=10.10.10.11,10.10.10.12,10.10.10.13
talosctl -n $CPS etcd status    # three rows, one LEADER, empty ERRORS
talosctl -n 10.10.10.11 etcd members
talosctl -n $CPS get addresses | grep 10.10.10.10/32   # holds the API address
```

Reboot the node holding the API address and the etcd leader separately. If
one control plane is both, move leadership first with
`talosctl -n <ip> etcd forfeit-leadership`. Then:

```bash
talosctl -n <ip> reboot --wait
kubectl wait --for=condition=Ready node/<name> --timeout=10m
talosctl -n $CPS etcd status    # all three healthy again before the next
```

Before the next node, wait for its DaemonSet pods (the CNI's above all) and
for every workload to be ready again.

Rolling back a CNI switch is the exception. Pods whose network the abandoned
CNI set up recover only when their own node reboots, so between nodes wait
only for the rebooted node to be Ready, the restored CNI's DaemonSet
(`kube-flannel`) to run on it and, after a control plane, etcd to have all
three members. Wait for every workload once all nodes have rebooted.

## Flux Operator Upgrades

Talos owns the operator and the `FluxInstance`; Flux does not manage them. The
operator upgrades Flux itself within the `FluxInstance` version range. To
upgrade the operator or change the `FluxInstance`, edit [flux.tf](flux.tf) or
the manifest, apply, then sync the running cluster:

```bash
talosctl upgrade-k8s --to <current Kubernetes version> --dry-run
talosctl upgrade-k8s --to <current Kubernetes version>
```

Talos only creates missing manifests on its own; `upgrade-k8s` updates them and,
from Talos 1.13, deletes ones removed from the config.

## Raspberry Pi 5 Installer

Upstream's `rpi_5` overlay ships a U-Boot without RP1 or working NVMe boot.
[rpi5-installer](rpi5-installer) replaces it with the `rpi5-u-boot` output of
[kahlstrm/u-boot](https://github.com/kahlstrm/u-boot) (branch `jetkvm-rpi5`),
pinned in [flake.nix](../flake.nix): RP1 and NVMe boot support, USB fixes
that let U-Boot use a JetKVM's virtual disk and keyboard, and runtime EFI
variables. Talos writes its boot entries during installs and upgrades; without
them the installer stops before writing U-Boot and the device trees, yet the
node still reboots into the new Talos version. The variables last only until
the next reboot; see
[ADR 1](../docs/adr/0001-pi5-sd-boot-with-volatile-efi-variables.md).
[versions.json](versions.json) pins the Talos and overlay versions.

The `Talos Raspberry Pi 5 installer` workflow builds the installer on pull
requests. On `main` it publishes `ghcr.io/kahlstrm/talos-installer-rpi5:<talos>`.
Existing tags are kept, so to roll a U-Boot or overlay change into the current
Talos version, dispatch the workflow with `overwrite`. The package must be
public, because nodes pull it without credentials.

The build renders the EFI files the installer writes to a node: U-Boot, the
Pi 5 device trees and `config.txt`. It fails unless they match
[verified-boot.sha256](rpi5-installer/verified-boot.sha256), which records the
boot chain verified on a control plane. The build is reproducible, so the
hashes stay stable. To change any of these files deliberately, boot the new
U-Boot on a control plane first with the fork's JetKVM launcher image (see its
`jetkvm/README.md`), which leaves the node's disks untouched, then update the
pin and the hashes in the same commit.

Build it locally with:

```bash
nix shell --inputs-from .. nixpkgs#crane nixpkgs#jq --command rpi5-installer/build.sh _out
```

## OS Upgrades

[versions.json](versions.json) holds the Talos version for all nodes.
Raspberry Pi 5 control planes use the installer above; workers use an Image
Factory installer. `talos_machine` upgrades a node whenever its running version
differs from the installer tag. All nodes are `for_each` instances, so an
untargeted apply after a version bump upgrades them all at once and loses etcd
quorum. Keep `talos_machine_configuration.talos_version` at the cluster's
original contract version.

Upgrade one Talos minor at a time:

1. Bump `talos` in `versions.json` and merge. Wait for the installer workflow
   to publish the new tag.
2. Upgrade a control plane only with its UART console attached. Recovery is a
   PoE port toggle on kuberack, plus UART or JetKVM virtual media. Rollback,
   downgrades and same-version UKI changes do not take effect on their own;
   see [ADR 1](../docs/adr/0001-pi5-sd-boot-with-volatile-efi-variables.md).
   Record the starting version with `talosctl -n <ip> version`.
3. Apply each node on its own, starting with c1, then c2, c3, w1, and w2:

   ```bash
   terraform apply -target='module.cluster.talos_machine.controlplane["c1.k8s.kalski.xyz"]'
   talosctl -n 10.10.10.11 health
   talosctl -n 10.10.10.11 etcd status
   ```

   A worker's `talos_machine` depends on every control plane's (through the
   kubeconfig and the bootstrap), so targeting a worker also applies any
   pending control-plane change; finish the control planes first.

   Follow `talosctl -n <node> dmesg -f` during the apply. The provider only
   waits for the new version to boot, so it reports success even when the
   installer fails. The log must show `upgrade completed` with `exit_code=0`
   before the reboot. Talos streams the installer's own output only to the API
   client, which the provider discards; the exit code covers the board step
   too, as any installer failure exits non-zero.
   Continue only once etcd has all members, and `talosctl health` (run against
   a control plane, also for workers) and `kubectl get nodes` are healthy. If etcd or the pause container fails with
   `exec format error`, the cached image files are corrupt (zero bytes). Remove
   those images and re-pull them.
4. Finish with an untargeted `terraform plan`. It must show no `talos_machine`
   changes.

Kubernetes stays on `kubernetes` in `versions.json` while Talos is upgraded.
Upgrade it afterwards, one minor at a time, with
`talosctl -n 10.10.10.11 upgrade-k8s --to <version>`. Then set the same
version in `versions.json` before the next apply; an apply in between reverts
the component images.

Run it with `--dry-run` first. The manifest diff also carries Talos's current
defaults, such as newer Flannel and CoreDNS images. On nodes older than Talos
1.13 it replaces each manifest whole, dropping fields other controllers added;
flux-operator restores its labels on the `flux-system` namespace when it
restarts.
