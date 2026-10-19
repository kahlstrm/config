# Pocket ID Identity

Pocket ID users, the `admins` group and OIDC clients. Apply after Flux has
started Pocket ID; the provider uses its public URL and the static API key from
[the SOPS-encrypted Secret](../local-kubernetes/platform/pocket-id/pocket-id.sops.yaml).

The SOPS provider can't prompt for a key passphrase, so decrypt with the
cluster's age key from Secret Manager:

```bash
export SOPS_AGE_KEY=$(gcloud secrets versions access latest --secret=local-kubernetes | jq -er .sops_age_key)
terraform init && terraform plan && terraform apply
```

An administrator SSH key without a passphrase also works through
`SOPS_AGE_SSH_PRIVATE_KEY_FILE`.

Clients are public and use PKCE, so they have no secrets to hand to the cluster.

## Passkeys

Open the one-time link to register a passkey:

```bash
terraform output -raw pocket_id_enrolment_url
```

Issue a new link with `terraform apply -replace=pocketid_one_time_access_token.kalle`.
