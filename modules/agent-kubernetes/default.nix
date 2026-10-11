{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentKubernetes;
  package = pkgs.callPackage ./package.nix { inherit pkgs; };
  kubeconfig = "/run/agent-kubernetes/kubeconfig";
in
{
  options.local.agentKubernetes = {
    enable = lib.mkEnableOption "automatic short-lived Kubernetes reader credentials";
    bootstrapKubeconfigFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime issuer kubeconfig, provisioned through agenix outside the Nix store.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          lib.hasPrefix "/" cfg.bootstrapKubeconfigFile
          && !lib.hasPrefix "/nix/store/" cfg.bootstrapKubeconfigFile;
        message = "Kubernetes bootstrap credentials must be an absolute runtime path outside the Nix store.";
      }
    ];
    environment.systemPackages = [
      package
      package.kubectl
    ];
    environment.sessionVariables.KUBECONFIG = kubeconfig;
    systemd.services.t3code.environment.KUBECONFIG = kubeconfig;
    systemd.services.agent-kubernetes = {
      description = "Prepare Kubernetes reader access with automatic token acquisition";
      wantedBy = [ "multi-user.target" ];
      before = [ "t3code.service" ];
      serviceConfig = {
        User = "agent";
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "agent-kubernetes";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        ExecStart = "${package}/bin/agent-kube-setup ${lib.escapeShellArg cfg.bootstrapKubeconfigFile} ${package}/bin/agent-kube-credential ${kubeconfig}";
      };
    };
  };
}
