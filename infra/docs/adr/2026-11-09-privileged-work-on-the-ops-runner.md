# Keep privileged credentials on an ops runner, not in Amp

- Status: accepted, not yet implemented (needed before step M6 of
  [the runners ADR](2026-11-09-amp-runners-on-hosts.md))
- Date: 2026-11-09
- Related: [ADR 9](0009-approval-capped-ops-environment.md),
  [the auto-mode ADR](2026-11-06-operator-raised-auto-mode-on-ops.md),
  [the runners ADR](2026-11-09-amp-runners-on-hosts.md),
  [the orb networking ADR](2026-11-09-orbs-reach-home-through-runner-threads.md),
  [the orb shipping ADR](2026-11-09-orb-shipping-guardrail-ladder.md)
- Amends: [the runners ADR](2026-11-09-amp-runners-on-hosts.md) ("root work
  beyond deployments stays with the operator over SSH") and
  [ADR 9](0009-approval-capped-ops-environment.md) (T3 as ops' executor)

## Context

The goal is that everything on the home LAN can be done from an orb through
some mechanism, with as little friction for the operator as possible. The
runners ADR keeps only `host-deploy` on the per-host runners and sends all
other root work back to the operator over SSH. Today the ops VM does much more
than deploy: admin `talosctl`, `local-talos` Terraform, cluster-admin `kubectl`,
RouterOS reads and PoE power-cycles, `gh` and `glab` as the operator, and
service keys such as Bambuddy's and Home Assistant's. Sending all of that to the
operator would be worse than what ops does now.

Three placements were weighed:

- **(a)** Keep the ops VM and replace T3 in it with an Amp runner that asks
  before every command.
- **(b)** Leave the work with the operator over SSH, as the runners ADR says.
  Rejected: everything ops does today becomes manual work.
- **(c)** Give each capability its own narrow runner. Not chosen: more hosts and
  keys to harden for the same credentials, and each runner's Amp key still acts
  as the whole account.

Storing the credentials as Amp secrets for orbs was also rejected. Keeping them
on hardware the operator owns keeps them portable to another agent tool and out
of a vendor's store.

`local-talos` state is admin-equivalent: it holds `talos_machine_secrets` (the
Talos OS CA), and `infra/local-talos/outputs.tf` outputs the admin talosconfig
and the cluster-admin kubeconfig. Read access to that state is Talos admin plus
cluster-admin.

## Decision

- **Per-host runners do host-local work**: deploy, rebuild and inspect their own
  machine, as in the runners ADR.
- **The ops VM is the one privileged runner.** T3 in it is replaced by an Amp
  runner (`local.ampRunner` in `machines/ops.nix`) that asks before every
  command. Its rules override Amp's built-in allow rules, such as the one for
  `python -c`, allow a short list of fixed read-only commands with no
  interpreters, and reject reads of the credential paths
  (`/var/lib/ops-credentials`, `/run/ops-credentials`). It holds:
  - Talos admin (`talosctl`) and cluster-admin `kubectl`;
  - RouterOS REST and the PoE power-cycle scripts;
  - Terraform on `infra/local-talos` and `infra/local-networking`;
  - `gh` and `glab` as the operator;
  - service keys, such as Bambuddy's and Home Assistant's.
- **Credentials stay on ops**, generated there and never copied out, as in
  ADR 9. None are stored as Amp secrets.
- **Orbs get credentials only through Amp OIDC** (`amp orb id-token`), and only
  for narrow read-only GCP roles through workload identity federation. No
  long-lived key for anything on this list is stored in Amp. Kubernetes API
  OIDC for orbs is dropped, because orbs get no home-LAN access (see the orb
  networking ADR).
- **`gcp-project` stays operator-only**, applied from the operator's machine,
  and owns the Amp orb pool and every orb-facing role.
- **The ops runner's threads are personal**, like every runner's (see the
  runners ADR). Orbs reach it by starting a thread on it; see the orb
  networking ADR.

## Required check

Nothing given to orbs or to the pannu runner may be able to mint Talos or
cluster-admin credentials. Run this check before the first orb OIDC grant and
again after every change to orb or runner access. Only the operator, the ops
service account where intended, and the cluster's External Secrets principal
should show up.

- **GCP, from the operator's machine:**
  - `gcloud storage buckets get-iam-policy gs://terraform-state-1751317459` and
    `gcloud projects get-iam-policy <project>`: no `principal://` or
    `principalSet://` from the Amp pool, and no orb principal with a basic role.
  - `gcloud secrets list`, then `gcloud secrets get-iam-policy <secret>` for
    each, especially `local-kubernetes`, `local-networking` and `sops_age_key`.
  - `gcloud iam workload-identity-pools providers describe …` for the Amp pool:
    its condition pins `user_id`, `project_id` and `token_use`.
  - `gcloud asset analyze-iam-policy` on the bucket and the secrets for
    `storage.objects.get`, `secretmanager.versions.access`,
    `iam.serviceAccounts.getAccessToken`, `iam.serviceAccountKeys.create`,
    every `*.setIamPolicy` and `iam.workloadIdentityPoolProviders.update`.
- **Negative test from a real orb:** mint and exchange a token, then
  `gcloud storage cat` of `local-talos/default.tfstate` and
  `local-networking/default.tfstate`, and
  `gcloud secrets versions access latest` of `local-kubernetes` and
  `sops_age_key`, each return 403.
- **Kubernetes, for the pannu runner's reader identity:**
  `kubectl auth can-i --list --as=<identity> --as-group=<group>` per namespace,
  and explicitly `no` for `get secrets -A`, `create pods -n kube-system`,
  `create pods/exec`, `impersonate users`, `create clusterrolebindings`,
  `create serviceaccounts/token`, `get nodes/proxy` and
  `update certificatesigningrequests/approval`. Every namespace it can create
  pods in enforces the `restricted` Pod Security level.
- **Talos:** orbs have no talosconfig and can't reach apid (port 50000).
- **Network, from a real orb:** the Kubernetes API (10.10.10.10:6443), apid and
  kuberack's REST port are unreachable.
- **pannu runner, as `amp` on pannu:** `id` shows no `wheel`, `kvm` or `docker`
  group; `sudo -n true` fails; `test -r` fails on ops' disks under
  `/mnt/agents` and on `/var/lib/microvms/ops/ops.sock`; `env` holds no GCP or
  Kubernetes credentials.
- **GitHub:** the orb identity's reach is known and recorded; see the orb
  shipping ADR.

## Known gaps

1. **`local-networking` state is sensitive too.** It holds
   `ops_routeros_password` and `poenttoe_zerotier_private_key`, and
   `infra/modules/secrets` reads the `local-networking` Secret Manager secret
   through a data source, so the router credentials land in state. Treat the
   whole state bucket as dangerous, including `hetzner-infra` and
   `gcp-project`.
2. **Project viewers can read every state file.** `infra/gcp-project/main.tf`
   binds `projectViewer` to `legacyBucketReader` and `legacyObjectReader` on the
   state bucket. An orb must never get a basic role such as `roles/viewer`;
   use narrow predefined or custom roles, ideally in a separate project.
3. **Ops can widen other principals' access.** Ops' service account has
   project-level `roles/iam.workloadIdentityPoolAdmin` and `secretMetadataAdmin`
   on `local-kubernetes` (`infra/gcp-project/ops.tf`). One wrongly approved ops
   command could loosen the orb pool's condition or grant an orb
   `secretAccessor`. Keep the orb pool where only `gcp-project` manages it.
4. **There are mint paths outside the state bucket:** `sops_age_key` decrypts
   every SOPS secret in git; the cluster's own workload identity pool;
   Kubernetes RBAC (secrets, pods outside restricted namespaces, `exec`,
   `nodes/proxy`, `impersonate`, RBAC writes, `serviceaccounts/token`, CSR
   approval, and privileged hostPath pods on a control plane, which can read
   its machine config); and GitOps, since whoever pushes to `main` gets
   cluster-admin through Flux.
5. **Orbs can't reach the Kubernetes API** at 10.10.10.10. Resolved by the orb
   networking ADR: read-only cluster work runs on the pannu runner. Kube OIDC
   for orbs would also need a Talos machine-config change and egress from the
   control planes to Amp's discovery document.
6. **Amp OIDC tokens identify the project, not the task.** Personal threads
   carry no `workspace_id`, so conditions match `user_id`, `project_id` and
   `token_use == 'exchanged'`. Every orb in the project, including a
   prompt-injected one, can mint the same identity, so a role granted that way
   must be safe for every thread. Per-task roles need `thread_id` matching.
7. **The pannu runner sits next to ops.** pannu hosts the ops VM, whose
   credentials sit unencrypted on its `/var` disk. `amp` on pannu must not read
   ops' disk images under `/mnt/agents` or reach the `microvm@ops` QMP socket.
8. **The ops runner's Amp key** acts as the whole account, and commands run as
   the runner's own uid, so any approved command can read the key from the
   process environment. Asking before every command protects it only if
   nothing on the allow list can print environments or read `/proc`. Keep the
   allow list to fixed commands with no interpreters.

## Consequences

- Privileged work keeps a VM boundary and per-command approval, but approval
  moves from the T3 app to Amp's `ask` prompts. Whether those can be answered
  from Android, and whether passkey mode allows it, is still untested; it is an
  exit criterion of the runners ADR's trial.
- Amp has no equivalent of the operator raising a thread to Auto, so the
  auto-mode ADR lapses with T3. Long rollouts need either a `delegate` helper as
  a policy layer or many approvals.
- Commands, output and briefs from the ops runner are stored by Amp, as for any
  runner. Credentials stay on ops, but anything a command prints does not.
- Applying `local-networking` from ops is new: ops' service account reads that
  state today (`storage.objectViewer`) but cannot write it or read the
  `local-networking` secret with the router admin credentials, so it needs
  `gcp-project` grants for both, and `infra/AGENTS.md` stops sending those
  applies to the operator's machine.
- The credentials stay long-lived until #250 replaces them.
- The ops T3 link expires on 2026-12-01; it is re-linked if M6 isn't done by
  then.
- Narrowing the dangerous state (splitting `talos_machine_secrets` and the admin
  outputs into an ops-only prefix, keeping router credentials out of state),
  moving the orb pool to its own GCP project, per-task roles bound to a
  `thread_id`, and automating the required check are the steps that would let
  orbs do more of ops' work later. Each re-runs the required check.
