# T3 Code's server without the desktop app or the workspace's build tooling,
# mirroring upstream's CLI archive: the bundled server plus the packages the
# bundle leaves external. The list follows upstream's
# scripts/lib/cli-external-packages.ts; entries match as name prefixes.
{
  lib,
  runCommand,
  makeBinaryWrapper,
  nodejs,
  t3code-unwrapped,
  resourceMonitor,
  # What nixpkgs' t3code wrapper would put on PATH, without its per-file symlink tree.
  runtimePackages ? [ ],
}:
let
  externalPrefixes = [
    "@cursor/sdk"
    "playwright-core"
    "node-pty"
    "ffi-rs"
    "@yuuang/"
    "@ff-labs/"
    "@napi-rs/keyring"
    "node-gyp-build"
    "node-addon-api"
    "bufferutil"
    "utf-8-validate"
    # Runtime dependencies of @cursor/sdk
    "@bufbuild/protobuf"
    "@connectrpc/connect"
    "@statsig/js-client"
    "@statsig/client-core"
    "zod"
    "undici"
    "@fastify/busboy"
  ];
in
runCommand "t3code-server-${t3code-unwrapped.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    inherit (t3code-unwrapped) version;
    passthru = t3code-unwrapped.passthru or { };
    meta = t3code-unwrapped.meta // {
      mainProgram = "t3";
    };
  }
  ''
    full=${t3code-unwrapped}/libexec/t3code
    lean=$out/libexec/t3code
    mkdir -p "$lean"/apps/server/node_modules "$lean"/node_modules/.pnpm
    cp -a "$full"/apps/server/dist "$lean"/apps/server/

    isExternal() {
      local prefix
      for prefix in ${lib.escapeShellArgs externalPrefixes}; do
        [[ $1 == "$prefix"* ]] && return 0
      done
      return 1
    }

    # Top-level links the bundle resolves externals through, scoped ones included.
    queue=()
    for modules in apps/server/node_modules node_modules; do
      for link in "$full/$modules"/* "$full/$modules"/@*/*; do
        name=''${link#"$full/$modules/"}
        if [ -L "$link" ] && isExternal "$name"; then
          mkdir -p "$(dirname "$lean/$modules/$name")"
          cp -a "$link" "$lean/$modules/$name"
          queue+=("$(realpath "$link")")
        fi
      done
    done

    # Copy each external's pnpm entry and, transitively, the entries its links point to.
    declare -A copied=()
    while [ ''${#queue[@]} -gt 0 ]; do
      target=''${queue[0]}
      queue=("''${queue[@]:1}")
      entry=''${target#"$full/node_modules/.pnpm/"}
      entry=''${entry%%/*}
      [ -n "''${copied[$entry]:-}" ] && continue
      copied[$entry]=1
      cp -a "$full/node_modules/.pnpm/$entry" "$lean/node_modules/.pnpm/"
      for dep in "$full/node_modules/.pnpm/$entry"/node_modules/* "$full/node_modules/.pnpm/$entry"/node_modules/@*/*; do
        [ -L "$dep" ] && queue+=("$(realpath "$dep")")
      done
    done

    find "$lean" -xtype l -delete
    makeWrapper ${lib.getExe nodejs} "$out"/bin/t3 \
      --add-flags "$lean"/apps/server/dist/bin.mjs \
      --prefix PATH : ${lib.makeBinPath runtimePackages} \
      --set-default T3CODE_RESOURCE_MONITOR_PATH ${lib.getExe resourceMonitor}

    # The PTY addon is the one native module every session needs.
    (cd "$lean"/apps/server/dist && ${lib.getExe nodejs} --input-type=module -e "await import('node-pty')")
    HOME=$TMPDIR "$out"/bin/t3 --help > /dev/null
  ''
