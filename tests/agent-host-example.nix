# Example configuration with every agent host module enabled; evaluated in CI.
{
  imports = [ ../modules/darwin/agents ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;
  system.primaryUser = "agent";
  users.users.agent.home = "/Users/agent";
  networking.localHostName = "agent-host-example";
  home-manager.users.agent.home.stateVersion = "26.05";

  local.agentHost = {
    alwaysOn.enable = true;
    t3 = {
      enable = true;
      previewPorts = [
        3000
        5173
      ];
    };
    deploy.enable = true;
    doctor.enable = true;
    instructions.enable = true;
    opper = {
      enable = true;
      claudeModels = {
        opus = "inceptron/moonshotai/Kimi-K2.7-Code";
        sonnet = "inceptron/zai-org/GLM-5.3";
        haiku = "inceptron/zai-org/GLM-5.3-Flash";
      };
      maxContextTokens = 262144;
      opencodeModels."inceptron/zai-org/GLM-5.3" = "GLM-5.3 (EU)";
    };
  };
}
