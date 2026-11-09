{
  config,
  lib,
  pkgs,
  ...
}:
let
  vms = lib.attrNames config.local.agentVMs;
  exporter = config.services.prometheus.exporters.node.enable;
  dir = "/run/agent-vm-metrics";
  # KVM reports a vCPU thread's run delay, the time it was runnable but not running,
  # to the guest as steal. QEMU names those threads "CPU <n>/KVM".
  collector = pkgs.writeShellApplication {
    name = "agent-vm-steal-metrics";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      while true; do
        {
          echo "# HELP agent_vm_vcpu_wait_seconds_total Time the VM's vCPU threads waited for a host CPU: the guest's steal."
          echo "# TYPE agent_vm_vcpu_wait_seconds_total counter"
          echo "# HELP agent_vm_vcpus vCPU threads of the running VM."
          echo "# TYPE agent_vm_vcpus gauge"
          for vm in "$@"; do
            pid=$(systemctl show -P MainPID "microvm@$vm.service")
            [ "$pid" -gt 0 ] || continue
            ns=0 vcpus=0
            for task in /proc/"$pid"/task/*; do
              comm=$(cat "$task/comm" 2>/dev/null) || continue
              [[ $comm == "CPU "*/KVM ]] || continue
              read -r _ wait _ <"$task/schedstat" || continue
              ns=$((ns + wait)) vcpus=$((vcpus + 1))
            done
            [ "$vcpus" -gt 0 ] || continue
            printf 'agent_vm_vcpu_wait_seconds_total{vm="%s"} %d.%09d\n' "$vm" $((ns / 1000000000)) $((ns % 1000000000))
            printf 'agent_vm_vcpus{vm="%s"} %d\n' "$vm" "$vcpus"
          done
        } >${dir}/.steal.prom
        mv ${dir}/.steal.prom ${dir}/steal.prom
        sleep 15
      done
    '';
  };
in
{
  # Feeds node-exporter's textfile collector where the host runs it, so Prometheus
  # sees each agent VM's steal from outside the guest.
  config = lib.mkIf (vms != [ ]) {
    services.prometheus.exporters.node.extraFlags = lib.mkIf exporter [
      "--collector.textfile.directory=${dir}"
    ];
    systemd.services.agent-vm-steal-metrics = lib.mkIf exporter {
      description = "Agent VMs' vCPU wait time for node-exporter";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe collector} ${lib.escapeShellArgs vms}";
        DynamicUser = true;
        RuntimeDirectory = "agent-vm-metrics";
        RuntimeDirectoryMode = "0755";
        Restart = "always";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
