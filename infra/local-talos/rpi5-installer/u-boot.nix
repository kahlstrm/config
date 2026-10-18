# U-Boot with the RP1, USB and NVMe support missing from the upstream rpi_5 overlay.
# The patch adapts siderolabs/sbc-raspberrypi#88 and fixes NVMe DMA translation for the
# Pi 5 PCIe topology; this build boots c1 from NVMe.
{ buildUBoot, fetchFromGitHub }:
buildUBoot rec {
  version = "2026.10-rc3";
  src = fetchFromGitHub {
    owner = "u-boot";
    repo = "u-boot";
    tag = "v${version}";
    hash = "sha256-A2JWcLiuGl1Op2xw1zfzFnGHDCtDFG7E1NXlWFRzwaE=";
  };
  extraPatches = [ ./patches/0001-rpi5-rp1-usb-nvme.patch ];
  defconfig = "rpi_arm64_defconfig";
  extraMeta.platforms = [ "aarch64-linux" ];
  filesToInstall = [ "u-boot.bin" ];
}
