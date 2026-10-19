terraform {
  backend "gcs" {
    bucket = "terraform-state-1751317459"
    prefix = "local-identity"
  }
}
