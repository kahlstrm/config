{
  description = "Development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # U-Boot for the Pi 5 installer: RP1/NVMe support and JetKVM USB fixes,
    # pinned to the build verified on c1 (rpi5-installer/verified-boot.sha256).
    u-boot.url = "github:kahlstrm/u-boot/24fecc88c14b3fedbc2f7aa132bc620b84fd4319";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      u-boot,
      ...
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "terraform";
        };
        chrImage = pkgs.callPackage ./experiments/chr/image.nix { };
        ciliumManifest = pkgs.callPackage ./local-talos/cilium { };
        chrPackages = with pkgs; [
          go
          python3
          qemu
          openssh
          curl
          just
        ];
        # The Talos lab boots amd64 release assets.
        talosLab = pkgs.lib.optionalAttrs (system == "x86_64-linux") (
          let
            talosAssets = pkgs.callPackage ./experiments/talos/assets.nix { inherit ciliumManifest; };
          in
          {
            packages.talos-lab-assets = talosAssets;
            devShells.talos = pkgs.mkShellNoCC {
              TALOS_ASSETS = talosAssets;
              CGO_ENABLED = 0;
              packages = with pkgs; [
                talosAssets
                go
                qemu_kvm
                kubectl
                kubernetes-helm
                just
              ];
            };
          }
        );
      in
      pkgs.lib.recursiveUpdate {
        packages = {
          chr-image = chrImage;
          cilium-manifest = ciliumManifest;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          iperf3-image = import ./experiments/network-diagnostics/iperf3-image.nix { inherit pkgs; };
        }
        // pkgs.lib.optionalAttrs (u-boot.packages ? ${system}) {
          rpi5-u-boot = u-boot.packages.${system}.rpi5-u-boot;
        };
        checks = {
          # The committed render must match the pin and values it came from.
          cilium-manifest = pkgs.runCommand "cilium-manifest-current" { } ''
            if ! diff -u ${./local-talos/manifests/cilium.yaml} ${ciliumManifest} >diff.txt; then
              head -n 100 diff.txt
              echo "local-talos/manifests/cilium.yaml is stale; run \`just cilium-render\` in infra/." >&2
              exit 1
            fi
            touch "$out"
          '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          pocket-id-sync = pkgs.testers.runNixOSTest (
            import ./local-kubernetes/apps/pocket-id-sync/test.nix { inherit pkgs; }
          );
          # promtool reads plain rule files, so each PrometheusRule's spec is extracted
          # to rules/<metadata.name>.yaml for the tests to load.
          alert-rules =
            pkgs.runCommand "alert-rules"
              {
                nativeBuildInputs = [
                  pkgs.prometheus.cli
                  pkgs.yq-go
                ];
              }
              ''
                cp ${./local-kubernetes/platform/observability/tests}/*.yaml .
                mkdir rules
                grep -rl --include='*.yaml' '^kind: PrometheusRule' ${./local-kubernetes} | while read -r rule; do
                  yq '.spec' "$rule" >"rules/$(yq '.metadata.name' "$rule").yaml"
                done
                promtool test rules *.yaml
                touch $out
              '';
        };
        devShells.default = import ./shell.nix { inherit pkgs; };
        devShells.kubernetes = pkgs.mkShellNoCC {
          packages = with pkgs; [
            kubeconform
            kustomize
            yq-go
          ];
        };
        devShells.chr = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages;
        };
        devShells.chr-dns = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages ++ [
            pkgs.opentofu
            pkgs.jq
            pkgs.dig
          ];
        };
        devShells.chr-bootstrap = pkgs.mkShellNoCC {
          CHR_IMAGE = chrImage;
          packages = chrPackages ++ [
            pkgs.opentofu
            pkgs.jq
            pkgs.dig
          ];
        };
      } talosLab
    );
}
