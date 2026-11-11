# AGENTS.md

Run commands in this guide from `~/config/infra`, unless a layer directory is
specified. Machine and user configuration lives at the repository root and has
its own flake. Infrastructure CI lives in `../.github/workflows/`.

## Development Environment

```bash
nix develop                              # Enter dev shell (terraform, gcloud, just, talosctl, kubectl)
gcloud auth application-default login    # Authenticate to GCP
```

## Layer Commands

Each infrastructure layer is applied separately in order:

```bash
# State bucket and the appliers' service accounts (a maintainer's machine only)
cd gcp-project && terraform init && terraform plan && terraform apply

# Networking layer (MikroTik routers, DHCP, DNS, ZeroTier): agents apply it through
# infra-apply on pannu (see Applying Changes); a maintainer's machine runs it directly
cd local-networking && terraform init && terraform validate && terraform plan && terraform apply

# Talos Kubernetes cluster (depends on local-networking via remote state)
cd local-talos && terraform init && terraform plan && terraform apply

# Hetzner cloud resources
cd hetzner-infra && terraform init && terraform plan && terraform apply
```

Site-specific applies must include the matching bootstrap module, e.g.
`terraform apply -target=module.stationary -target=module.bootstrap_stationary`
(use `kuberack` for both targets at that site).

Format all HCL: `terraform fmt -recursive`

If infrastructure-as-code configuration exists, always use it for infrastructure
changes, including temporary resources and experiments.

## Applying Changes

Frictionless first, guardrails second: when told to ship, an agent merges its own
PR once `sol-loop` approves and CI is green, without waiting for a person's
approval. Before adding a guardrail or an approval prompt, test it against
[the frictionless shipping ADR](docs/adr/2026-11-10-agents-ship-without-approvals.md).

Agents open PRs and verify results through Git and read-only access: `kubectl`
on the klusse runner, or on pannu's runner while that one is down, and on the
agents VM, which also has read-only `talosctl` (Talos `os:reader`). The agents
VM may also delete or evict pods so their controllers recreate them, and run test
pods in the `agent-sandbox` namespace, which reach only the pod network once
their policy applies, about two seconds after they start
([ADR 4](docs/adr/0004-network-policies-apply-seconds-after-pod-start.md)).

Apart from `local-networking` below, no agent holds admin credentials yet. Until
pannu runs the rest as root-owned units
([the ops retirement ADR](docs/adr/2026-11-10-retire-the-ops-vm.md)), a
maintainer runs from merged `main` on their machine: `terraform` for the other
layers, admin `talosctl`, `gcloud`, and imperative Kubernetes operations that
Flux can't do (cordons, maintenance pods, reads of what read-only access hides).
Nothing is delegated to the ops VM's T3.

`local-networking` applies run on pannu through `infra-apply`
(`modules/infra-apply`): root-owned units for each layer, `infra-plan@<layer>` and
`infra-apply@<layer>`, with the layer's own user and GCP account, which the pannu
runner starts but whose credentials it cannot read. Start a thread on runner
`pannu` after the PR merges and have it run `infra-apply plan local-networking`,
then `infra-apply apply local-networking`; both run without a prompt, in the
units' own checkout of merged `main`, on the whole layer, and print the units'
output (`infra-apply log local-networking` shows it again). The apply refuses if
`main` moved since the plan; plan again. Never run `terraform` against the layer
there. The plan prints a summary without values, naming the merged PRs it covers:
post it to those PRs and the requesting thread, and compare it with their
rollouts. The apply refuses deletions and replacements unless one of those PRs
carries `networking:allow-destroy`, and firewall or `ops_kuberack` user changes
unless one carries `networking:allow-access`. The agent that opens such a PR adds
the label and names in the description what is destroyed or which access
changes. The apply arms a dead-man switch on each router it touches; report a
restore it announces as an incident and fix forward with a new PR. Management
addresses, the routes between the sites and to the WAN, the WAN's IPv6 client and
the routers' REST and API services have `prevent_destroy`; a PR that removes one
lifts it in the same PR. A maintainer edits Secret Manager secrets with
`just edit` on their machine; `local-kubernetes` holds `sops_age_key`, and the
apply's account has no access to it. That path is temporary: each layer drops it
when it moves to the private secrets repository
([the private secrets repository ADR](docs/adr/2026-11-11-secrets-in-a-private-sops-repository.md)).

A PR that needs an apply describes it under `## Rollout`: the layers in order,
what each plan should show, and the checks afterwards. An apply handed to a
maintainer names the requesting thread's URL, where the result is reported. When
applying:

