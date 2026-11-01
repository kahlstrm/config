# gcp-bootstrap

GCP resources the other layers depend on but cannot manage themselves:

- the Terraform state bucket `terraform-state-1751317459`, with uniform
  bucket-level access and the project members' legacy bucket roles;
- the ops VM's `ops-terraform` service account, its custom roles
  `terraformStateLister` and `secretMetadataAdmin`, and its grants on the state
  bucket, the project and the `local-kubernetes` secret.

Only the operator applies this layer, with their own credentials. The ops VM's
account can neither read this layer's state nor change its own grants.

IAM uses `*_iam_member` resources, which add or remove single bindings and leave
other grants alone. The service account's key is uploaded from ops' own
certificate (see `modules/agent-ops/default.nix`) and is not managed here.

The state lives in the bucket this layer manages, under `gcp-bootstrap/`.
`prevent_destroy` keeps Terraform from deleting the bucket. A project owner can
still repair the bucket's IAM with `gcloud` if a change ever locks the state out.

```bash
cd gcp-bootstrap && terraform init && terraform plan && terraform apply
```
