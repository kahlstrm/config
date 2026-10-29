# The CNI switch. Renders real machine configurations; only the resources
# that contact nodes are overridden.
override_resource {
  target = talos_machine.controlplane
}

override_resource {
  target = talos_machine.worker
}

override_resource {
  target = talos_machine_bootstrap.this
}

override_resource {
  target = talos_cluster_kubeconfig.this
  values = { kubeconfig_raw = "kubeconfig" }
}

variables {
  cluster_name         = "test"
  cluster_endpoint     = "https://api.test:6443"
  talos_config_version = "v1.11.5"
  kubernetes_version   = "1.37.1"
  bootstrap_node       = "cp1"
  control_planes = {
    cp1 = { ip = "10.0.0.11", install_disk = "/dev/sda", install_image = "installer:cp" }
  }
  workers = {
    w1 = { ip = "10.0.0.21", install_disk = "/dev/sda", install_image = "installer:worker" }
  }
  controlplane_patches = [
    "machine:\n  sysctls:\n    test.before: \"1\"\n",
    "cluster:\n  inlineManifests:\n    - name: other\n      contents: \"\"\n",
  ]
  worker_patches  = ["machine:\n  sysctls:\n    test.worker: \"1\"\n"]
  cilium_manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cilium-marker\n"
}

# The module before the switch, with callers passing the network-policy patch
# among their own, as local-talos did.
run "legacy" {
  command = apply

  module {
    source = "./tests/legacy"
  }
  # Shares the module's state, so both render with the same secrets.
  state_key = "cluster"

  variables {
    controlplane_patches = [
      "machine:\n  sysctls:\n    test.before: \"1\"\n",
      file("cni/flannel-controlplane.yaml"),
      "cluster:\n  inlineManifests:\n    - name: other\n      contents: \"\"\n",
    ]
  }
}

run "flannel_is_unchanged" {
  command   = apply
  state_key = "cluster"

  variables {
    cni = "flannel"
  }

  assert {
    condition     = nonsensitive(output.machine_configurations) == nonsensitive(run.legacy.machine_configurations)
    error_message = "With cni = flannel, machine configurations must be byte-identical to the module's before the switch."
  }
}

run "cilium" {
  command = apply

  variables {
    cni = "cilium"
  }

  assert {
    condition = alltrue([
      for config in [yamldecode(nonsensitive(output.machine_configurations["cp1"])), yamldecode(nonsensitive(output.machine_configurations["w1"]))] :
      config.cluster.network.cni.name == "none" && try(config.cluster.network.cni.flannel, null) == null && config.cluster.proxy.disabled
    ])
    error_message = "Every node must have no Talos CNI, no Flannel settings and kube-proxy disabled."
  }

  assert {
    condition = (
      [for manifest in yamldecode(nonsensitive(output.machine_configurations["cp1"])).cluster.inlineManifests : manifest.name] == ["other", "cilium"]
      && strcontains(nonsensitive(output.machine_configurations["cp1"]), "name: cilium-marker")
      && !strcontains(nonsensitive(output.machine_configurations["w1"]), "cilium-marker")
    )
    error_message = "Control planes, and only they, must carry the Cilium manifest next to their other inline manifests."
  }
}

run "cilium_needs_a_manifest" {
  command = plan

  variables {
    cni             = "cilium"
    cilium_manifest = null
  }

  expect_failures = [var.cilium_manifest]
}
