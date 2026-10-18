# T3 Code's server without the desktop app or the workspace's build tooling,
# mirroring upstream's CLI archive: the bundled server plus the dependencies the
# bundle leaves external. Upstream's own selection code picks those
# dependencies; their closure comes from the existing build's pnpm tree.
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
runCommand "t3code-server-${t3code-unwrapped.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    inherit (t3code-unwrapped) version;
    passthru = (t3code-unwrapped.passthru or { }) // {
      inherit (t3code-unwrapped) src;
    };
    meta = t3code-unwrapped.meta // {
      mainProgram = "t3";
    };
  }
  ''
    full=${t3code-unwrapped}/libexec/t3code
    lean=$out/libexec/t3code
    mkdir -p "$lean"/apps/server/node_modules "$lean"/node_modules/.pnpm
    cp -a "$full"/apps/server/dist "$lean"/apps/server/

    ${lib.getExe nodejs} ${./select-runtime-externals.mjs} ${t3code-unwrapped.src} \
      > "$lean"/runtime-externals.txt
    queue=()
    while read -r name; do
      link=$full/apps/server/node_modules/$name
      if [ ! -L "$link" ]; then
        echo "runtime external $name is not installed for the server" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$lean/apps/server/node_modules/$name")"
      cp -a "$link" "$lean/apps/server/node_modules/$name"
      queue+=("$(realpath "$link")")
    done < "$lean"/runtime-externals.txt

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

    # Upstream hoists the closure next to the bundle; keep the workspace's
    # top-level links into it so the bundle resolves those packages as before.
    for link in "$full"/node_modules/* "$full"/node_modules/@*/*; do
      [ -L "$link" ] || continue
      entry=$(realpath "$link")
      [[ $entry == "$full/node_modules/.pnpm/"* ]] || continue
      entry=''${entry#"$full/node_modules/.pnpm/"}
      if [ -n "''${copied[''${entry%%/*}]:-}" ]; then
        name=''${link#"$full/node_modules/"}
        mkdir -p "$(dirname "$lean/node_modules/$name")"
        cp -a "$link" "$lean/node_modules/$name"
      fi
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
