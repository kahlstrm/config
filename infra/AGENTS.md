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

Existing credentials flow from Google Secret Manager → Terraform → Kubernetes. Generate application credentials with ephemeral Terraform resources and write-only Kubernetes Secret fields. **Never create Kubernetes secrets manually.**

### Editing Secrets

Secrets are stored as JSON blobs in Google Secret Manager. Run `just` commands from within the target layer directory:

```bash
just help           # Show available commands
just edit           # Edit secret for current layer (opens $EDITOR)
just view           # View current secret value
just clean --dry-run  # Preview old version cleanup
```

First-time setup for a layer: `terraform apply -target module.secrets` before running `just edit`.

### Creating Kubernetes Secrets

1. **Add values to GSM** (from `local-networking/`):
   ```bash
   cd local-networking && just edit
   # Add your key to the JSON, e.g.: "myapp": { "password": "xxx" }
   ```

2. **Create the Kubernetes secret** in `local-talos/kubernetes-secrets.tf`:
   ```hcl
   resource "kubernetes_namespace" "myapp" {
     depends_on = [talos_cluster_kubeconfig.this]
     metadata { name = "myapp" }
   }

   resource "kubernetes_secret" "myapp_credentials" {
     depends_on = [kubernetes_namespace.myapp]
     metadata {
       name      = "myapp-credentials"
       namespace = "myapp"
     }
     data = {
       PASSWORD = local.config["myapp"]["password"]
     }
   }
   ```

3. **Apply Terraform**:
   ```bash
   cd local-talos && terraform plan && terraform apply
   ```

4. **Reference in manifests** via `secretKeyRef` or `envFrom`:
   ```yaml
   envFrom:
     - secretRef:
         name: myapp-credentials
   ```

## Architecture

**Layered infrastructure with dependency ordering:**

```
local-networking/     → Network foundation (MikroTik routers, DHCP, DNS, VPN)
    ↓ (remote state)
local-talos/          → Cluster primitives (Talos nodes, ArgoCD, OpenEBS, MetalLB)
    ↓ (GitOps)
local-kubernetes/
  ├── apps-talos/     → Platform services (cert-manager, Traefik, MinIO, Harbor)
  └── apps/           → Portable applications (External-DNS, observability)
```

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
talosctl health                          # Talos cluster health
terraform output -raw kubeconfig > ~/.kube/talos-config && kubectl get nodes
```

Bootstrap script changes regenerate `bootstrap/generated/*.rsc` - review with `git diff` before committing.

## Coding Conventions

- HCL: 2-space indent, `snake_case` for variables/locals
- File layout: `provider.tf`, `backend.tf`, `main.tf`, `outputs.tf`, `secrets.tf`
- Follow existing hostname patterns (e.g., `kuberack-rb5009`, `c1.k8s.kalski.xyz`)
- Commits: short imperative summaries, lowercase (e.g., "add dhcp static lease for pannu")
