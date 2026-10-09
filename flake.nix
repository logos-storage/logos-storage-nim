{
  description = "Logos Storage build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=release-25.11";

    # 25.11's mingw gcc is 14.3, logos-nix builds with 15.2.
    nixpkgs-windows.url = "github:NixOS/nixpkgs?ref=release-26.05";
  };

  outputs = { self, nixpkgs, nixpkgs-windows }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];

      windowsSystem = "x86_64-windows";
      windowsBuildSystem = "x86_64-linux";

      allSystems = stableSystems ++ [ windowsSystem ];

      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;
      forNativeSystems = f: nixpkgs.lib.genAttrs stableSystems f;

      pkgsFor = system:
        if system != windowsSystem then
          import nixpkgs { inherit system; }
        else
          import nixpkgs-windows {
            localSystem = windowsBuildSystem;
            crossSystem = {
              config = "x86_64-w64-mingw32";
              # libstorage mallocs the strings the consumer frees, so we need
              # ucrt, Universal C Runtime, and not mingw's msvcrt default,
              # to be compatible with logos-storage-module.
              libc = "ucrt";
            };

          };
    in rec {
      packages = forAllSystems (system: let
        buildTarget = (pkgsFor system).callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
        };
        build = targets: buildTarget.override { inherit targets; };
      in rec {
        logos-storage-nim   = build ["all"];
        libstorage = build ["libstorage"];
        default = logos-storage-nim;
      });

      nixosModules.logos-storage-nim = { config, lib, pkgs, ... }: import ./nix/service.nix {
        inherit config lib pkgs self;
      };

      # A mingw-hosted dev shell would have to run on Windows.
      devShells = forNativeSystems (system: let
        pkgs = pkgsFor system;
      in {
        default = pkgs.mkShell {
          inputsFrom = [
            packages.${system}.logos-storage-nim
            packages.${system}.libstorage
          ];
          # Use real tools in interactive shells instead of the build-time version shim.
          nativeBuildInputs = with pkgs; [ git cargo nodejs_20 ];
          shellHook = ''
            export NIMBLE_DIR="$PWD/nimbledeps"
            export NIMBLE_FLAGS="--useSystemNim"
          '';
        };
      });

      # The NixOS test driver requires a Linux host.
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: let
        pkgs = pkgsFor system;
      in {
        logos-storage-nim-test = pkgs.testers.nixosTest {
          name = "logos-storage-nim-test";
          nodes = {
            server = { config, pkgs, ... }: {
              imports = [ self.nixosModules.logos-storage-nim ];
              services.logos-storage-nim.enable = true;
              services.logos-storage-nim.settings = {
                data-dir = "/var/lib/logos-storage-nim-test";
              };
              systemd.services.logos-storage-nim.serviceConfig.StateDirectory = "logos-storage-nim-test";
            };
          };
          testScript = ''
            print("Starting test: logos-storage-nim-test")
            server.start()
            server.wait_for_unit("logos-storage-nim.service")
            server.succeed("test -d /var/lib/logos-storage-nim-test")
            server.wait_until_succeeds("journalctl -u logos-storage-nim.service | grep 'Started Storage node'", 10)
          '';
        };
      });
    };
}
