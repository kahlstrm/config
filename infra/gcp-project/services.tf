# APIs the other layers use with this project as their quota project. Calls made
# with a project's own service account, such as ops-terraform's, bill to this
# project, so their APIs must be enabled here. disable_on_destroy is off so that
# removing a resource from Terraform never switches an API off under a running layer.
locals {
  project_services = toset([
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  # Enabled before this layer existed; iam.googleapis.com is new.
  imported_project_services = toset([
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "this" {
  for_each = local.project_services

  project            = local.project
  service            = each.value
  disable_on_destroy = false
}

import {
  for_each = local.imported_project_services
  to       = google_project_service.this[each.value]
  id       = "${local.project}/${each.value}"
}
