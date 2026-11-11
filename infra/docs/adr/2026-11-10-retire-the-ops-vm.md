# Retire the ops VM; privileged applies run as root-owned units on pannu

- Status: accepted, migrating (stage 1), amended 2026-11-11: one generic
  applier per layer replaces the per-duty wrappers. The duties under
  [To confirm](#to-confirm) are proposed and each is confirmed or changed before
  its stage starts. Amended by [the private secrets repository ADR](2026-11-11-secrets-in-a-private-sops-repository.md): secret edits are sops files in the
  private repository, and appliers read their credentials from it
- Date: 2026-11-10
- Supersedes: the ops VM as "the one privileged runner" in
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md), and
  [ADR 9](0009-approval-capped-ops-environment.md) with
  [the auto-mode ADR](2026-11-06-operator-raised-auto-mode-on-ops.md), which
  lapse with T3 on ops
- Amends: [the runners ADR](2026-11-09-amp-runners-on-hosts.md) (step M6),
  [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md) (no ops
  runner; the break-glass reader stays on pannu) and
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md)
  (where orbs send privileged work)
- Related: [the secret edits ADR](2026-11-10-secret-edits-on-the-ops-runner.md),
  [the frictionless shipping ADR](2026-11-10-agents-ship-without-approvals.md)

## Context

The ops VM on pannu exists to keep root infrastructure credentials away from
everyday agents: ADR 9 put them in a VM whose commands a maintainer approves,
and the ops runner ADR kept that VM as the one privileged place when T3 gave way
to Amp runners. [The frictionless shipping ADR](2026-11-10-agents-ship-without-approvals.md)
then set the test for every guardrail: a recurring human step is automated or
dropped. It replaces the ops runner's prompt, for fixed commands on merged
`main`, with commands whose credentials the runner's user cannot read.

Facts on 2026-11-10:

