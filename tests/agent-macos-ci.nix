# Adapts the macOS example to a GitHub runner's logged-in user with offline installers.
port:
{ pkgs, lib, ... }:
{
  local.agentEnvironment = {
    user = "runner";
    t3Port = port;
    toolInstallers = import ./agent-tool-installers.nix { inherit pkgs lib; };
  };
}
