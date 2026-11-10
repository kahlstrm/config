# Edit Secret Manager secrets from the ops runner

- Status: accepted, amended 2026-11-10 twice: `local-kubernetes` stays outside
  ops, and orbs edit it instead, after `sops_age_key` and `klusse_amp_runner_key`
  moved to secrets of their own (see
  [the bundled secret](#the-bundled-local-kubernetes-secret) and
  [edits from orbs](#edits-to-local-kubernetes-from-orbs)). The edit
  command exists (`ops-networking secret-edit`, `modules/agent-ops/runner.nix`).
  Access is the standing grant below. PAM is blocked: `infra-464520` belongs to
  no organization (the Cloud console lists it under "No organization"), and PAM
  documents only an organization-level service agent. Revisit PAM if the project ever moves into an organization.
- Date: 2026-11-10
- Related: [the privileged-work ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  [the declarative state ADR](2026-11-09-keep-agent-state-declarative.md)

## Context

The `local-kubernetes` and `local-networking` Secret Manager secrets are JSON
documents. A maintainer edits them with `just edit` from a machine with GCP
credentials. Agents can open a PR that needs a new property, but they can't add
it, so every such change waits for a maintainer at a terminal.

The ops runner already asks before every command and holds a GCP key of its own
(`ops-networking`). An edit made there is one approval prompt, provided the prompt
shows what changes and no secret value reaches the thread.

## Decision

- **`ops-networking secret-edit`** takes a secret and property changes and writes
  a new version. Only `local-networking` is accepted; the command refuses every
  other secret, and ops has no IAM grant on any other. Orbs edit
  `local-kubernetes`; see
  [edits from orbs](#edits-to-local-kubernetes-from-orbs).
  The command line, and so the prompt, names the properties and where each value
  comes from, never the value:
  - `--remove PATH` needs no value.
  - `--generate PATH=token|password` makes the value on ops. It is never printed.
  - `--from-env PATH=VARIABLE` reads a variable of the runner's environment.
- **Values only a maintainer has** still go in with `just edit`. Amp can pass a
  personal Amp secret, set through its masked dialog, to a runner's threads only
  when the runner runs with Amp's Secrets & Env Vars (`--amp-env`). That would
  put every personal and project Amp secret in the shells of the ops runner's
  threads, against the rule that the runner holds only the credentials it needs
  and that no credential is stored in Amp. The ops runner doesn't enable it.
  `--from-env` is ready if a maintainer decides otherwise.
- **Access, preferred but blocked: Privileged Access Manager.** A PAM entitlement in
  `gcp-project` makes the `ops-networking` service account eligible for a custom
  role with `secretmanager.versions.add`, `versions.access`, `versions.get`,
  `versions.list` and `secrets.get` (no `setIamPolicy`), conditioned on
  `local-networking`. Each grant needs a maintainer's approval. PAM's shortest maximum
  duration is 30 minutes (`1800s`), not the 15 that was wanted, so the
  entitlement uses that. `secret-edit` would request the grant with a
  justification naming the secret and properties, wait for it, edit, then end the
  grant early (a preview PAM feature) instead of letting it run out. Ops holds no
  standing write access. This is not built: PAM needs an organization, and
  `infra-464520` has none.
- **Access, chosen: a standing grant.** Because PAM is unavailable,
  `gcp-project` grants `ops-networking`
  `roles/secretmanager.secretVersionAdder` on `local-networking`, next to the
  `secretAccessor` it holds there for applies. The ops runner's per-command
  prompt is then the only gate.

A maintainer applies the grant from their own machine; ops never grants itself
access.

### The bundled `local-kubernetes` secret

`local-kubernetes` is one JSON document on purpose. Secret Manager bills per
active secret version, enabled or disabled, so one secret for the cluster's
values keeps the number of versions, and of edits, small.

Two values are the exception, and each has a secret of its own
(`infra/gcp-project/cluster-secrets.tf`): `sops_age_key`, which decrypts every
SOPS file in the repository, and `klusse_amp_runner_key`, an account-wide Amp
key. Secret Manager's IAM grants a whole secret and has no condition on what a
version contains: reading a version returns the whole document, and adding one
replaces it. So nothing could be allowed to edit the bundle while it held those
two without also being able to read or replace them. Only the cluster's
External Secrets reads their secrets; no orb or runner identity has a grant.
They change rarely, and a maintainer changes them in the Cloud console or with
`gcloud`. While `ops-terraform` holds project-wide
`roles/iam.workloadIdentityPoolAdmin`, ops can still pass as External Secrets
through a provider it rewrites and read them, as it could read the bundle before
the split (the privileged-work ADR's known gap 3). Retiring ops, or dropping that
role, closes it.

### Edits to `local-kubernetes` from orbs

Every other value in `local-kubernetes` is an internet-usable credential the
cluster needs (Cloudflare, Telegram, the tailnet probe key, the alert webhook),
so orbs of this repository's Amp project may read and edit the bundle.

- **Identity: Amp's orb OIDC, not a stored key.** An orb mints a short-lived
  token with `amp orb id-token`. The `amp-orbs` workload identity pool in
  `gcp-project` (`amp-orbs.tf`) accepts it only for this Amp project and its
  owner, with `token_use == 'exchanged'`. The project is personal, so its
  tokens carry no `workspace_id`. `google.subject` is the `thread_id`, so audit
  logs name the thread. The pool's principal set has one grant: the custom role
  `secretVersionEditor` on `local-kubernetes`, which reads, adds and destroys
  versions. It has no `versions.enable`, so a destroyed version cannot be
  restored from an orb during its day of delayed destruction, and no
  `setIamPolicy`. A stored service account key was rejected: it would be one
  more long-lived credential, held in Amp, for every orb of the project.
- **The tool:** `infra/secret-edit`, run as
  `nix run ./infra#secret-edit -- --from-env PATH=VARIABLE --remove PATH`.
  It reads the latest version, changes only the named properties, adds the
  result as a new version and destroys the versions before the one it read, so
  two stay active: the new one and the one to go back to. It prints property
  names and version numbers, never a value. It refuses `sops_age_key` and
  `klusse_amp_runner_key`, so neither returns to the bundle. If another version
  was added between its read and its write, it says so and destroys nothing.
- **Values:** a generated value is made in the orb straight into an exported
  variable, such as `export VALUE="$(openssl rand -hex 32)"`, and never echoed. A value only a
  maintainer has goes in through Amp: the agent asks with Amp's private secret
  prompt (`manage_amp` secrets `set` without a value, project scope), or the
  maintainer adds it under the project's Secrets & Env Vars. The orb picks it up
  after `amp orb restart-processes`, and Amp masks the value in shell output.
  After the edit the agent deletes the Amp secret, with the maintainer's
  confirmation. While it exists, every orb of the project receives it.

This narrows the rule that no credential is stored in Amp: a value passes
through Amp for the length of one edit, then is deleted. The ops runner still
doesn't run with `--amp-env`.

`local-networking` stays with `just edit` on a maintainer's machine (and ops'
`secret-edit` while ops exists). It holds the router admin credentials and the
Home Assistant token, which would give orbs the LAN reach the orb networking ADR
denies them.

## Consequences

- Editing a JSON document means reading it. `ops-networking` already reads
  `local-networking` for applies, so any approved command on the ops runner can
  read the router admin credentials, as before. Ops holds the write access at
  all times, not only during an approved edit.
- Rotating a `local-kubernetes` value, generated or issued, needs no
  maintainer's machine: an orb thread does it, and an issued value takes one
  entry in Amp's private prompt. Rotating `sops_age_key` or
  `klusse_amp_runner_key` still needs a maintainer in the Cloud console.
- Every orb of the project, including a prompt-injected one, can read
  `local-kubernetes` and replace or destroy its versions. A destroyed latest
  version stops External Secrets' refreshes, but the cluster's Secrets keep their
  last values, and a maintainer can re-enable the version within a day.
- The tailnet probe key in the bundle lets an orb join the tailnet as
  `zima-tailnet-probe`, with the same reach as any tailnet user: zima's HTTPS
  and the game server's ports.
- Secret Manager keeps old versions, so a bad edit is undone by adding the
  previous version back (`just edit` or a new `secret-edit`). The orb tool keeps
  the version it replaced for that and destroys older ones.
- A `local-networking` change takes effect at its next apply; a
  `local-kubernetes` change at External Secrets' next refresh, within an hour.
- If the project moves into an organization, PAM can replace the standing
  bindings with the entitlement, and `secret-edit` gains the grant request.
  Re-run the privileged-work ADR's required check after either change.
