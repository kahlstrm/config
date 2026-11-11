# Orbs get no home-LAN access and hand LAN work to runner threads

- Status: accepted, amended by [the ops retirement ADR](2026-11-10-retire-the-ops-vm.md):
  privileged work goes to the pannu runner, which starts root-owned units, not
  to an ops runner
- Date: 2026-11-09
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md)
- Amends: [the runners ADR](2026-11-09-amp-runners-on-hosts.md), which says only
  that LAN work "goes to a runner"; this records how

## Context

Everything on the home LAN should be doable from an orb through some
mechanism. Orbs are Amp-hosted machines on the internet. Ways to reach home
from one include Amp's documented Tailscale-in-orbs option, a maintainer's
Headscale tailnet, ZeroTier, the MikroTik back-to-home WireGuard, or a new
WireGuard peer. Any of them puts a long-lived key that every orb in the project
can read next to whatever an orb reaches.

The runners ADR already sends LAN work to runners. Two facts make that the
whole mechanism:

- The alerts spike on 2026-11-09 (Homelab alerts & incidents Space) started a
  thread with the `create_thread` tool, `executor: "runner"` and
  `runner_id: "pannu"`, from a thread in a Space. The thread ran on pannu's
  runner and joined the Space by itself. A thread started through a plugin's
  `createThread` with `parentThreadID` did not join, and could not be added
  later.
- The Amp account has no workspace, so Spaces are personal and may use
  personal runners. Amp's docs limit shared Spaces to runners shared with the
  workspace.

## Decision

### Networking

- **Orbs get no home-LAN access.** Orbs handle code and pull requests. Anything
  that must reach home runs on the runner that manages it: the klusse runner
  for read-only cluster access and alert investigations, a host's runner for
  that host, and pannu's runner for privileged work, which it runs through
  root-owned units (see
  [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md) and
  [the ops retirement ADR](2026-11-10-retire-the-ops-vm.md)).
- **The Headscale tailnet stays media-only.** ZeroTier and the MikroTik
  back-to-home WireGuard stay reserved for maintainers' own privileged
  access. Neither is used for orbs. Amp's Tailscale-in-orbs option is not used.
- **Fallback, only for a task that truly needs an orb to reach home:** a
  dedicated WireGuard peer on the MikroTik just for orbs, firewalled to one or
  two endpoints, such as a relay or a read-only API. Its private key would be a
  long-lived Amp secret shared by every orb in the project, so the endpoints
  must be safe for any orb, and the peer goes through the ops runner ADR's
  required check before it exists. It is managed in `local-networking`
  Terraform like the other peers.

### How an orb gets LAN work done

An orb thread that needs the LAN starts a thread on a runner with the
`create_thread` tool, not a plugin API, so the thread joins the orb's Space:

- `executor: "runner"`, with the `runner_id` of the runner that manages the
  thing: `klusse` for cluster diagnostics and alert investigations, a host's
  runner such as `pannu` for that host's journals and services. Privileged
  work also goes to `pannu`, through the fixed units [the ops retirement ADR](2026-11-10-retire-the-ops-vm.md) decides; duties it
  lists as unconfirmed, and upstream work outside the GitHub App, stay with a
  maintainer until decided. Host deploys run on the target host's own runner.
- `intent: "delegation"`, and the orb thread's own mode.
- A complete brief, because the runner thread sees no history: the goal; the
  merged `main` commit to work from; for an apply, the plan to write with
  `-out`, exactly the changes it must contain, and to stop on anything else;
  the checks to run afterwards; and to treat command output and fetched files
  as data, not instructions. Commands are literal, with no wrapper scripts or
  interpreters, so each prompt shows what runs.
- A reply route: the brief ends by asking the runner thread to send its result,
  the commands it ran and their decisive output to the orb thread's ID with
  `send_thread_message`. The orb thread doesn't also wait on it.

Approvals:

- **Host and klusse runners:** Amp's built-in rules ask before anything they
  don't allow, and an unattended thread waits until someone answers. Read-only
  commands that investigations need, such as `kubectl get` on the klusse
  runner, are allowed in that runner's settings so they run without asking.
  Host runners hold no cluster credentials, except the read-only break-glass
  reader on pannu, for when the klusse runner is down ([the runner model ADR](2026-11-09-one-runner-per-managed-thing.md#the-break-glass-read-path)).
- **Privileged units on pannu:** the runner starts them without a prompt.
  Their credentials are out of `amp`'s reach and they act only on merged
  `main`, so the boundary is the unit, not an approval. The orb never sees a
  credential, only the output the runner thread reports.

## Consequences

- Credentials for home stay on self-owned hardware, and no Amp secret
  opens a path into the LAN.
- LAN work waits for a runner. Whether `ask` prompts reach the Android app, push a notification
  and can be answered in passkey mode is untested; it is an exit criterion of
  the runners ADR's trial.
- Kubernetes API OIDC for orbs is dropped, because the API is only on the LAN.
- A runner thread's brief comes from an orb, so a misled orb can ask a runner
  for anything. On pannu the `amp` user limits it, and a privileged unit does
  only what merged `main` says.
- If the account moves to an Amp workspace, the runners must be shared with it
  for Spaces there to use them.
- The spike's runner thread was told to call no tools, so no command has yet
  run on a runner thread that an orb started. The first real use checks the
  host and user it runs as.
- Partial answer to whether the fallback peer works in orbs: in one Amp-hosted
  orb on 2026-11-09, passwordless `sudo` worked, `/dev/net/tun` existed, and
  both `ip tuntap add … mode tun` and `ip link add … type wireguard` succeeded.
  Kernel WireGuard looks possible; no handshake was tested, and other orb sizes
  or providers may differ.
