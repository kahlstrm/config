{ config, lib, ... }:
let
  cfg = config.local.agentGithub;
in
{
  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = true;
      config.credential = {
        helper = "${cfg.credentialHelper}/bin/git-credential-agent";
        useHttpPath = true;
      };
    };
  };
}
