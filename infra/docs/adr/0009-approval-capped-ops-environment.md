# 9. Run root infrastructure work in an approval-capped ops VM

- Status: accepted, amended by [the auto-mode ADR](2026-11-06-operator-raised-auto-mode-on-ops.md)
  and [the ops runner ADR](2026-11-09-privileged-work-on-the-ops-runner.md),
  which replaces T3 in ops with an Amp runner
- Date: 2026-11-01

## Context

Agents in the agents VM have read-only cluster access. Talos writes, Terraform
applies and other root-level steps went to the operator as hand-offs, which
were the main friction in agent work. Rejected earlier: a self-hosted CI runner
with apply credentials, Talos operations from inside Kubernetes, and access
brokers such as Teleport or a credential broker on pannu.

T3 Code 0.1.4 added linked environments: one T3 server's agents can delegate
threads to another server, and the link caps the delegated threads' runtime
mode. In `approval-required` mode, Claude Code asks before every command
outside its allow list, and the operator answers in the T3 app.

## Decision

Run a second microVM on pannu, `ops`, with its own T3 server and the root
credentials. The agents VM links to it with `approval-required` access, and its
agents delegate root steps there instead of handing them off.

- **Isolation:** a separate microVM (`local.agentVMs.ops`), not a service on
  pannu or a NixOS container, so neither pannu nor the agents VM shares a
  kernel or filesystem with the credentials. The agents VM can reach only ops'
  T3 port; ops cannot connect back. Ops reaches Talos apid on every node and
  the Kubernetes API.
- **Credentials:** private keys are generated on ops and never leave it. The
  repository holds only public material: the signed Talos `os:admin` client
  certificate, the Talos CA certificate, and the GCP service account and
  uploaded key ID. Nothing secret is committed, not even encrypted.
- **Approval:** ops offers only Claude Code, in T3 and in `agent-tools`, since
  other harnesses lack its permission rules. Managed settings allow a short
  list of read-only commands and deny file reads of the credential paths, which
  sit outside every project folder.
- **The link:** T3 links only over https or loopback, so the agents VM reaches
  ops through a loopback forward (`modules/agents/vm/ops-link.nix`). The hub
  that redeems a pairing code chooses the link's access, so ops mints codes
  limited to `orchestration:read` and `orchestration:operate`. Such a code
  refuses a `full-access` link, so ops enforces the cap regardless of what the
  linking agent asks for.

## Consequences

- Root steps wait for the operator's approval in the T3 app instead of a
  hand-off to a local agent. Read-only checks run without asking.
- CI checks the cap without a model (`t3-link-cap`), the providers on a running
  ops server (`agent-ops-providers`), key handling (`agent-ops-credentials`)
  and the static rules (`agent-ops`). Whether a command waits for approval is
  Claude Code's decision and is trusted, not tested.
- The link token is stored in plaintext on the agents VM and travels as plain
  http on pannu's VM network. The ops-side cap is the boundary, not the
  token's secrecy.
- The credentials are long-lived: a GCP service account key (RSA, because key
  upload accepts nothing else) and a Talos client certificate valid for a year
  that cannot be revoked without rotating the CA. Replacing them with keyless
  or short-lived credentials is tracked in #250.
- Links expire after 30 days and must be renewed with a new pairing code.
- Recreating ops' `/var` volume regenerates its keys, which then need signing
  and uploading again.
