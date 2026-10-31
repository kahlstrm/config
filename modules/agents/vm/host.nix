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
in
{
  config = lib.mkIf (vms != { }) {
    assertions = lib.concatLists (
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
      # A host switch only stages a new boot image, so it never interrupts running agent sessions.
      restartIfChanged = false;
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
    ) vms;
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
        };
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
