# Agents ship on their own, guarded by automated and recoverable defaults

- Status: accepted; the guardrails marked "to build" are not yet implemented
- Date: 2026-11-10
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the runner model ADR](2026-11-09-one-runner-per-managed-thing.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the ops retirement ADR](2026-11-10-retire-the-ops-vm.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md)
- Amends: [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md):
  its stages, its never-self-merged list, its deploy approvals and its decision
  against a ruleset no longer apply. Its sections on lock file bumps and the
  orb GitHub identity stand.

## Priority

**Frictionless first, guardrails second, with sanity.**

When the two conflict, the guardrail gives way, unless the risk is clearly
unreasonable: unrecoverable data loss, or handing someone root or
cluster-admin.

**One-time human setup is acceptable; a recurring human step is not.**
Importing a ruleset or storing a recovery copy happens once. A waiver a person
grants per PR, a restore drill a person runs and a secret a person pastes value
by value recur: each is automated or dropped.

Every guardrail, existing or proposed, is tested in this order:

1. Does it cost a maintainer an action? If not, and it is cheap to keep, adopt
   it.
2. If the action happens once, at setup, adopt it when it is worth that one
   action.
3. If the action recurs, automate it. If it cannot be automated, drop the
   guardrail, rely on recovery and record what remains under accepted risks. A
   recurring step stays only while it is the sole control against a clearly
   unreasonable risk, and then with a stated way to remove it.

## Context

Facts on 2026-11-10:

- The orb shipping ADR is at Stage 1, where a maintainer merges every PR. In
  practice agents already merge their own PRs after a clean `sol-loop` review
  and green CI, and `modules/amp-runner.nix` allows `host-deploy deploy`
  without approval.
- **Ship in Amp is a prompt, not a gate.** Amp's shipping documentation says
  the Ship button sends the thread a prompt "as if you had typed it", and that
  Puck and other threads send the same prompt when they ship a thread. An agent
  acting for the project's owner can also change the project's Ship setting.
  Nothing lets GitHub or a runner tell that a person pressed Ship.
- The project's orbs act on GitHub as the Amp GitHub App, which has no
  Administration permission on this repository: it cannot read or change
  rulesets or other repository settings. Orbs started outside the project act
  as the account that started the thread.
- The repository has no ruleset. `ops-networking apply` already tells a person
  from an app: it counts a PR label only when the `labeled` event's actor is a
  user (`modules/agent-ops/networking/apply.go`).
- Flux applies `infra/local-kubernetes` from `main` as cluster-admin with
  `prune: true`, and hosts deploy `main` as root. Almost every path in the
  repository is therefore equivalent to root or cluster-admin, so no path list
  separates sensitive changes from safe ones.
- Volumes use one StorageClass, node-local with `reclaimPolicy: Delete`, and
  nothing backs them up. A volume removed from Git is deleted for good.

A person's approval on GitHub for every PR, or for PRs on sensitive paths, was
considered and rejected: it is friction on the routine path, and the path list
would cover most of the repository.

## Decision

**Agents ship on their own; humans press Ship at most; guardrails are
automated, recoverable-by-default, and sized to sensible risk.**

- **Agents ship on their own.** When told to ship, a thread merges its own PR,
  on any path, once `sol-loop` approves and CI is green. Host deploys from
  merged `main` run without approval. No person reviews or approves on the
  routine path.
- **Humans press Ship at most.** Ship states intent and starts delivery. No
  guardrail relies on a person having pressed it.
- **Automated.** A guardrail is a check, a setting or a default that works with
  nobody watching.
- **Recoverable by default.** Making a mistake undoable, by a revert and a
  redeploy, is preferred over preventing it.
- **Sized to sensible risk.** The guardrails cover model error and a single
  mistaken or steered change. They do not try to stop an attacker who controls
  the Amp account.

### Required guardrails

No maintainer action:

- **Review and CI before a merge** (exists, by instruction): a clean `sol-loop`
  result from a separate reviewer thread, and green CI.
- **The project's orbs act as the Amp GitHub App** (exists), so a misled orb
  cannot change this repository's settings.
- **Data survives its removal from Git** (to build). PersistentVolumeClaims,
  the namespaces that hold them and CustomResourceDefinitions carry
  `kustomize.toolkit.fluxcd.io/prune: disabled`; the Flux Kustomizations set
  `deletionPolicy: Orphan`; volumes that hold data use reclaim policy `Retain`.
  Terraform resources that hold state or secrets keep `prevent_destroy`.
- **A destructive-change guard** (to build): one check that fails a PR which
  removes one of those protections, deletes a stateful object, or changes the
  guard itself, unless the PR carries the label `allow-destroy`. The agent that
  opens the PR adds the label, as a declaration that the destruction is
  intended, and names what is destroyed in the PR description. No person
  waives it. The check runs from the base branch's workflow and reads the diff
  without running the PR's code, so a PR cannot switch off its own check.
- **Runners act on merged `main` through fixed commands** (exists for
  `host-deploy` and `ops-networking`), and their versions are pinned in the
  repository where Amp allows it (to build), so an update arrives as a PR.
- **Admin credentials stay unreadable to agents** (partly exists). Orbs hold no
  LAN, cluster or cloud write credentials.
