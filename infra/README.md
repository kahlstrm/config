# Infrastructure

This directory contains an experimental playground for managing a personal hardware setup using Infrastructure as Code. It uses Terraform for the declarative setup, Nix for tooling, and Just for scripting, with a focus on leveraging free-tier services from Google Cloud.

Infrastructure has its own `flake.nix` and `flake.lock`. Run the commands in this
guide from `~/config/infra`, unless a layer directory is specified. Machine and
user configuration is described in the [root guide](../README.md).

## Hardware Setup

### Kuberack (Portable)

- [DeskPi RackMate T0](https://deskpi.com/products/deskpi-rackmate-t1-rackmount-10-inch-4u-server-cabinet-for-network-servers-audio-and-video-equipment) - 10" 4U minirack
- [MikroTik RB5009UPr+S+IN](https://mikrotik.com/product/rb5009upr_s_in) - Main router with PoE
- [MikroTik CRS305](https://mikrotik.com/product/crs305_1g_4s_in) - PoE-powered switch
- 3x [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) - PoE-powered Kubernetes control plane nodes (c1, c2, c3)
- [Minisforum MS-01](https://minisforumpc.eu/en/products/ms-01) - Kubernetes worker node (w1)
- [Minisforum MS-A2](https://minisforumpc.eu/en/products/ms-a2) - Kubernetes worker node (w2)

### Stationary Setup

- [MikroTik RB5009UGS](https://mikrotik.com/product/rb5009ugs_in) - Main router (no PoE output)
- [MikroTik CRS310-8G+2S+IN](https://mikrotik.com/product/crs310_8g_2s_in) - Main managed switch
- Unmanaged 8-port 2.5G PoE switch with SFP+
- [Ubiquiti UniFi U7 Pro Wall](https://eu.store.ui.com/eu/en/products/u7-pro-wall) - WiFi access point
- [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/) - Home Assistant + Unifi controller
- pannu - Custom built PC
- [Zimaboard 2](https://www.zimaspace.com/products/single-board2-server) - Secondary compute
- [JetKVM](https://jetkvm.com/) - IP KVM for pannu

## Technologies Used

- [Terraform](https://www.terraform.io/)
- [MikroTik RouterOS Terraform provider](https://registry.terraform.io/providers/terraform-routeros/routeros/latest/docs)
- [Google Cloud Platform](https://cloud.google.com/) (GCS, Secret Manager)
- [Nix](https://nixos.org/)
- [Just](https://github.com/casey/just)

## Architecture

This infrastructure uses a **layered approach** where infrastructure-specific services are separated from portable applications:

```
local-networking/          # Network foundation (MikroTik routers, DHCP, DNS, VPN)
local-talos/               # Cluster primitives (Talos nodes, ArgoCD, OpenEBS, MetalLB)
local-kubernetes/
  ├── apps-talos/          # Platform services (Talos-specific)
  └── apps/                # Portable applications
```

### Cluster Primitives vs Platform Services vs Applications

**Cluster Primitives** (`local-talos/`, Terraform): Must exist before anything else works. Deployed via Terraform to guarantee ordering.

- ArgoCD (GitOps bootstrap)
- OpenEBS (storage - PVCs don't work without it)
- MetalLB (networking - LoadBalancer services don't work without it)

**Platform Services** (`apps-talos/`, ArgoCD): Talos-specific services that would be replaced by managed services on cloud platforms.

- cert-manager (TLS certificates)
- Traefik (ingress controller)
- MinIO (object storage)
- Harbor (container registry)

**Applications** (`apps/`, ArgoCD): Portable workloads that work on any platform with the right services available.

- External-DNS (MikroTik DNS - same provider everywhere)
- Observability stack

### Platform Services by Environment

| Service            | Local (Talos)           | AWS                    | Hetzner                   |
| ------------------ | ----------------------- | ---------------------- | ------------------------- |
| Block Storage      | OpenEBS                 | EBS CSI                | Hetzner CSI               |
| Load Balancer      | MetalLB                 | (built-in)             | Hetzner LB                |
| TLS Certs          | cert-manager            | cert-manager           | cert-manager              |
| Ingress            | Traefik                 | ALB Controller         | Traefik                   |
| Object Storage     | MinIO                   | S3                     | Hetzner Object Storage    |
| Container Registry | Harbor                  | ECR                    | Harbor                    |
| DNS Management     | External-DNS (MikroTik) | External-DNS (Route53) | External-DNS (Cloudflare) |

## Getting Started

1. **Setup environment:**

   ```bash
   cd ~/config/infra
   nix develop
   gcloud auth application-default login
   ```

2. **Deploy in order:**

   ```bash
   # Network layer first
   cd local-networking && terraform init && terraform apply

   # Talos cluster provisioning second
   cd ../local-talos && terraform init && terraform apply
   ```

## Configuration

Secrets are managed using Google Secret Manager. The `modules/secrets` module creates a secret in Secret Manager, but the actual value of the secret must be set manually. This is to avoid storing sensitive information in the repository.

The secret management workflow is designed to stay within the free tier of Google Secret Manager, which allows for up to 6 active secret versions. The provided `just` scripts assist with this; for example, `just clean` will prune old, disabled versions, keeping only the most recent two.

After first running `terraform apply -target module.secrets` inside a layer, you can then go on and setup the required secrets for that layer. To configure the secrets for the `local-networking` layer, you can use the `just edit` command from within the `local-networking` directory. This will open the secret in your default editor (`$EDITOR`, with a fallback to `vim`) and upload the new version to Google Secret Manager.

Alternatively, you can manually create a JSON file with the following structure:

```json
{
  "hex_s": {
    "username": "your-username",
    "password": "your-password"
  }
}
```

Then, you can add this to the `local-networking` secret in Google Secret Manager.

## Headscale VPN Management

The VPN infrastructure is built on [Headscale](https://headscale.net/) (self-hosted Tailscale control server) running on the `poenttoe` host.

- **Control Server URL:** `https://head.kalski.xyz`
- **Internal VPN Domain:** `vpn.kalski.xyz`
- **Public DNS:**
  - `head.kalski.xyz` -> Points to `poenttoe` public IP (managed via Terraform).
- **Internal DNS (VPN Only):**
  - `*.zima.kalski.xyz` records point to `zima` VPN IP.
  - Managed via `/var/lib/headscale/dns.json` on `poenttoe`.

### Adding a New User

1.  **Generate a Pre-Auth Key:**
    SSH into `poenttoe` and run:

    ```bash
    # Check User ID
    headscale users list

    # Create a reusable key valid for 24 hours using the User ID
    headscale preauthkeys create --user [USER_ID] --reusable --expiration 24h
    ```

2.  **Share Instructions:**
    Send the user the key and tell them to:
    - Install Tailscale.
    - Set **Login Server** to `https://head.kalski.xyz`.
    - Log in using the Auth Key.

### Registering a Machine Manually

If not using a pre-auth key:

1.  **User:** Runs `tailscale up --login-server https://head.kalski.xyz` and gets a machine key.
2.  **Admin:** Runs `headscale nodes register --user [USER_ID] --key [MACHINE_KEY]` on `poenttoe`.

### Internal DNS Management

To add new services to the VPN DNS:

1.  SSH into `poenttoe`.
2.  Edit `/var/lib/headscale/dns.json`.
3.  Add the new A record pointing to the `zima` VPN IP.
4.  Restart Headscale: `systemctl restart headscale`.
