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
                # Applies local-talos/cilium/post-render.yq to the lab's Cilium renders.
                yq-go
                just
                # The cilium-terraform scenario applies production's talos-cluster module.
                terraform
              ];
            };
          }
        );
        # The T3 mobile lab builds T3's Android app and runs it on an emulator.
        t3MobileLab = pkgs.lib.optionalAttrs (system == "x86_64-linux") (
          let
            # Only builds the Android SDK, whose components are all unfree.
            androidPkgs = import nixpkgs {
              inherit system;
              config = {
                android_sdk.accept_license = true;
                allowUnfree = true;
              };
            };
            androidSdk = androidPkgs.callPackage ./experiments/t3-mobile/android.nix { };
          in
          {
            devShells.t3-mobile = pkgs.mkShellNoCC {
              ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
              CGO_ENABLED = 0;
              packages = with pkgs; [
                go
                just
                git
                iproute2
                jdk17
                nodejs_26
                pnpm
              ];
            };
          }
        );
      in
      pkgs.lib.recursiveUpdate {
        packages = {
          chr-image = chrImage;
          cilium-manifest = ciliumManifest;
          # Recreates pods left on the previous network after the Cilium switch.
          cni-pods = pkgs.buildGoModule {
            pname = "cni-pods";
            version = "0";
            src = pkgs.lib.fileset.toSource {
              root = ./experiments/talos;
              fileset = pkgs.lib.fileset.unions [
                ./experiments/talos/go.mod
                ./experiments/talos/cmd/cni-pods
                ./experiments/talos/internal/cnipods
              ];
            };
            subPackages = [ "cmd/cni-pods" ];
            vendorHash = null;
            env.CGO_ENABLED = 0;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            # The caller's kubectl comes first.
            postInstall = ''
              wrapProgram $out/bin/cni-pods --suffix PATH : ${pkgs.kubectl}/bin
            '';
            meta.mainProgram = "cni-pods";
          };
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
          # The T3 mobile lab's helper, without the Android SDK its scenarios need.
          t3-mobile-lab =
            pkgs.runCommand "t3-mobile-lab"
              {
                nativeBuildInputs = [ pkgs.go ];
                CGO_ENABLED = 0;
              }
              ''
                export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache GOFLAGS=-mod=mod
                cp -r ${./experiments/t3-mobile} lab && chmod -R u+w lab && cd lab
                go vet ./...
                go vet -tags=integration ./...
                go test -count=1 ./...
                test -z "$(gofmt -l .)"
                touch $out
              '';
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
      } (pkgs.lib.recursiveUpdate talosLab t3MobileLab)
    );
}
