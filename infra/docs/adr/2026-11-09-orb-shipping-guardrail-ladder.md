# Let orbs ship in stages, guarded by instructions and approved deploys

- Status: accepted (Stage 1)
- Date: 2026-11-09
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md)
- Amends: [the runners ADR](2026-11-09-amp-runners-on-hosts.md): host deploys
  ask for approval, because a merge is no longer always the operator's review

## Context

The operator's goal: orbs should be able to ship things themselves whenever
told to, with as little friction for the operator as possible and sensible
guardrails. Start tight, then remove the guardrails the operator finds
annoying.

Facts on 2026-11-09:

- `kahlstrm/config` is public, with no rulesets and no CODEOWNERS. Squash merge
  is on, and merged branches are deleted.
- An orb's `gh` acts as `kahlstrm`, with admin on the repository, so an orb can
  push to `main` and merge anything. Where that token comes from (Amp's GitHub
  connection or a stored token) is not yet known.
- Every workflow in `.github/workflows/` is path-filtered, so a required status
  check from a workflow a PR doesn't trigger would never report.
- GitHub Actions is billing-locked, so CI cannot pass until the operator fixes
  billing.
- The runners ADR lets `host-deploy deploy` run without approval because "the
  merge is the review", and Flux applies `infra/local-kubernetes` from `main`
  on its own.

GitHub enforcement was considered: a ruleset on `main` requiring a PR, code
owner review and status checks, CODEOWNERS with path exemptions per stage, an
always-run `ci-ok` job to work around the path filters, and a `sol-review`
status posted by its own GitHub App. The operator chose not to build it now. It
adds setup and friction, and with orbs acting as `kahlstrm`, a ruleset the
operator can bypass would let orbs bypass it too.

## Decision

### Guardrails at every stage

- **Agent instructions**, in `AGENTS.md`: before an orb merges, or asks the
  operator to merge, the change has a clean result from the tool-agnostic
  `sol-loop` review and green CI. Orbs push non-default branches and never push
  to `main` directly.
- **Approvals on everything that changes a running system.** Host deploys and
  privileged applies ask for the operator's approval in the Amp app: deploys on
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

### Stage 1 (now): orbs open PRs, the operator merges

- Orbs push branches and open PRs with a clean `sol-loop` result and green CI.
- The operator merges every PR.

To move to Stage 2:

- About 20 orb PRs merged where Sol and CI were clean and the operator made no
  substantive change before merging.
- No orb pushed to `main` or merged on its own.
- CI billing stays fixed for the period.

### Stage 2: orbs merge their own low-risk PRs

- When told to ship, an orb merges its own PR if Sol is clean, CI is green, and
  the PR touches only low-risk paths: `docs/`, the blog, tests, lab scenarios
  such as `infra/experiments/`, and non-infrastructure code such as
  `config/nvim/`.
- Tests that pin security properties, such as `tests/agent-ops*.nix` and
  `tests/agent-amp-runner.nix`, and `flake.lock` stay with the operator.

To move to Stage 3:

- A few weeks of self-merges with no reverts caused by a bad merge and no
  incidents.
- No self-merge touched a path outside the low-risk list.
- The operator names which remaining approvals feel like rubber stamps.

### Stage 3: orbs merge most paths; high-risk paths stay with the operator

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
list. The operator may drop any guardrail at any time; each drop is recorded
by amending this ADR.

### Orb GitHub identity

Separate from the stages: find exactly where an orb's `gh` token comes from,
Amp's GitHub connection or a stored token, and switch orbs to the Amp bot
identity. This limits what a misled orb can reach (repository settings,
rulesets, other repositories), and it is a prerequisite for the escape hatch,
since a ruleset can only tell orbs apart from the operator once they use a
different identity.

## Consequences

- The stages are enforced by instructions, not by GitHub. A misled orb holding
  `kahlstrm`'s admin token can merge anything; deploy and apply approvals are
  the only enforced gate between a merge and a running host.
- **Residual risk: Flux has no gate.** Flux applies cluster config from `main`
  as soon as it merges, so Sol and CI are the only checks before a change to
  `infra/local-kubernetes` goes live. Flux cluster config stays with the
  operator through Stage 3 for this reason.
- Host deploys ask once per deploy, which adds a tap for every rollout but
  keeps a self-merged change, which deploys as root, from reaching a host
  without the operator.
- Every `flake.lock` and nixpkgs bump reaches every host at its next deploy, so
  bumps stay with the operator through Stage 2. Whether they become
  self-mergeable in Stage 3, given that deploys still ask, is open.
- Green CI is required from Stage 1, so the CI billing lock blocks orbs from
  shipping until it is fixed. During an outage, AGENTS.md's local-CI fallback
  applies, and the operator merges.
- Changes that follow: `modules/amp-runner.nix` changes the `host-deploy
  deploy` rule from `allow` to `ask`, the runners ADR's decision text follows,
  and `AGENTS.md` and the agent instructions gain the merge rules for the
  current stage.
