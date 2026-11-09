# Run agents through Amp: hosted orbs for code, runners on the hosts

- Status: accepted, migrating (step M3: trial on pannu until about 2026-11-17);
  amended by [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md)
  and [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md)
- Date: 2026-11-09
- Related: [ADR 7](0007-amp-orbs-on-klusse.md),
  [ADR 9](0009-approval-capped-ops-environment.md),
  [the agent VM placement ADR](2026-11-08-agent-vm-placement.md)

## Context

Agent work runs in two microVMs on pannu. The agents VM codes behind a host
firewall, and the ops VM holds the operator's credentials and deploys hosts over
a forced-command SSH key (`modules/ops-deploy.nix`), with the operator approving
each deployment. The VMs need their own images, cache, storage, network policy
and restart path, and T3 linked environments keep a child thread on the server
that runs it, so there is no single place for threads.

Amp now covers the missing pieces without our own platform work, unlike the
self-hosted orbs of ADR 7:

- Threads and Spaces live at ampcode.com, in the desktop, web and Android apps,
  with several accounts per app.
- Amp-hosted orbs are disposable machines for repository work on the paid
  Megawatt tier, and Claude and ChatGPT subscriptions can pay for models.
- A runner, `amp --no-tui --runner-id <id>`, connects out from any host. A
  thread can start on it directly, or an orb thread can hand it work.

A deployment already ships only merged upstream `main`: the key decides when a
change lands, not what lands. Approving each deployment repeats the review that
merging did, as long as the operator merges. Once orbs merge their own PRs, a
merge is no longer the operator's review, so deployments ask again; see
[the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md).

## Decision

- **Orbs do the repository work**, with internet access only. Work that needs
  the LAN goes to a runner, never through a tailnet in the orb.
- **Each NixOS host runs a runner** (`local.ampRunner`, `modules/amp-runner.nix`)
  as the unprivileged `amp` user. Its one privileged action is `host-deploy`
  (`deploy`, `status`, `log`) of its own configuration from merged `main`,
  through the same polkit rule ops uses. Its permission rules allow
  `host-deploy status` and `log` without approval and ask before
  `host-deploy deploy` (amended by the orb shipping ADR; the module still
  allows it until that change lands). Other commands follow Amp's built-in rules, which allow
  read-only commands, builds and running code, such as `python -c`, and ask for
  the rest.
- **The `amp` user is the boundary, not the permission rules**: no sudo, no
  other units, a read-only system and no access to `/home`. It reads the host's
  journal, so threads can debug the host's services. The Amp access key
  is installed by hand on each host, encrypted with `systemd-creds` into
  `/etc/credstore.encrypted/amp-runner.token`, and reaches the runner as a
  systemd credential.
- **Root work beyond deployments** runs on an Amp runner in the ops VM that
  asks before every command, not with the operator over SSH; see
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md).

## Migration

Both setups run side by side until M6, and every step before M8 is undone by
reverting its PR. The status line names the current step.

| Step | Change | Undo |
|---|---|---|
| M1 | Runner module and VM test; nothing enabled. `agent-deploy` accepts several requesters. | Revert. |
| M2 | Runner on pannu with its access key in the encrypted credential store; ops' path stays. | Disable the runner, revoke the key in Amp. |
| M3 | A week of deployments and diagnostics through Amp, beside T3. | Keep using T3. |
| M4 | Runners on zima and poenttoe. | Disable per host. |
| M5 | New work starts in Amp; both VMs stay up but idle for two weeks. | Start threads in T3 again. |
| M6 | Replace T3 in the ops VM with an Amp runner ([the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md)) and remove ops' SSH deploy path; the ops VM and its disks stay, and so does the `deployers.ops` key until M8. | Revert, deploy pannu and ops, re-link T3 on ops. |
| M7 | Remove the agents VM; archive T3's thread database, keep its disks, suspend the GitHub App. | Revert, deploy pannu, boot agents from its disk, resume the App. |
| M8 | After 30 more days: delete the agents VM's disks, the App, the agents VM's age recipient and the `deployers.ops` key, and stop building the agents system in the agent cache. The ops VM stays, and so does the cache for ops, whose deployments wait for it (`waitForSubstituter`). | None; rebuild from git history. |

Going back to the VMs after M8, or moving to Amp again later, follows the
same table.

Revert to the VMs if any of these holds:

- An Amp release stops working with the pinned `amp-cli` and nixpkgs does not
  catch up in a week.
- An `ask` approval cannot be answered from the apps, so routine work stalls.
- A thread misuses the `amp` user or its access key.
- Amp's included usage plus credits cost more than the subscriptions it
  replaces.

## Consequences

- Threads, prompts and command output, including Kubernetes and Talos
  diagnostics and anything read from the host's journal, are stored by Amp in
  Google Cloud in the US. A service that logs a secret exposes it to threads.
- A prompt-injected thread on a runner acts as `amp` from that host's place in
  the LAN. Only the user account limits it, so `amp` must stay narrow, and
  new rights for it, such as diagnostics credentials, need their own review.
- Amp has no runner-scoped key. A runner's access key acts as the whole
  personal account: it reads every thread, spends credits and subscriptions,
  and starts threads on every personal runner. Any thread on a runner can read
  it from the runner's environment, so one prompt injection reaches all hosts
  with runners. Encryption at rest protects only disks and backups. Each host
  gets its own key, so one can be revoked alone, and runners stay personal.
  Passkey authentication for remote control may limit a stolen key, which the
  M3 trial checks. A workspace service account would isolate the runners from
  the personal account, at the cost of a Team or Enterprise workspace.
- `amp-cli` comes from nixpkgs with its self-update off, so Amp releases reach
  the hosts through a `flake.lock` update.
- If Amp has no long-lived personal access key, a runner instead uses an account
  saved by a one-time `amp login` as `amp` on each host.
