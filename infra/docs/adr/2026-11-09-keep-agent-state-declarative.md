# Keep agent configuration declarative, in the repository and Nix

- Status: accepted
- Date: 2026-11-09
- Related: [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md)

## Context

Moving agent work to Amp adds many places to configure it: account settings,
project settings, Amp secrets, settings set by hand in the apps, and files in
the repository and on each host. State set by hand in a vendor's UI isn't
reviewed, isn't in git history, is lost or drifts silently, and has to be
recreated by hand to move to another tool. The repository already builds every
machine from git.

## Decision

Keep non-declarative state, in Amp and everywhere else, to the minimum, and
avoid it where a declarative place exists. In order of preference:

1. **Repository files:** `AGENTS.md` files, `.agents/skills`, `.agents/setup`
   and `.amp/settings.json`.
2. **Machine configuration deployed by Nix:** `~/.config/AGENTS.md`,
   `~/.config/amp/settings.json`, `/etc/ampcode/managed-settings.json`, and the
   runners' `--settings-file` (`modules/amp-runner.nix`).
3. **Amp account and project settings, Amp secrets and settings set in the
   apps**, only when nothing above can hold the state.

Amp's Global AGENTS.md setting stays unused; global instructions come from
`~/.config/AGENTS.md`. Credentials stay on hardware the operator owns rather
than in Amp secrets (see the ops runner ADR). When new Amp-side state becomes
unavoidable, it is added to the list below in the same change.

## Unavoidable Amp-side state today

- **The account itself:** login, passkey settings, and the Claude and ChatGPT
  subscriptions connected to pay for models.
- **Projects:** each repository's Amp project, its Ship behaviour, its
  pre-setup script and its default orb size.
- **The project's GitHub identity** (the Amp bot or the thread creator), and
  the Amp GitHub integration installed on `kahlstrm/config` and
  `kahlstrm/3d-models`.
- **The GitLab connection** that signs `glab` in inside orbs.
- **Runner registration** and one access key per host. The key also lives on
  the host outside Nix, in `/etc/credstore.encrypted/amp-runner.token`,
  installed by hand (see the runners ADR).
- **Spaces** and which threads belong to them.
- **Webhook triggers,** such as the Alertmanager alert webhook and its bearer
  token. A plugin can't create or revoke them.
- **Per-thread subscriptions and schedules:** GitHub CI and PR subscriptions,
  and Automations. These belong to threads and end with them.
- **Amp secrets,** none today. The orb-only WireGuard key would be one if that
  fallback is ever built (see the orb networking ADR).

Outside Amp, the deliberate non-declarative state is the credentials generated
on the ops VM (ADR 9) and the per-host runner keys above.

## Consequences

- Most agent behaviour changes through a reviewed commit, and moving to another
  agent tool means rewriting files, not reconstructing UI settings.
- The list above is what must be recreated by hand after losing the Amp
  account or moving off Amp, and what to check when behaviour differs from the
  repository.
- Where Amp offers only a UI setting for something a file could hold, the file
  wins once Amp supports it.
