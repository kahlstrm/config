{ androidenv }:
# The SDK pieces upstream T3 Code's Android app (React Native 0.88) builds
# against, plus an emulator image. Versions follow react-native's
# gradle/libs.versions.toml; bump them with the T3 revision in t3code.json.
(androidenv.composeAndroidPackages {
  platformVersions = [
    "36"
    "37"
  ];
  buildToolsVersions = [
    "36.0.0"
    "37.0.0"
  ];
  ndkVersions = [ "27.1.12297006" ];
  cmakeVersions = [
    "3.22.1"
    "3.30.5"
  ];
  includeNDK = true;
  includeEmulator = true;
  includeSystemImages = true;
  systemImageTypes = [ "google_apis" ];
  abiVersions = [ "x86_64" ];
}).androidsdk
