# The cni variable as local-talos passes it to the cluster. Renders real
# machine configurations offline: Google is mocked, the networking state and
# the image factory are given, and nothing that contacts a node runs.
mock_provider "google" {}

override_data {
  target = data.terraform_remote_state.networking
  values = {
    outputs = {
      k8s_controlplanes = {
        "c1.k8s.kalski.xyz" = { ip = "10.10.10.11" }
        "c2.k8s.kalski.xyz" = { ip = "10.10.10.12" }
        "c3.k8s.kalski.xyz" = { ip = "10.10.10.13" }
      }
      k8s_workers = {
        "w1.k8s.kalski.xyz" = { ip = "10.10.10.21" }
        "w2.k8s.kalski.xyz" = { ip = "10.10.10.22" }
      }
      cluster_network  = "10.10.10.0/24"
      k8s_api_vip      = "10.10.10.10"
      k8s_api_hostname = "api.k8s.kalski.xyz"
    }
  }
}

override_resource {
  target = talos_image_factory_schematic.worker
  values = { id = "schematic" }
}

override_data {
  target = data.talos_image_factory_urls.worker
  values = { urls = { installer = "factory.talos.dev/metal-installer/schematic:v1.14.4" } }
}

override_resource {
  target = module.cluster.talos_machine.controlplane
}

override_resource {
  target = module.cluster.talos_machine.worker
}

override_resource {
  target = module.cluster.talos_machine_bootstrap.this
}

override_resource {
  target = module.cluster.talos_cluster_kubeconfig.this
  values = { kubeconfig_raw = "kubeconfig" }
}

# A plain plan or apply, without -var cni=...: every node stays on Flannel and
# kube-proxy, and no control plane carries the Cilium manifest.
run "default_stays_on_flannel" {
  command = apply

  assert {
    condition = length(module.cluster.machine_configurations) == 5 && alltrue([
      for hostname, config in module.cluster.machine_configurations : can(yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster)
    ])
    error_message = "Every node's machine configuration must render and decode."
  }

  assert {
    condition = alltrue([
      for hostname, config in module.cluster.machine_configurations :
      try(yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.network.cni.name, "flannel") == "flannel"
      && !try(yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.proxy.disabled, false)
      && !contains([for m in try(yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.inlineManifests, []) : m.name], "cilium")
    ])
    error_message = "Without -var cni=cilium, every node must keep Flannel and kube-proxy, and no control plane may carry the Cilium manifest."
  }
}

# What the cutover window applies with -var cni=cilium.
run "cilium_when_asked" {
  command = apply

  variables {
    cni = "cilium"
  }

  assert {
    condition = alltrue([
      for hostname, config in module.cluster.machine_configurations :
      yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.network.cni.name == "none" && yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.proxy.disabled
      && contains([for m in try(yamldecode(split("\n---\n", nonsensitive(config))[0]).cluster.inlineManifests, []) : m.name], "cilium") == startswith(hostname, "c")
    ])
    error_message = "With -var cni=cilium, every node must drop the Talos CNI and kube-proxy, and exactly the control planes carry the Cilium manifest."
  }
}

run "rejects_other_cnis" {
  command = plan

  variables {
    cni = "calico"
  }

  expect_failures = [var.cni]
}
