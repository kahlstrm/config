final: prev: {
  mise = prev.mise.overrideAttrs (
    old:
    let
      # The default multi-call coreutils dispatches on argv[0], which the probe renames.
      coreutils = prev.coreutils.override { singleBinary = false; };
      cp = prev.lib.getExe' coreutils "cp";
      sleep = prev.lib.getExe' coreutils "sleep";
    in
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
      # build.rs signs its bundled notification helper with /usr/bin/codesign,
      # which the sandbox refuses to exec unless declared as an impure host dep
      # (allowed in modules/nix-config/darwin.nix).
      __impureHostDeps = (old.__impureHostDeps or [ ]) ++ [ "/usr/bin/codesign" ];

      # Tests probe /bin/cp and /bin/sleep, which the macOS sandbox hides; use store binaries instead.
      postPatch = old.postPatch + ''
        substituteInPlace ./src/backend/spm.rs \
          --replace-fail 'symlink("/bin/cp"' 'symlink("${cp}"' \
          --replace-fail '"copy-probe /bin/cp prefix/bin/copied"' '"copy-probe ${cp} prefix/bin/copied"'
        substituteInPlace ./src/toolset/running.rs \
          --replace-fail '["/usr/bin/sleep", "/bin/sleep"]' '["${sleep}"]'
      '';
    }
  );
}
