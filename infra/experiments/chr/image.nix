{
  runCommand,
  fetchurl,
  unzip,
}:
let
  version = "7.25";
  archive = fetchurl {
    url = "https://download.mikrotik.com/routeros/${version}/chr-${version}.img.zip";
    hash = "sha256-a5gSiDUN4qLHoyGL2CCrcCYzuM1s0znyuzTdofGiVQ4=";
  };
in
runCommand "chr-${version}" { nativeBuildInputs = [ unzip ]; } ''
  mkdir -p "$out"
  unzip -p ${archive} chr-${version}.img > "$out/chr-${version}.img"
''
