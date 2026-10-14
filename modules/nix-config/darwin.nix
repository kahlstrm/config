{ ... }:
{
  nix.gc.interval = {
    Weekday = 0; # Sunday
    Hour = 0;
    Minute = 0;
  };
  nix.settings.sandbox = true;
  nix.settings.trusted-users = [ "@admin" ];
  # Nix's darwin defaults, plus codesign for packages that sign app bundles (see overlays/mise.nix)
  nix.settings.allowed-impure-host-deps = [
    "/System/Library"
    "/bin/sh"
    "/dev"
    "/usr/lib"
    "/usr/bin/codesign"
  ];
  launchd.daemons.nix-gc.serviceConfig = {
    StandardOutPath = "/var/log/nix-gc.log";
    StandardErrorPath = "/var/log/nix-gc.log";
  };
}
