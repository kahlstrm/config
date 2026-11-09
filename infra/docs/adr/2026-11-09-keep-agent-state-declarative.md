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
`~/.config/AGENTS.md`. Credentials stay on self-owned hardware rather
than in Amp secrets (see the ops runner ADR). When new Amp-side state becomes
unavoidable, it is added to the list below in the same change.

## Guidance files

Personal agent instructions (`config/agents/instructions.md`)
are guidance for local agents only. Amp threads, in orbs or on runners,
never load them. Per
[Amp's docs](https://ampcode.com/docs/customize/agents-md), Amp always loads
`$HOME/.config/amp/AGENTS.md`, `$HOME/.config/AGENTS.md` and
`/etc/ampcode/AGENTS.md`, and `AGENTS.md` files in the working directory and
its parents up to `$HOME`. It also loads a subtree's `AGENTS.md` once a thread
reads a file in that subtree, and falls back to `AGENT.md` or `CLAUDE.md` where a
directory has no `AGENTS.md`.

Checked on 2026-11-09 against `main`, the evaluated pannu and ops
configurations and an Amp orb, without looking at the hosts:

- **Every Amp thread with a checkout of this repository loaded it** while it was
  `config/AGENTS.md`, a subtree guidance file: in an orb, reading
  `config/ghostty/config` made Amp include it in the thread. Any orb, or runner
  thread working in a checkout, that read a file under `config/` got personal
  rules, such as asking before publishing PR text. It now lives at
  `config/agents/instructions.md`, a name Amp doesn't discover, and the Home
  Manager copies and `/etc/agent-instructions.md` are unchanged.
- **pannu runner:** runs as the system user `amp`, with `HOME` and the working
  directory both `/var/lib/amp-runner` (`modules/amp-runner.nix`), and
  `ProtectHome=true`. Home Manager configures only the primary user, whose
  copies of the instructions (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
  `~/.gemini/GEMINI.md`, `~/.config/opencode/AGENTS.md`) are in no Amp path and
  hidden from `amp`. pannu's `environment.etc` has no `ampcode/` entry. Nothing
  loads outside a checkout. Files a thread writes into `/var/lib/amp-runner`
  itself were not checked on the host.
- **ops runner (planned):** `local.ampRunner` alone would run as `amp` like
  pannu's. But ops' credentials (`/var/lib/ops-credentials` and the `gh` and
  `glab` logins) belong to the agents environment's user `agent`, whose home
  `/home/agent` holds `AGENTS.md` linked to `/etc/agent-instructions.md`, which
  is the personal instructions followed by the T3-era agent and ops instructions
  (`modules/agents/environment/shared.nix`). A runner running as `agent`, or any
  thread working under `/home/agent`, would load it from the home directory too.
- Amp's Global AGENTS.md setting is unused.

Follow-ups:

- **Before the ops runner is enabled:** run it as `amp` and give `amp` only the
  credentials it needs, or, if it must run as `agent`, stop linking
  `/etc/agent-instructions.md` into that home once T3 leaves ops.
- **Backstop on every runner:** set `AMP_IGNORE_GUIDANCE_FILES` in the
  `amp-runner` service from `modules/amp-runner.nix` to globs for copies of the
  personal instructions, such as `/home/agent/AGENTS.md`. Not `*`, which would
  drop the repository's own guidance too.

## Unavoidable Amp-side state today

- **The account itself:** login, passkey settings, and the Claude and ChatGPT
  subscriptions connected to pay for models.
- **Projects:** each repository's Amp project, its Ship behaviour, its
  pre-setup script and its default orb size.
- **The project's GitHub identity** (the Amp bot or the thread creator), and
  the Amp GitHub integration installed on this repository and the 3D models
  repository.
- **The GitLab connection** that signs `glab` in inside orbs.
- **Runner registration** and one access key per runner. A host's key also
  lives on the host outside Nix, in `/etc/credstore.encrypted/amp-runner.token`,
  installed by hand (see the runners ADR). The klusse runner's key is the
  `klusse_amp_runner_key` property of the `local-kubernetes` Secret Manager
  secret, added by hand.
- **Spaces** and which threads belong to them.
- **Webhook triggers,** such as the Alertmanager alert webhook. A plugin's
  `createWebhook` registers one, but only trigger settings pause or delete it,
  and its URL lives only in Amp. The alert intake's trigger (`tools/alert-intake`) is
  owned by its intake thread in the Homelab alerts & incidents Space, which must
  stay unarchived; that orb also holds the intake's dedup state and the trigger's
  URL, which is copied by hand into Secret Manager (`amp_alert_webhook_url`).
- **Per-thread subscriptions and schedules:** GitHub CI and PR subscriptions,
  and Automations. These belong to threads and end with them.
- **Amp secrets:** `ALERT_WEBHOOK_TOKEN` in the project's secrets, the bearer
  token the alert intake checks; orbs never read `local-kubernetes`, where
  Alertmanager's copy (`amp_alert_webhook_token`) lives. The orb-only WireGuard
  key would be another if that fallback is ever built (see the orb networking
  ADR).

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