- **Merges and failed rollouts notify** (partly exists): a merge to `main`, a
  failed Flux reconciliation and a failed host deploy each reach a maintainer
  without anyone polling.

One maintainer action, once:

- **A ruleset on `main`** (to build): require a pull request with no approvals,
  block force pushes and deletion, and require the guard's check. Only the
  guard is required, so path-filtered and slow CI jobs cannot block a merge.
  The ruleset is committed as JSON and a maintainer imports it, because agents
  cannot administer the repository. They cannot remove it for the same reason.
- **Recovery material** (to do): the recovery codes and passkeys of the Google
  and GitHub accounts are kept in the password manager, and the Flux age key
  (`sops_age_key`) and the Talos secrets are copied offline.

Recurring maintainer actions: this ADR requires none. Three exist today. This
ADR removes none of them: each stays in force until a change that automates or
drops it merges and amends the ADR that decided it.
[The ops retirement ADR](2026-11-10-retire-the-ops-vm.md) decides that for the
first two, which stay until its stage 1 merges.

- **The ops runner asks before each command** (the ops runner ADR). An approved
  command there reads Talos and router admin credentials, so the prompt is the
  sole control against handing out cluster-admin. It is removed for the fixed
  commands that act on merged `main` once the runner's user cannot read their
  credentials. Other commands there are break-glass work and keep the prompt.
- **Networking PR labels that only a person can add** (the ops runner ADR, and
  `infra/AGENTS.md`): `networking:allow-destroy` and `networking:allow-access`.
  A waiver per PR, to automate or drop.
- **`just edit` for a value only a maintainer has, and for every edit of the
  `local-kubernetes` secret**
  ([the secret edits ADR](2026-11-10-secret-edits-on-the-ops-runner.md)). Entry
  by a person per value, to automate or drop.

### Accounts

One account per service: Google, GitHub, ChatGPT, Claude and Amp, each
connected to Amp so that agents work without setup per thread. There is no
second Google owner, no GitHub machine account, no Amp credit balance kept in
reserve and no scheduled mirror of the repository; the clones on the hosts and
the runners are copies enough.

`sol-loop` stays required. When the ChatGPT connection fails, Sol runs on Amp
credits if the account has any; none is kept in reserve for that. If no backend
can run Sol, shipping stops and the thread reports it, as the root `AGENTS.md`
requires. There is no waiver by a person, no substitute reviewer and no
`needs-sol` queue.

### Approval prompts

Existing `ask` rules on runners are tested against the priority when they get
in the way. A prompt for an action that a redeploy or a restart undoes fails
the test and is removed, by amending the ADR that introduced it.

## Accepted risks

- **A merged change is root and cluster-admin.** A mistaken or steered thread
  whose change passes review and CI merges it; Flux applies it as
  cluster-admin, and the next deploy runs it as root. No person stands in
  between. Review by a separate thread, CI, notifications, `git revert` and a
  rebuild bound it; nothing prevents it. A gate on privilege-granting diffs was
  rejected, because a change can gain root through almost any path and such a
  gate would stop only the obvious ones.
- **Any agent of the account can ship.** Puck, a Space or another thread can
  send the Ship prompt.
- **The guard stops accidents, not intent.** The agent that opens a PR can add
  `allow-destroy`, so the guard catches a deletion nobody declared and passes
  one a mistaken or steered agent declares. With prune disabled and `Retain`,
  removing a volume from Git, labelled or not, leaves its data on the node.
  What remains is a change written to destroy data, which is the first risk
  above, and until backups exist that loss is permanent. An orb started outside
  the project acts as a maintainer's account and could also edit the ruleset.
- **One account per service.** Losing the Google account loses Secret Manager
  and the Terraform state, and with the `local-talos` state the Talos secrets.
  The offline copy of the Flux age key and the Talos secrets is the mitigation;
  everything else there has to be recreated. Losing the GitHub account leaves
  the clones on the hosts and the runners.
- **Account-level compromise.** A stolen Amp account, a leaked runner token or
  a malicious Amp update can do what every runner can: merge through the bot,
  deploy merged `main`, read the cluster and restart units.
- **Transcripts hold what threads read.** Journals and cluster output that
  threads read are stored by Amp and sent to model providers, including any
  secret a service logs.
- **Until backups exist, losing a node's disk loses its volumes.** The
  guardrails above stop deletion through Git, not hardware loss. Backups,
  replication and restore checks that run on a schedule, with no person
  involved, are the next priority after these guardrails.

## Consequences

- The only routine action left to a maintainer is pressing Ship, and that is
  optional.
- The guard and the ruleset are new parts: one workflow, one JSON file and one
  import. Once the ruleset exists, a GitHub Actions outage blocks merges until
  Actions returns, because the guard cannot report; the rule in the root
  `AGENTS.md` for proceeding on local checks then stops short of the merge.
  That delay is accepted, and nobody is asked to bypass the ruleset.
- Deleting a volume or namespace on purpose takes a labelled PR and then a
  cleanup on the ops runner, behind its prompt, because prune is disabled and
  `Retain` keeps the data.
- The orb shipping ADR's stage criteria, its path lists and the planned change
  of `host-deploy deploy` to `ask` are dropped.
- A new guardrail that costs a recurring action is not added. One that costs a
  one-time action needs a line here saying what it is worth.
