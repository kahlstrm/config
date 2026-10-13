{
  runCommand,
  fetchurl,
  unzip,
}:
let
  version = "7.21.3";
  archive = fetchurl {
    url = "https://download.mikrotik.com/routeros/${version}/chr-${version}.img.zip";
    hash = "sha256-2D3QBpKJFfiun670EvDMJ46OBQpBbQC2UPvqgcwFB4s=";
  };
in
runCommand "chr-${version}" { nativeBuildInputs = [ unzip ]; } ''
  mkdir -p "$out"
  unzip -p ${archive} chr-${version}.img > "$out/chr-${version}.img"
''
