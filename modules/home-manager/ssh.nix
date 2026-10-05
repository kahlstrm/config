{
  lib,
  isDarwin,
  config,
  ...
}:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [
      "${config.home.homeDirectory}/.ssh/config_external"
    ];
    extraOptionOverrides = lib.optionalAttrs isDarwin { UseKeychain = "yes"; };
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
        HashKnownHosts = false;
        SetEnv.TERM = "xterm-256color";
      };
      "pannu" = {
        HostName = "p.kalski.xyz";
        User = "kahlstrm";
      };
      "pannu-agents" = {
        HostName = (import ../agents/settings.nix).network.guestAddress;
        User = "agent";
        ProxyJump = "pannu";
        ForwardAgent = false;
      };
      "zima" = {
        HostName = "zima.kalski.xyz";
        User = "kahlstrm";
      };
      "poenttoe" = {
        HostName = "poenttoe.kalski.xyz";
        User = "kahlstrm";
      };
      "kuberack" = {
        HostName = "kuberack.networking.kalski.xyz";
      };
      "stationary" = {
        HostName = "stationary.networking.kalski.xyz";
      };
    };
  };
}
