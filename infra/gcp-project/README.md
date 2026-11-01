# gcp-project

Project-level GCP resources the other layers depend on but cannot manage themselves:

- the APIs enabled in `infra-464520` that the other layers use: Cloud Storage,
  Secret Manager and IAM;
- the Terraform state bucket `terraform-state-1751317459`, with uniform
  bucket-level access and the project members' legacy bucket and object roles;
- the ops VM's `ops-terraform` service account, its custom roles
  `terraformStateLister` and `secretMetadataAdmin`, and its grants on the state
  bucket, the project and the `local-kubernetes` secret.

Every GCP API enablement and IAM change made for these belongs here, not only in
`gcloud`.

## Operator only

Only the operator applies this layer, from their own machine and with their own
credentials, never from the ops VM. The layer grants `ops-terraform`'s own
permissions, so applying it from ops would let ops widen its own access. The ops
VM's account can neither read this layer's state nor change its own grants.

## Not managed here

The service account's key is uploaded from ops' own certificate (see
`modules/agent-ops/default.nix`). It changes whenever ops regenerates its keys,
for example after its `/var` volume is recreated, so it stays outside Terraform.

## Notes

IAM uses `*_iam_member` resources, which add or remove single bindings and leave
other grants alone. `google_project_service` has `disable_on_destroy = false`, so
removing one from Terraform never disables an API under a running layer.

The state lives in the bucket this layer manages, under `gcp-project/`.
`prevent_destroy` keeps Terraform from deleting the bucket. A project owner can
still repair the bucket's IAM with `gcloud` if a change ever locks the state out.

```bash
cd gcp-project && terraform init && terraform plan && terraform apply
```
