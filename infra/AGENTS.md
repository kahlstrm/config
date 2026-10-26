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
# Networking layer (MikroTik routers, DHCP, DNS, ZeroTier)
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

Agents without infrastructure credentials (the agent VM) open PRs and verify
results through Git and read-only `kubectl`, plus test pods in the `agent-sandbox`
namespace, which reach only the pod network once their policy applies, about
two seconds after they start
([ADR 4](docs/adr/0004-network-policies-apply-seconds-after-pod-start.md)).
An agent on the operator's machine runs `terraform`, `talosctl` and `gcloud`
from merged `main`, and reports the
results to the requesting T3 thread through T3's MCP server; see
[operator-machine agents](../docs/agents.md#operator-machine-agents).

A PR that needs an apply describes it under `## Rollout`: the layers in order,
what each plan should show, and the checks afterwards. Instructions handed to the
operator for an apply start with the requesting thread's ID (`T3 thread: <id>`),
which T3's `t3_thread_list` returns as `currentThreadId`. When applying:

- Compare each plan with the rollout and stop if it shows anything else.
- Apply Talos node changes one node at a time with `-target`, control planes
  first, and run `talosctl -n <control plane> health` between nodes; see
  [OS upgrades](local-talos/README.md#os-upgrades).
- Check the Kubernetes API with `kubectl` (for example `kubectl get --raw
  /version`); it rejects anonymous requests.
- Report command output as-is, and stop on errors instead of working around them.
- Pass secrets only through environment variables of the command that needs
  them. Never print or paste them; one-time links go only to the operator.

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

## Secret Management

Kubernetes Secrets live in Git and never come from Terraform. **Never create
Kubernetes secrets manually.**

- **Internet-usable credentials** (API tokens usable from anywhere, such as
  Cloudflare or Telegram) and **bearer URLs** (webhook URLs carrying their own
  token, such as the T3 alert webhook) go in the `local-kubernetes` secret in
  Google Secret Manager and reach the cluster through an `ExternalSecret`; see
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
