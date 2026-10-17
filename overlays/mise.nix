final: prev: {
  mise = prev.mise.overrideAttrs (
    old:
    let
      # The default multi-call coreutils dispatches on argv[0], which the probe renames.
      cp = prev.lib.getExe' (prev.coreutils.override { singleBinary = false; }) "cp";
    in
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
      # build.rs signs its bundled notification helper with /usr/bin/codesign,
      # which the sandbox refuses to exec unless declared as an impure host dep
      # (allowed in modules/nix-config/darwin.nix).
      __impureHostDeps = (old.__impureHostDeps or [ ]) ++ [ "/usr/bin/codesign" ];

      # The direct-exec test probes /bin/cp, which the sandbox hides; use a store cp instead.
      postPatch = old.postPatch + ''
        substituteInPlace ./src/backend/spm.rs \
          --replace-fail 'symlink("/bin/cp"' 'symlink("${cp}"' \
          --replace-fail '"copy-probe /bin/cp prefix/bin/copied"' '"copy-probe ${cp} prefix/bin/copied"'
      '';
    }
  );
}
