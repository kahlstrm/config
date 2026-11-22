{
  runCommand,
  fetchurl,
  ciliumManifest,
}:
let
  # The lab boots the Talos release production runs.
  version = (builtins.fromJSON (builtins.readFile ../../local-talos/versions.json)).talos;
  hashes = {
    "v1.14.4" = {
      talosctl = "sha256-Cmnj+baCxc2ES3ja4wX2BWzrhsX8xpE9zqeMUn7ZfO4=";
      vmlinuz = "sha256-dTUntUHmA7/ara80Z/WoVip4CN1r5NdifNZx2/1GOhY=";
      initramfs = "sha256-UziP8BrqXacliRiFYqxf2sSF/BObvA5DfohspCz5iKk=";
    };
  };
  hash =
    hashes.${version}
      or (throw "experiments/talos/assets.nix has no hashes for Talos ${version}; add them from the release's sha256sum.txt");
  release =
    name: hash:
    fetchurl {
      url = "https://github.com/siderolabs/talos/releases/download/${version}/${name}";
      inherit hash;
    };
  # Production's pin (local-talos/cilium), and an older release for the
  # upgrade scenario; bump it with production's.
  cilium = {
    inherit (ciliumManifest) version chart;
  };
  ciliumPrevious = {
    version = "1.20.3";
    chart = fetchurl {
      url = "https://helm.cilium.io/cilium-1.20.3.tgz";
      hash = "sha256-CAWlJzEYxDbJdyu5Vm2H7FWNiyXMLOXcMpGOzdNvLHw=";
    };
  };
in
runCommand "talos-lab-assets-${version}" { passthru = { inherit version cilium ciliumPrevious; }; }
  ''
    mkdir -p "$out/bin" "$out/cilium-previous"
    install -m755 ${release "talosctl-linux-amd64" hash.talosctl} "$out/bin/talosctl"
    ln -s ${release "vmlinuz-amd64" hash.vmlinuz} "$out/vmlinuz-amd64"
    ln -s ${release "initramfs-amd64.xz" hash.initramfs} "$out/initramfs-amd64.xz"
    ln -s ${cilium.chart} "$out/cilium-${cilium.version}.tgz"
    ln -s ${ciliumPrevious.chart} "$out/cilium-previous/cilium-${ciliumPrevious.version}.tgz"
  ''
