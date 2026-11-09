# Let orbs ship in stages, guarded by instructions and approved deploys

- Status: accepted (Stage 1)
- Date: 2026-11-09
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md)
- Amends: [the runners ADR](2026-11-09-amp-runners-on-hosts.md): host deploys
  ask for approval, because a merge is no longer always a maintainer's review

## Context

The goal: orbs should be able to ship things themselves whenever
told to, with as little friction for maintainers as possible and sensible
guardrails. Start tight, then remove the guardrails that prove
annoying.

Facts on 2026-11-09:

- This repository is public, with no rulesets and no CODEOWNERS. Squash merge
  is on, and merged branches are deleted.
- An orb's `gh` acts as a maintainer's personal GitHub account, with admin on
  the repository, so an orb can push to `main` and merge anything. Where that
  token comes from (Amp's GitHub connection or a stored token) is not yet known.
- Every workflow in `.github/workflows/` is path-filtered, so a required status
  check from a workflow a PR doesn't trigger would never report.
- GitHub Actions is billing-locked, so CI cannot pass until a maintainer fixes
  billing.
- The runners ADR lets `host-deploy deploy` run without approval because "the
  merge is the review", and Flux applies `infra/local-kubernetes` from `main`
  on its own.

GitHub enforcement was considered: a ruleset on `main` requiring a PR, code
owner review and status checks, CODEOWNERS with path exemptions per stage, an
always-run `ci-ok` job to work around the path filters, and a `sol-review`
status posted by its own GitHub App. The maintainers chose not to build it now. It
adds setup and friction, and with orbs acting as that account, a ruleset a
maintainer can bypass would let orbs bypass it too.

## Decision

### Guardrails at every stage

- **Agent instructions**, in `AGENTS.md`: before an orb merges, or asks a
  maintainer to merge, the change has a clean result from the tool-agnostic
  `sol-loop` review and green CI. Orbs push non-default branches and never push
  to `main` directly.
- **Approvals on everything that changes a running system.** Host deploys and
  privileged applies ask for a maintainer's approval in the Amp app: deploys on
  the target host's runner, applies on the ops runner. The runners ADR's rule
  that allows `host-deploy deploy` without approval is replaced by an `ask`
  rule; `host-deploy status` and `log` stay allowed.
- **Never self-merged, at any stage:** `.github/`, every `AGENTS.md`, agent
  instructions and skills. A PR from a branch in this repository runs its
  workflows with the repository's secrets, so a workflow change can leak them,
  and the instructions are the guardrails themselves.
- **No ruleset, CODEOWNERS or `ci-ok` job.** If an orb merges something it
  shouldn't, or skips review, the escape hatch is a ruleset on `main` and
  CODEOWNERS, as described in the context.

### Lock file and nixpkgs bumps

Orbs may ship `flake.lock` and nixpkgs bumps, at Stage 1 through a maintainer's
merge and from Stage 2 on their own, if the builds are verified on a runner
first. Nothing is built in orbs ([the runner model
ADR](2026-11-09-one-runner-per-managed-thing.md)), so the orb starts a thread on
the pannu runner, and later on a klusse builder. pannu is x86_64 with KVM and
builds `aarch64-linux` through binfmt. That thread checks out the PR's pushed
head into a clean directory, after updating the branch to the current `main`,
and builds before the merge:

- `config.system.build.toplevel` of every `nixosConfigurations` entry that uses
  a bumped input, which for a nixpkgs bump is every one;
- the flake's `checks` for those systems, including the VM tests, which get
  KVM from the Nix daemon's builders rather than from the `amp` user.

It reports the commit, each attribute and its result to the orb thread, and the
PR description records them. If `main` moves before the merge, the build runs
again. Until `amp` is in pannu's `nix.settings.allowed-users` (an untrusted
client, not `trusted-users`), the runner can't reach the Nix daemon, so this
gate can't run and bumps stay with a maintainer. Darwin configurations can't be
built on pannu; the runner evaluates them, and they are built on the
maintainer's Mac when it next switches. Once the klusse builder exists
([the klusse placement ADR](2026-11-09-move-work-from-pannu-to-klusse.md)), these
builds and the VM tests run there. Because these builds
land in the store pannu's harmonia serves, they can also replace
`agent-cache-warm` (see the runner model ADR).

