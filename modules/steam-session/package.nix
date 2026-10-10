{
  buildGoModule,
  systemd,
  homeDirectory ? "/home/steam-machine",
}:
buildGoModule {
  pname = "steam-session";
  version = "1.0.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  subPackages = [
    "cmd/steam-session"
    "cmd/steam-session-control"
  ];
  ldflags = [
    "-s"
    "-w"
    "-X main.systemctlPath=${systemd}/bin/systemctl"
    "-X main.journalctlPath=${systemd}/bin/journalctl"
    "-X main.homeDirectory=${homeDirectory}"
  ];
}
