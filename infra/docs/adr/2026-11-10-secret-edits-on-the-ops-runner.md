# Edit Secret Manager secrets from the ops runner

- Status: accepted, amended 2026-11-10: `local-kubernetes` stays outside ops
  (see [the bundled secret](#the-bundled-local-kubernetes-secret)). The edit
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
  other secret, and ops has no IAM grant on any other. `local-kubernetes` stays
  with `just edit` on a maintainer's machine; see
  [the bundled secret](#the-bundled-local-kubernetes-secret).
  The command line, and so the prompt, names the properties and never a value:
  - `--remove PATH` needs no value.
  - `--generate PATH=token|password` makes the value on ops. It is never printed.
- **Values only a maintainer has** still go in with `just edit`. Amp can pass a
  personal Amp secret, set through its masked dialog, to a runner's threads only
  when the runner runs with Amp's Secrets & Env Vars (`--amp-env`). That would
  put every personal and project Amp secret in the shells of the ops runner's
  threads, against the rule that the runner holds only the credentials it needs
  and that no credential is stored in Amp. The ops runner doesn't enable it,
  and the command takes no value from its environment.
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
active secret version, so one secret for all of the cluster's values keeps the
number of versions, and of edits, small. The values stay bundled; none moves to
a secret of its own.

The bundle includes `sops_age_key`, which decrypts every SOPS file in the
repository, and `klusse_amp_runner_key`, an account-wide Amp key. Secret
Manager's IAM grants a whole secret and has no condition on what a version
contains. Reading a version returns the whole document, and adding one replaces
it. So no grant lets ops change one property of `local-kubernetes` without also
being able to read `sops_age_key` or replace it. Ops therefore gets neither
`secretAccessor` nor `secretVersionAdder` on it, and edits there stay with a
maintainer's `just edit`. The command's refusal is a second line; IAM is the
boundary.

## Consequences

- Editing a JSON document means reading it. `ops-networking` already reads
  `local-networking` for applies, so any approved command on the ops runner can
  read the router admin credentials, as before. Ops holds the write access at
  all times, not only during an approved edit.
- Rotating a `local-kubernetes` value, generated or issued, needs a maintainer
  at a machine with GCP credentials.
- Secret Manager keeps old versions, so a bad edit is undone by adding the
  previous version back (`just edit` or a new `secret-edit`). Nothing is
  destroyed.
- The new version takes effect at the next apply of `local-networking`.
- If the project moves into an organization, PAM can replace the standing
  bindings with the entitlement, and `secret-edit` gains the grant request.
  Re-run the privileged-work ADR's required check after either change.
