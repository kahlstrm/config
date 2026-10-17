{ config, lib, ... }:
let
  cfg = config.local.agentGithub;
in
{
  config = lib.mkIf cfg.enable {
    environment.etc.gitconfig.text = lib.generators.toGitINI {
      credential = {
        helper = "${cfg.credentialHelper}/bin/git-credential-agent";
        useHttpPath = true;
      };
    };
  };
}