### Stage 1 (now): orbs open PRs, a maintainer merges

- Orbs push branches and open PRs with a clean `sol-loop` result and green CI.
- A maintainer merges every PR.

To move to Stage 2:

- About 20 orb PRs merged where Sol and CI were clean and a maintainer made no
  substantive change before merging.
- No orb pushed to `main` or merged on its own.
- CI billing stays fixed for the period.

### Stage 2: orbs merge their own low-risk PRs

- When told to ship, an orb merges its own PR if Sol is clean, CI is green, and
  the PR touches only low-risk paths: `docs/`, the blog, tests, lab scenarios
  such as `infra/experiments/`, and non-infrastructure code such as
  `config/nvim/`.
- Tests that pin security properties, such as `tests/agent-ops*.nix` and
  `tests/agent-amp-runner.nix`, stay with a maintainer.
- `flake.lock` and nixpkgs bumps may be merged by orbs too, once built on the
  pannu runner as described below.

To move to Stage 3:

- A few weeks of self-merges with no reverts caused by a bad merge and no
  incidents.
- No self-merge touched a path outside the low-risk list.
- A maintainer names which remaining approvals feel like rubber stamps.

### Stage 3: orbs merge most paths; high-risk paths stay with a maintainer

Orbs self-merge everything except:

- `infra/local-talos/`, `infra/local-networking/`, `infra/gcp-project/`,
  `infra/hetzner-infra/`;
- `secrets/`, `.sops.yaml` and `**/*.sops.yaml`;
- `modules/agent-ops/`, `modules/amp-runner.nix`,
  `modules/host-deploy-command.nix`, `modules/ops-deploy.nix`,
  `modules/agents/environment/deploy*` and `lib/ssh-keys.nix`;
- Flux cluster config: `infra/local-kubernetes/clusters/`, `infrastructure/`,
  `platform/`, and RBAC such as `agent-debug`;
- the never-self-merged list above;
- anything that reaches admin credentials per the ops runner ADR's required
  check.

Further widening needs a Stage 3 track record like Stage 2's, a clean required
check, and progress on narrowing admin-equivalent state, which would shrink the
list. A maintainer may drop any guardrail at any time; each drop is recorded
by amending this ADR.

### Orb GitHub identity

Separate from the stages: find exactly where an orb's `gh` token comes from,
Amp's GitHub connection or a stored token, and switch orbs to the Amp bot
identity. This limits what a misled orb can reach (repository settings,
rulesets, other repositories), and it is a prerequisite for the escape hatch,
since a ruleset can only tell orbs apart from a maintainer once they use a
different identity.

## Consequences

- The stages are enforced by instructions, not by GitHub. A misled orb holding
  a maintainer's admin token can merge anything; deploy and apply approvals are
  the only enforced gate between a merge and a running host.
- **Residual risk: Flux has no gate.** Flux applies cluster config from `main`
  as soon as it merges, so Sol and CI are the only checks before a change to
  `infra/local-kubernetes` goes live. Flux cluster config stays with a
  maintainer through Stage 3 for this reason.
- Host deploys ask once per deploy, which adds a tap for every rollout but
  keeps a self-merged change, which deploys as root, from reaching a host
  without a maintainer.
- Every `flake.lock` and nixpkgs bump reaches every host at its next deploy.
  Building every affected configuration on pannu before the merge catches
  breakage that CI's path-filtered checks miss; the deploy approval is still the
  gate before a host runs it.
- Green CI is required from Stage 1, so the CI billing lock blocks orbs from
  shipping until it is fixed. During an outage, AGENTS.md's local-CI fallback
  applies, and a maintainer merges.
- Changes that follow: `modules/amp-runner.nix` changes the `host-deploy
  deploy` rule from `allow` to `ask`, the runners ADR's decision text follows,
  and `AGENTS.md` and the agent instructions gain the merge rules for the
  current stage.
