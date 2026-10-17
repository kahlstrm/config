{
  imports = [ ../modules/agents/environment ];
  nixpkgs = {
    hostPlatform = "aarch64-darwin";
    config.allowUnfree = true;
  };
  system.stateVersion = 6;
  networking.localHostName = "agent-macos-example";
  local.agentEnvironment = {
    revision = "example";
    deploy = {
      enable = true;
      configuration = "agent-macos-example";
    };
  };
  local.agentGithub = {
    enable = true;
    app = {
      id = "1";
      installationId = "2";
      keyFile = "/var/run/agent-github-app.pem";
    };
  };
}
