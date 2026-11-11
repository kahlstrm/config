# Backups

Everything Git cannot rebuild is backed up nightly with [restic](https://restic.net) to two
repositories that share one password:

- **zima**: `/var/lib/restic/repo` on zima's system disk, not the media array, served over
  SFTP to the backup key only, chrooted to the repository. Fast local restores.
- **Storage Box**: a Hetzner Storage Box, off-site.

Every host writes to both repositories itself, so a dead zima or zima disk stops no other
host's off-site backup. poenttoe cannot reach zima, so it backs up off-site only, and zima
copies its snapshots down daily. Only zima's weekly prune deletes snapshots: it keeps 7
daily, 5 weekly and 12 monthly snapshots of each host. `modules/backup.nix` implements it.

## What is backed up

| From | What | How |
| --- | --- | --- |
| poenttoe | `/var/lib/headscale` (database, noise and DERP keys), SSH host keys | `backup.service`, 02:00 UTC |
| zima | nixarr state (Jellyfin, Seerr, Sonarr, Radarr, Prowlarr, Transmission) without caches, logs and downloaded metadata; `/data/.secret` (VPN and DNS credentials); SSH host keys | `backup.service`, 02:00 UTC |
| pannu | Bambuddy (`/var/lib/private/bambuddy`), `/var/lib/secrets` (DNS credentials), SSH host keys | `backup.service`, 02:00 UTC |
| klusse | Pocket ID's export: users, passkeys, OIDC clients, signing keys | CronJob `backup` in `pocket-id`, 01:30 UTC. `pocket-id export` takes a consistent copy while it runs. |
| klusse | Every object in the Terraform state bucket, including the Talos machine secrets in `local-talos`' state, encrypted to the recovery key | CronJob `terraform-state` in `backup`, 01:00 UTC, through a workload identity provider that reads only that bucket (`infra/gcp-project/backup.tf`) |

The cluster holds no backup credentials. Its jobs upload to a write-only SFTP drop on zima
and on pannu, which can add or replace files but not read, list or delete them, and both
hosts back the drop up with their own state. With the drop on two hosts, losing zima still
leaves the cluster's exports going off-site through pannu.

Hosts copy each SQLite database with SQLite's online backup first and back up the copy under
`/var/lib/backup/sqlite` instead of the live file. The SSH host keys let a rebuilt host keep
its identity, so its secrets decrypt without re-encrypting anything.

**Not backed up**, because it can be rebuilt or lost without harm: media on zima's array (it
can be fetched again and does not fit a small Storage Box), Prometheus, Loki and Alertmanager
data, Grafana's volume (dashboards and logins come from Git and Pocket ID), Harbor (a cache of
images that are rebuilt or pulled again), Docsight's 7-day modem history, the agents and ops
VMs, the laptops, and Secret Manager (below).

## Keys: what opens what

No backup credential is in this repository. The operator's Bitwarden holds:

- **the restic password**, which opens both repositories: host state and Pocket ID's export;
- **the backup SSH key**, which both repositories trust;
- **the Storage Box login**.

The hosts hold copies of these three, installed once (below), until the private secrets
repository provides them through `local.backup.credentials`.

Nothing that opens everything sits behind the restic password:

- **Pocket ID's `ENCRYPTION_KEY`** is not in the backup. It stays in the cluster's sops
  files, so the export and the key that decrypts its signing keys are opened by different
  keys.
- **The Terraform state**, with the Talos machine secrets, is encrypted in the pod to the
  offline recovery key's age public key (`apps/backup/recovery-recipient`) before restic
  sees it. The restic password opens only the ciphertext.
- **Secret Manager is not exported.** Its provider tokens (Cloudflare, Hetzner, ZeroTier,
  Telegram, Amp runner keys) are minted again in each provider's console, and the Flux key
  (`sops_age_key`) gets its recovery-key copy in the private secrets repository.
- **The drop key** (`backup-drop`, in `apps/backup`) only adds files to the drops.

## Secrets: backed up or regenerated

These can't be recreated. Losing one means rebuilding what depends on it:

