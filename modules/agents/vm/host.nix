{
  config,
  lib,
  inputs,
  ...
}:
let
  vms = config.local.agentVMs;
  runner = name: config.microvm.vms.${name}.evaluatedConfig.config.microvm.declaredRunner;
  guestInterfaces = name: config.microvm.vms.${name}.evaluatedConfig.config.microvm.interfaces;
  budget = config.local.agentVMDiskBudgetMiB;
  # Each VM reserves its volumes' full size before it starts, so they must fit together.
  volumeMiB = lib.foldl' (sum: volume: sum + volume.size) 0 (
    lib.concatMap (name: config.microvm.vms.${name}.evaluatedConfig.config.microvm.volumes) (
      lib.attrNames vms
    )
  );
in
{
  config = lib.mkIf (vms != { }) {
    assertions =
      lib.optional (budget != null) {
        assertion = volumeMiB <= budget;
        message = "Agent VM volumes need ${toString volumeMiB} MiB, more than local.agentVMDiskBudgetMiB (${toString budget} MiB).";
      }
      ++ lib.concatLists (
        lib.mapAttrsToList (name: cfg: [
          {
            assertion = lib.any (interface: interface.type == "tap" && interface.id == cfg.network.interface) (
              guestInterfaces name
            );
            message = "local.agentVMs.${name}: configuration ${cfg.configuration} has no tap interface ${cfg.network.interface}.";
          }
          {
            assertion = lib.all (client: client != name && vms ? ${client}) (lib.attrNames cfg.allowedClients);
            message = "local.agentVMs.${name}.allowedClients must name other agent VMs.";
          }
        ]) vms
      );
    local.agentNetworks = lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair cfg.unitPrefix {
        vm = name;
        inherit (cfg.network) interface hostAddress guestAddress;
        inherit (cfg) allowedServices;
        # Unknown clients fail the assertion above instead of an attribute lookup here.
        allowedClients = lib.mapAttrs (client: allowed: {
          address = vms.${client}.network.guestAddress;
          inherit (allowed) tcpPorts;
        }) (lib.filterAttrs (client: _: vms ? ${client}) cfg.allowedClients);
      }
    ) vms;
    networking.networkmanager.unmanaged = lib.mapAttrsToList (
      _: cfg: "interface-name:${cfg.network.interface}"
    ) vms;
    systemd.network.enable = true;
    systemd.network.networks = lib.mapAttrs' (
      _: cfg:
      lib.nameValuePair "10-${cfg.unitPrefix}-tap" {
        matchConfig.Name = cfg.network.interface;
        address = [ "${cfg.network.hostAddress}/${toString cfg.network.prefixLength}" ];
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
      }
    ) vms;
    microvm.vms = lib.mapAttrs (_: cfg: {
      # Unless the VM opts in, a host switch only stages a new boot image, so it never
      # interrupts running agent sessions.
      restartIfChanged = cfg.restartOnSwitch;
      evaluatedConfig = inputs.self.nixosConfigurations.${cfg.configuration}.extendModules {
        modules = [
          {
            microvm.vcpu = lib.mkForce cfg.cores;
            microvm.mem = lib.mkForce cfg.memoryMiB;
          }
        ];
      };
    }) vms;
    # Switch output is where a staged-but-unbooted image would otherwise go unnoticed.
    system.activationScripts = lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair "${cfg.unitPrefix}-vm-restart-pending" {
        text = ''
          booted=$(readlink ${config.microvm.stateDir}/${name}/booted || true)
          if [ -n "$booted" ] && [ "$booted" != ${runner name} ]; then
            echo "agent VM keeps its running image until: systemctl restart microvm@${name}" >&2
          fi
        '';
      }
    ) (lib.filterAttrs (_: cfg: !cfg.restartOnSwitch) vms);
    systemd.services = lib.mapAttrs' (
      name: cfg:
      lib.nameValuePair "microvm@${name}" {
        requires = [ "${cfg.unitPrefix}-network.service" ];
        after = [ "${cfg.unitPrefix}-network.service" ];
        partOf = [ "${cfg.unitPrefix}-network.service" ];
        serviceConfig = {
          CPUQuota = "${toString (cfg.cores * 100)}%";
          MemoryMax = "${toString (cfg.memoryMiB + 2048)}M";
          TasksMax = 512;
        }
        # Stopping sends the guest an ACPI power-off and waits for QEMU to exit. A switch
        # stops a VM that restarts on switch without warning, so its services get time to
        # stop cleanly: the guest's 90-second default for a unit that hangs, plus the rest.
        // lib.optionalAttrs cfg.restartOnSwitch { TimeoutStopSec = "3min"; };
      }
    ) vms;
    services.nginx.virtualHosts = lib.mkMerge (
      lib.mapAttrsToList (
        _: cfg:
        lib.mkIf (cfg.proxyHost != null) {
          ${cfg.proxyHost} = {
            forceSSL = true;
            useACMEHost = cfg.acmeHost;
            locations."/" = {
              proxyPass = "http://${cfg.network.guestAddress}:${toString cfg.t3Port}";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_read_timeout 3600s;
              '';
            };
          };
        }
      ) vms
    );
  };
}