- Compare each plan with the rollout and stop if it shows anything else.
- Apply Talos node changes one node at a time with `-target`, control planes
  first, and run `talosctl -n <control plane> health` between nodes; see
  [OS upgrades](local-talos/README.md#os-upgrades).
- Check the Kubernetes API with `kubectl` (for example `kubectl get --raw
  /version`); it rejects anonymous requests.
- Report command output as-is, and stop on errors instead of working around them.
- Pass secrets only through environment variables of the command that needs
  them. Never print or paste them; one-time links go only to a maintainer.
- Apply `gcp-project` only from a maintainer's machine. It holds every
  applier's service account and grants, so an applier that applied it could
  widen its own access. Every GCP API enablement and IAM change belongs
  in this layer, not only in `gcloud`.

## Bootstrap and CHR tests

Bootstrap changes must regenerate and review `local-networking/bootstrap/generated/*.rsc`.
Run the isolated two-router test on Linux with `/dev/kvm`:

```sh
nix develop .#chr-bootstrap --command just chr run bootstrap
```

Keep scenarios under `experiments/chr/scenarios/`; see the [lab README](experiments/chr/README.md).
After bootstrap/reset, preview `just adopt-bootstrap --router stationary` (or `kuberack`);
add `--apply` to reconcile state, then review a Terraform plan. Use
`TF_VAR_ALLOW_INSECURE=true` only during bootstrap while the router presents its
self-signed certificate. Omit it from normal plans and applies once the managed
certificate is installed. Avoid concurrent state writes. See
[commissioning](local-networking/README.md#adopting-a-bootstrapped-router).

Static firewall rules, address lists, and filter ordering are owned by
`local-networking/modules/bootstrap/firewall.tf`, which also renders the bootstrap
script. Dynamic router rules stay unmanaged.

## Talos lab

Test cluster-level changes such as the CNI or NetworkPolicy enforcement on a
disposable QEMU cluster built from the production Talos versions and patches
(Linux with `/dev/kvm` and passwordless `sudo`):

```sh
nix develop .#talos --command just talos run netpol-baseline
```

Keep scenarios under `experiments/talos/scenarios/`; see the
[lab README](experiments/talos/README.md).

## T3 mobile lab

Test the T3 Code Android app's connection behaviour on a headless emulator,
built from a pinned upstream revision with optional patches (Linux with
`/dev/kvm`):

```sh
nix develop .#t3-mobile --command just t3-mobile run blocked-resume
```

See the [lab README](experiments/t3-mobile/README.md).

## Secret Management

Every secret is moving to sops files in a private repository; see
[the private secrets repository ADR](docs/adr/2026-11-11-secrets-in-a-private-sops-repository.md).
Until a layer reads from that repository, its secrets, new ones included,
follow the rules below and move with the rest of the layer.

Kubernetes Secrets live in Git and never come from Terraform. **Never create
Kubernetes secrets manually.**

- **Internet-usable credentials** (API tokens usable from anywhere, such as
  Cloudflare or Telegram) and **bearer URLs** (webhook URLs carrying their own
  token, such as the Amp alert intake webhook) go in the `local-kubernetes`
  secret in Google Secret Manager and reach the cluster through an
  `ExternalSecret`; see
  [local-kubernetes/README.md](local-kubernetes/README.md#secrets-from-secret-manager).
- **Everything else** (LAN-only passwords, generated app credentials) is a
  SOPS-encrypted Secret named `<secret-name>.sops.yaml` next to the app that uses
  it. Flux decrypts it; see
  [local-kubernetes/README.md](local-kubernetes/README.md#sops-encrypted-secrets).

### Editing Secret Manager secrets

Secrets are stored as JSON blobs in Google Secret Manager, named after the
directory. Run `just` commands from that directory:

```bash
just help           # Show available commands
just edit           # Edit the secret for the current directory (opens $EDITOR)
just view           # View current secret value
just clean --dry-run  # Preview old version cleanup
```

Terraform layers also read their own secrets this way, such as
`local-networking` for router credentials.

## Architecture

**Layered infrastructure with dependency ordering:**

```
gcp-project/          → State bucket, the appliers' service accounts and their grants
local-networking/     → Network foundation (MikroTik routers, DHCP, DNS, VPN)
    ↓ (remote state)
local-talos/          → Talos nodes, Flux bootstrap, Secret Manager access
    ↓ (GitOps)
local-kubernetes/
  ├── clusters/klusse/        → Flux entrypoint and layer dependencies
  ├── infrastructure/         → Flux: controllers, then their configs
  ├── platform/               → Flux: shared services (ingress, DNS, observability, registry)
  └── apps/                   → Flux: applications, one kustomization each
```

See [local-kubernetes/README.md](local-kubernetes/README.md) for Flux layers
and validation.

**local-networking modules:**
- `modules/kuberack/` and `modules/stationary/` - MikroTik router configs for each site
- `modules/rb5009/` - Shared RB5009 router configuration
- `modules/dhcp/`, `modules/dns/`, `modules/cert/` - Network services
- `modules/zerotier/` - VPN site-to-site connectivity
- `modules/bootstrap/` - Bootstrap script, Terraform resources, and adoption metadata
- `bootstrap/generated/` - Generated `.rsc` commissioning scripts

**local-talos:** Bootstraps Talos cluster using Siderolabs provider. Consumes networking outputs for node IPs/hostnames.

**Shared modules (`modules/`):**
- `secrets/` - Google Secret Manager wrapper
- `templatefile-generator/` - Template processing utility

## Network Topology

- **Kuberack LAN**: `10.10.10.0/24` / `fd00:de:ad:10::/64` (portable)
- **Stationary LAN**: `10.1.1.0/24` / `fd00:de:ad:1::/64`
- **Transit Link**: `10.254.254.0/30` / `fd00:de:ad:ff::/64` (point-to-point between routers)
- **ZeroTier VPN**: `10.255.255.0/24` (fallback when sites are separated)

## Validation

```bash
terraform validate && terraform plan     # Pre-apply checks
nix develop .#kubernetes --command local-kubernetes/scripts/validate.sh
flux get kustomizations                  # Flux layer status
talosctl -n 10.10.10.11 health           # Talos cluster health (one node)
terraform output -raw kubeconfig > ~/.kube/talos-config && kubectl get nodes
```

Bootstrap script changes regenerate `bootstrap/generated/*.rsc` - review with `git diff` before committing.

## Coding Conventions

- HCL: 2-space indent, `snake_case` for variables/locals
- File layout: `provider.tf`, `backend.tf`, `main.tf`, `outputs.tf`, `secrets.tf`
- Follow existing hostname patterns (e.g., `kuberack-rb5009`, `c1.k8s.kalski.xyz`)
- Commits: short imperative summaries, lowercase (e.g., "add dhcp static lease for pannu")
- Architecture decision records: name new ones by date and topic, without a
  number; see [docs/adr/README.md](docs/adr/README.md)
