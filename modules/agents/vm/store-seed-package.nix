{ writeShellApplication, coreutils }:
writeShellApplication {
  name = "agent-store-seed";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./store-seed.sh;
}