- **The ops runner never ran.** Its Amp token was never committed and its GCP
  account (#364) was never applied. Nothing live depends on it.
- **T3 on ops still holds the old credentials:** the `ops-terraform` GCP key
  (`local-talos` state, so Talos and cluster admin), a Talos `os:admin`
  certificate, the cluster-admin kubeconfig it derives, the RouterOS `ops` user
  for PoE power cycles, a Home Assistant token, the Bambuddy key and the
  `ops-deploy` SSH key. The T3 link expires on 2026-12-01.
- **Pannu's root already reaches all of them.** Ops' disks, including the
  unencrypted `/var` that holds its keys, are files on pannu
  (`/mnt/agents/ops`), and pannu masquerades ops' traffic, so the routers
  already see ops as pannu.
- **The VM costs more than its boundary gives** once every duty is a fixed
  command: its own image, a restart on every pannu deploy, a wait for pannu's
  cache, a network exception per service it reaches, and one more account-wide
  Amp key. `host-deploy` already shows the cheaper shape: a root-owned unit that
  acts on merged `main`, which the unprivileged runner user may start through
  polkit.

## Decision

**No ops VM.** Each privileged duty becomes a root-owned systemd unit on pannu
that runs as its own system user, holds that duty's credentials, and acts only
on merged `main`, which it fetches and checks out itself; it never runs code
from the runner's checkout. Pannu's runner user, `amp`, may start these units
through polkit and read their journals, and cannot read their credentials,
state or saved plans. The runner allows these fixed commands without a prompt,
because their credentials are out of `amp`'s reach and they apply only what a
merge already decided.

Terraform layers share one applier rather than a wrapper per duty: two template
units, `infra-plan@<layer>` and `infra-apply@<layer>`, whose instance name is the
only argument and must be on a fixed list of layers in the host's
configuration. Each layer's units run as that layer's own user with that
layer's own GCP account, holding only the grants its plan and apply need. Plan
saves the plan file and writes a summary without values to the journal; apply
runs only that saved plan, on the whole layer with no `-target`, and only if
`main` has not moved since. If a layer ever has to be split, the split is a
fixed instance name such as `layer:part`, never a free argument. `amp` may only
start these units; they are protected from stop and restart, run with a
negative OOM score adjustment, and resume cleanly after an interruption.

Plans of unmerged branches are a later addition, `infra-plan-pr@<layer>:<pr>`,
once a plan no longer reads admin credentials: the RouterOS credentials become
variables instead of reads of the secret and the state, branch plans use
read-only RouterOS users and an account without access to the
`local-networking` secret, and providers and provisioners that run commands
are refused. Until then a plan reads merged `main` only.

Branches need not be up to date with `main` to merge. An apply always plans the
current `main` and refuses if `main` moved since the plan, so a stale branch
cannot apply anything stale. The branch-plan summary names the branch's base
commit and, when the branch is behind `main`, says so and suggests a rebase;
that is information, not a gate. A GitHub merge queue is the option to consider
only if merges that pass on their own start breaking together.

### Decided

| Duty | Home |
|---|---|
| `local-networking` plan and apply | `infra-plan@local-networking` and `infra-apply@local-networking` on pannu, with the plan summary without values, the saved-plan apply, the refusals and the RouterOS dead-man switch of `ops-networking`, and the account `infra-local-networking` |
| `networking:allow-destroy`, `networking:allow-access` | Declarations the agent opening the PR adds, naming what is destroyed or which access changes, as for `allow-destroy` in [the frictionless shipping ADR](2026-11-10-agents-ship-without-approvals.md). No person adds them, and the apply counts them whoever added them |
| Secret Manager edits | Orbs, decided separately; `just edit` until that lands. Ops' `secret-edit` never ran and is removed |
| Bambuddy | Pannu's runner, against Bambuddy on loopback, with the library-only key encrypted to pannu's host key |
| T3, its harness settings and instructions | Retired with T3 |
| `gh` and `glab` as a maintainer | Already removed; upstream work outside the GitHub App stays manual |
| `gcp-project` | A maintainer's machine, unchanged |

### To confirm

These move privilege onto pannu or drop a capability, so each waits for a
maintainer's confirmation:

| Duty | Proposed home |
|---|---|
| `local-talos` Terraform | `local-talos` added to the applier's layers, with an account holding `ops-terraform`'s grants except that its pool admin is limited to the cluster's pool: a plan from merged `main`, a summary without values, `allow-destroy` declared for deletions. Its state holds the Talos CA, so pannu's disk holds Talos and cluster admin, readable only by the unit's user |
| Admin `talosctl` and cluster-admin `kubectl` | Fixed root-owned units for the recurring operations: cordon, drain, uncordon, reboot and health of a named node, and deleting a released volume after a declared destroy. Credentials are derived from the state in memory. Everything else is break-glass |
| PoE power cycle of a Pi control plane ([the PoE ADR](2026-11-07-ops-power-cycles-pi-control-planes.md)) | A `poe-cycle@<port>` unit on pannu that polkit allows only for the control planes' ports. The RouterOS user keeps its address pin and loses its general REST read |
| Home Assistant token | Dropped, with its `local-networking` output |
| `ops-deploy` SSH key | Dropped once poenttoe has its own runner (M4); until then poenttoe deploys from a maintainer's machine |
| Break-glass read | `break-glass-reader` stays on pannu's runner; its planned move to ops is cancelled |
| Break-glass admin | Outside Amp: a maintainer's machine, UART and JetKVM, which work when Amp is down |

### Accounts and pending work this replaces

- **The ops runner's Amp token** (the sops file #369 expects) is not minted. The
  ops runner and its token wiring are removed in stage 1.
- **The `ops-networking` GCP account** (#364) is not created. Stage 1 creates
  `infra-local-networking` with the same state and secret-read grants and
  without `secretVersionAdder`, since edits go to orbs.
- **`ops-terraform`** and its grants are removed in stage 4, after `local-talos`
  has another home.

### Stages

Each stage is one PR with its own rollout. Until stage 4, each is undone by
reverting it and deploying pannu.

| Stage | Change |
|---|---|
| 0 | This record |
| 1 | The generic applier on pannu for `local-networking` and its GCP account; labels as declarations; the ops runner and `secret-edit` removed |
| 2 | Bambuddy's key on pannu's runner; the ops-only Bambuddy vhost and network exception removed |
| 3 | The duties under To confirm, as confirmed, one PR each |
| 4 | The VM, its modules, tests, deploy key, host key, network exceptions, docs and `ops-terraform` removed; ops' disks deleted 30 days later |

T3's remaining parts go with the agents VM in the runners ADR's M7 and M8.

## Consequences

- Pannu's root is the one place that holds router admin, and Talos and cluster
  admin once the applier holds `local-talos`. It already reached them through ops' disks.
  As `amp`, a thread can start the fixed units and read their output, not their
  credentials.
- A thread on pannu's runner can plan and apply merged `main` at any time
  without asking. What lands is what a merge decided; the dead-man switch, the
  refusals and `prevent_destroy` still bound a bad merge.
- The networking labels stop accidents, not intent: a steered agent can declare
  a destroy, as with `allow-destroy`.
- Privileged applies depend on pannu, as they did while ops ran on it. With
  pannu down, break-glass work runs from a maintainer's machine.
- Pannu deploys no longer restart a VM, and its runner no longer protects
  `microvm@ops`. One fewer Amp key exists.
- The ops runner ADR's required check moves to pannu: as `amp`, `test -r` fails
  on each layer's state directory, `sudo -n true` fails, polkit refuses unit
  names outside the allowlist, and the runner's environment holds no GCP, Talos
  or admin Kubernetes credentials. It runs after stages 1 and 3.
