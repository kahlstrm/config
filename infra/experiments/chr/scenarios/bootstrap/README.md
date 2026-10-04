# Bootstrap end-to-end test

From the repository root:

```sh
nix develop .#chr-bootstrap
just chr run bootstrap
```

This requires Linux, `/dev/kvm`, roughly 1 GiB of free RAM, and Internet access
for CHR images, the RouterOS package check, and provider downloads. It uses
OpenTofu (or Terraform if OpenTofu is unavailable), with the RouterOS provider
version pinned by `local-networking/.terraform.lock.hcl`.

The Go/Terratest scenario creates two disposable CHRs with separate LANs and a shared transit
link. It uploads the **checked-in production scripts** from
`local-networking/bootstrap/generated/`, resets both routers with
`no-defaults=yes`, and imports those files through `run-after-reset`. Regenerate
and review the files after template changes before running the test. A networking
layer plan can verify that their contents match the Terraform template output;
the E2E command itself needs no production credentials or state access.

The test checks:

- Bootstrap reaches its completion marker and finishes its final reboot.
- SSH and certificate-backed HTTPS management work over the new LAN IPv4 addresses.
- Both router names resolve to their IPv4 addresses, including UDP DNS queries
  from outside the router.
- Each router can reach the other router's LAN address with its own LAN address
  as the source, exercising the transit link and return routes.
- IPv6 is disabled globally, LAN advertisements are disabled, and router AAAA
  records stay disabled before and after adoption and reset recovery.
- The production adoption command imports management addresses, peer routes,
  A/AAAA records, static firewall entries, IPv6 settings, and LAN advertisements
  into the bootstrap modules.
  A repeated adoption changes nothing.
  Before any apply, every adopted router resource must have a no-op plan. Only
  creation of the local/uploaded script files and filter ordering resources is
  allowed; updates and replacements fail the test. After creating those files, the full module plan must be empty.
- Adoption preserves the firewall export. Deliberately reordered IPv4/IPv6 forward
  rules produce only ordering updates, and applying them restores that export.
- Both routers are reset again while Terraform state is retained. DNS entries
  and forward filter entries are recreated to guarantee changed IDs, and adoption
  repairs the stale bindings. Recovery may refresh the ordering resources’ ID
  lists, but must preserve the firewall export.
  DNS and routed IPv4 management are checked again.

The lab's normal `terraform/main.tf` only configures providers and disposable
credentials. It explicitly allows the bootstrap's self-signed certificate, as
required during real commissioning; installing and checking managed certificates
belongs to the later networking apply. The harness links the production `bootstrap.tf`, `bootstrap-config.tf`,
`network-topology.tf`, and module directory into its private
Terraform root. There is no copied resource configuration or HCL template substitution.
Terratest runs initialization, plans, applies and idempotency checks; the shared
Go CHR helper handles VM lifecycle and commissioning. SSH is used for initial
access, executing the commissioning script, observations, and deliberate drift
or resets that the recovery test must exercise.
The module renders its scripts there, and the test compares them byte-for-byte with
the checked-in production scripts.

The adoption fixture covers bootstrap handoff, not the entire networking layer
(GCP secrets, ACME, ZeroTier, DHCP leases, CAKE, and monitoring). The assertions target `enable_ipv6=false`, matching the production site configuration.
Internet IPv6/prefix delegation is not simulated here.

## Hardware adaptation and isolation

CHR has nine virtual Ethernet adapters. A small reset wrapper maps their names
to the RB5009 template's ports, including `sfp-sfpplus1`, and removes the temporary
factory DHCP client used to upload the files. The production scripts themselves
are not patched. `keep-users=yes` retains the disposable admin credentials so
the harness can inspect the router after reset.

No TAP devices, host routes, physical bridges, or production routers are changed.
QEMU binds SSH, HTTPS, and DNS forwards to kernel-assigned localhost ports;
the harness reads the assigned ports from QEMU after binding. The transit link
uses a Unix socket inside the private run directory, with no TCP port allocation.
Both test VMs stop on completion or failure; disks, captures, serial/bootstrap logs, exports, and Terraform logs/state
are retained under `$XDG_STATE_HOME/chr/bootstrap/<run>/` (default `~/.local/state`).
These private evidence directories include disposable credentials and state.
The adopted bootstrap resources disappear with the disposable routers. Their
state is retained for diagnosis; removing management addresses through a destroy
would interrupt the API connection used to remove the remaining resources.

CHR cannot verify RB5009 switch hardware, the SFP PHY, or ARM ZeroTier package
installation. It executes the package check's unavailable-package branch. Run
hardware-specific commissioning checks separately.

Select another RouterOS version with:

```sh
just chr --version 7.24.2 run bootstrap
```

## Running locally and in CI

The [GitHub Actions workflow](../../../../../.github/workflows/network-bootstrap.yml)
runs on relevant pull requests and manual dispatch, and uploads selected diagnostic
logs. The command is noninteractive and exits nonzero on a failed assertion. A Linux
CI runner with KVM can use the same entry point and an explicit artifact path:

```sh
nix develop .#chr-bootstrap --command \
  just chr --state "$RUNNER_TEMP/chr" run bootstrap
```

Retain `$RUNNER_TEMP/chr/bootstrap/` on failure. The runner needs no production
secrets. Keep the artifacts private because the local provider state and lab
credentials are included. An interrupted/killed runner can leave QEMU processes;
use an ephemeral CI worker so its teardown also removes them.

A broader `local-networking` suite can build on this topology with simulated
WAN DHCP/DNS/IPv6-PD services and LAN clients. Its next layers should apply the
full router modules, test client DHCP and DNS, and exercise allowed/blocked
firewall traffic and transit failure/recovery. IPv6 on/off transitions need
client-side address, route, DNS, and connectivity checks. ZeroTier integration
and physical RB5009 commissioning remain separate tests. These are planned
coverage, not assertions implemented by this bootstrap scenario.
