# Talos creates these on the control planes and owns them: Flux manages
# everything else but not its own operator or FluxInstance. Bump the operator
# here, apply, then run `talosctl upgrade-k8s` to update the running cluster.
locals {
  flux_operator_version = "0.61.0"

  flux_bootstrap_patch = yamlencode({
    cluster = {
      extraManifests = [
        "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v${local.flux_operator_version}/install.yaml"
      ]
      inlineManifests = [{
        name     = "flux-instance"
        contents = file("${path.module}/manifests/flux-instance.yaml")
      }]
    }
  })
}
