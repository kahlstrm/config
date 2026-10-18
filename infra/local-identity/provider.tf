terraform {
  required_providers {
    pocketid = {
      version = "~> 2.4"
      source  = "trozz/pocketid"
    }
    sops = {
      version = "~> 1.4"
      source  = "carlpett/sops"
    }
  }
}

# Decrypting needs SOPS_AGE_SSH_PRIVATE_KEY_FILE pointing at the administrator key.
ephemeral "sops_file" "pocket_id" {
  source_file = "${path.module}/../local-kubernetes/platform/pocket-id/pocket-id.sops.yaml"
}

# Pocket ID must be running (deployed by Flux) before this layer is applied.
provider "pocketid" {
  base_url  = "https://id.kube.kalski.xyz"
  api_token = ephemeral.sops_file.pocket_id.data["stringData.STATIC_API_KEY"]
}
