# Renders real machine configurations; only the resources that contact nodes
# are overridden.
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
    w1 = {
      ip            = "10.0.0.21"
      install_disk  = "/dev/nvme1n1"
      install_image = "installer:worker"
      patches       = ["apiVersion: v1alpha1\nkind: UserVolumeConfig\nname: only-w1\nprovisioning:\n  diskSelector:\n    match: disk.serial == \"s1\"\n"]
    }
    w2 = { ip = "10.0.0.22", install_disk = "/dev/sda", install_image = "installer:worker" }
  }
  controlplane_patches = ["machine:\n  sysctls:\n    test.controlplane: \"1\"\n"]
  worker_patches       = ["machine:\n  sysctls:\n    test.worker: \"1\"\n"]
}

run "patches_reach_their_nodes" {
  command = apply

  assert {
    condition = alltrue([
      strcontains(nonsensitive(output.machine_configurations["cp1"]), "hostname: cp1"),
      strcontains(nonsensitive(output.machine_configurations["cp1"]), "disk: /dev/sda"),
      strcontains(nonsensitive(output.machine_configurations["cp1"]), "image: installer:cp"),
      strcontains(nonsensitive(output.machine_configurations["w1"]), "hostname: w1"),
      strcontains(nonsensitive(output.machine_configurations["w1"]), "disk: /dev/nvme1n1"),
    ])
    error_message = "Each node must get its own hostname, install disk and install image."
  }

  assert {
    condition = alltrue([
      strcontains(nonsensitive(output.machine_configurations["cp1"]), "test.controlplane"),
      !strcontains(nonsensitive(output.machine_configurations["cp1"]), "test.worker"),
      strcontains(nonsensitive(output.machine_configurations["w2"]), "test.worker"),
      !strcontains(nonsensitive(output.machine_configurations["w2"]), "test.controlplane"),
    ])
    error_message = "Role patches must apply to their role only."
  }

  assert {
    condition = alltrue([
      strcontains(nonsensitive(output.machine_configurations["w1"]), "name: only-w1"),
      !strcontains(nonsensitive(output.machine_configurations["w2"]), "name: only-w1"),
    ])
    error_message = "A node's own patches must apply to that node only."
  }
}