- **Talos machine secrets** (cluster CA and keys, in `local-talos`' state): the cluster must be
  rebuilt. Backed up, encrypted to the recovery key.
- **Pocket ID's signing keys and passkeys** (its export) and **`ENCRYPTION_KEY`** (Git):
  without both, every OIDC client and passkey must be set up again.
- **Headscale's database and noise key**: every tailnet node must log in again.
- **Host SSH keys**: a new one means re-encrypting every secret the host reads.
- **`sops_age_key`**, **the recovery key**, **the restic password** and **the Storage Box
  login**: kept offline, in Bitwarden and the private secrets repository.

These are issued again in the provider's console or by the service itself, so they are not
backed up: the Cloudflare, Hetzner and ZeroTier tokens, the Telegram bot token, the Amp
webhook and runner tokens, router and app passwords, and the drop key.

## Checks and alerts

zima checks both repositories and writes the results as node-exporter metrics, which the
cluster's Prometheus scrapes (`platform/observability/scrapeconfig-zima.yaml`) and alerts on
(`prometheusrule-backup.yaml`). Critical alerts open an investigation thread through the Amp
alert intake and page on Telegram.

- `backup-check`, every 2 hours, lists each repository: the newest snapshot of each host, and
  the time of the newest backed-up copy of each file the cluster drops on zima and pannu.
  `BackupStale` fires when one is over 36 hours old, once the repository is over 36 hours
  old; `BackupRepositoryUnreachable` when a repository can't be listed for 3 hours;
  `BackupChecksNotRunning` when the check has not reported for 5 hours, which also covers
  zima being down.
- `backup-restore-check`, daily at 08:00 UTC: `restic check` of a different seventh of the
  data each day, then a restore of each host's latest snapshot. It checks the SSH host key,
  runs `PRAGMA integrity_check` on every SQLite copy, checks that Pocket ID's export has
  users and keys, and that the Terraform state is encrypted. `BackupRestoreCheckFailing`.
- `backup-prune`, weekly. `BackupPruneFailing`, a warning.

The checks can't decrypt the Terraform state or start Pocket ID with its key; restoring them
for real needs the recovery key and Git, below.

## Setting it up

Done once, by the operator:

1. In the Hetzner Console, create a Storage Box (BX11 is plenty) with SSH support.
2. In Bitwarden, generate a restic password (40 characters) and an ed25519 SSH key, and save
   the Storage Box login. Add the SSH key's public half to the Storage Box.
3. On zima, pannu and poenttoe, as root, install the three values. Each command waits for a
   value pasted from Bitwarden; end it with Enter, then Ctrl-D.

   ```sh
   install -d -m 0700 /etc/credstore.encrypted
   systemd-creds encrypt --name=backup-password - /etc/credstore.encrypted/backup-password
   systemd-creds encrypt --name=backup-ssh-key - /etc/credstore.encrypted/backup-ssh-key
   systemd-creds encrypt --name=backup-offsite - /etc/credstore.encrypted/backup-offsite
   ```

   `backup-offsite` is the repository's location,
   `sftp://<user>@<user>.your-storagebox.de:23/restic`. Then, on zima only, run
   `systemctl restart backup-server`, which authorizes the key and creates zima's repository.
   zima's next backup creates the off-site one.
4. Apply `infra/gcp-project` from the operator's machine, for the state export's read access.

The state export also needs the recovery key's age public key in
`infra/local-kubernetes/apps/backup/recovery-recipient`. It is public, so an agent commits it.

## Restoring

From a host that backs up, as root; `restic-backup` wraps restic with the installed
credentials:

```sh
restic-backup -r sftp:restic@zima.kalski.xyz:/repo snapshots
restic-backup -r <Storage Box location> restore latest --host <host> --target /tmp/restore
```

Without Git or any host, use plain restic with the password and the Storage Box login from
Bitwarden: `restic -r sftp://<user>@<user>.your-storagebox.de:23/restic restore latest --host zima --target restore`.

- **A host**: install it, restore its SSH host keys to `/etc/ssh` before the first deploy,
  then restore its state with its services stopped. SQLite databases come from
  `/var/lib/backup/sqlite/<original path>`.
- **Pocket ID**: its export is `/var/lib/backup-drop/incoming/pocket-id-export.zip` in zima's
  or pannu's snapshot. Scale Pocket ID to 0, run `pocket-id import --yes --path <export>` on
  an empty volume with `ENCRYPTION_KEY` from `platform/pocket-id/pocket-id.sops.yaml`, and
  scale it back.
- **Terraform state, with the Talos machine secrets**: `terraform-state.tar.sops` in the same
  directory. Decrypt it with the recovery key, `SOPS_AGE_KEY_FILE=<recovery key> sops decrypt
  --input-type json --output-type binary terraform-state.tar.sops | tar -x`, and copy the
  objects back into the bucket. The bucket also keeps old versions, and keeps deleted objects
  for 30 days.
