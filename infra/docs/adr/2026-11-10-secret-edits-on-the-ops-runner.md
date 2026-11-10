# Edit Secret Manager secrets from the ops runner

- Status: accepted. The edit command exists (`ops-networking secret-edit`,
  `modules/agent-ops/runner.nix`). Access is the standing grant below. PAM is
  blocked: `infra-464520` belongs to no organization (the Cloud console lists it
  under "No organization"), and PAM documents only an organization-level
  service agent. Revisit PAM if the project ever moves into an organization.
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
  a new version. Only `local-kubernetes` and `local-networking` are accepted;
  `sops_age_key` and every other secret are refused by the command and by IAM.
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
  `versions.list` and `secrets.get` (no `setIamPolicy`), conditioned on the two
  secrets. Each grant needs a maintainer's approval. PAM's shortest maximum
  duration is 30 minutes (`1800s`), not the 15 that was wanted, so the
  entitlement uses that. `secret-edit` would request the grant with a
  justification naming the secret and properties, wait for it, edit, then end the
  grant early (a preview PAM feature) instead of letting it run out. Ops holds no
  standing write access. This is not built: PAM needs an organization, and
  `infra-464520` has none.
- **Access, chosen: a standing grant.** Because PAM is unavailable,
  `gcp-project` grants `ops-networking`
  `roles/secretmanager.secretVersionAdder` on both secrets and
  `secretAccessor` on `local-kubernetes` (it has that on `local-networking`
  already for applies). The ops runner's per-command prompt is then the only
  gate.

A maintainer applies the grant from their own machine; ops never grants itself
access.

## Consequences

- Editing a JSON document means reading it, so `ops-networking` reads
  `local-kubernetes` too: Internet-usable tokens such as Cloudflare's and
  Telegram's. With the fallback, any approved command on the ops runner can read
  them, as it can the router admin credentials already. Ops holds this write
  access at all times, not only during an approved edit.
- Secret Manager keeps old versions, so a bad edit is undone by adding the
  previous version back (`just edit` or a new `secret-edit`). Nothing is
  destroyed.
- The new version takes effect when its consumer reads it: an apply of
  `local-networking`, or External Secrets' next refresh for `local-kubernetes`.
- If the project moves into an organization, PAM can replace the standing
  bindings with the entitlement, and `secret-edit` gains the grant request.
  Re-run the privileged-work ADR's required check after either change.
