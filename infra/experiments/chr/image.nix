{
  runCommand,
  fetchurl,
  unzip,
}:
let
  version = "7.25.1";
  archive = fetchurl {
    url = "https://download.mikrotik.com/routeros/${version}/chr-${version}.img.zip";
    hash = "sha256-x46OJMp41/E0lhQOYAcC3wf+XFfRpdbQJWVMhHbtLtI=";
  };
in
runCommand "chr-${version}" { nativeBuildInputs = [ unzip ]; } ''
  mkdir -p "$out"
  unzip -p ${archive} chr-${version}.img > "$out/chr-${version}.img"
''
