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
            overlays = [
              # nixpkgs 26.05 ships Nim 2.2.4, the project pins 2.2.10.
              # We prefer override the Nim version and keep the release branch
              # for nixpkgs-windows.url rather than pinning to a specific commit on
              # unstable branch and have the Nim version up to date.
              (final: prev: {
                nim-unwrapped-2_2 = prev.nim-unwrapped-2_2.overrideAttrs (old: rec {
                  version = "2.2.10";
                  src = prev.fetchurl {
                    url = "https://nim-lang.org/download/nim-${version}.tar.xz";
                    hash = "sha256-eVe37QBCBrzxC8xPO0dEFTh45i8kMVUqmo6dP0Do1dU=";
                  };
                  # Rewrite patch for 2.2.10.
                  patches = builtins.filter
                    (p: baseNameOf (toString p) != "extra-mangling-2.patch") old.patches;
                  # This flag turns on code that 2.2.10 no longer compiles.
                  # nixpkgs dropped it in the same commit that moved to 2.2.10.
                  kochArgs = builtins.filter
                    (f: f != "-d:nativeStacktrace") old.kochArgs;
                });
              })
            ];
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

      # Native only: a mingw-hosted dev shell would have to run on Windows, and
      # the nixosTest driver needs a Linux VM.
      devShells = forNativeSystems (system: let
        pkgs = pkgsFor system;
      in {
        default = pkgs.mkShell {
          inputsFrom = [
            packages.${system}.logos-storage-nim
            packages.${system}.libstorage
          ];
          # Not using buildInputs to override fakeGit and fakeCargo.
          nativeBuildInputs = with pkgs; [ git cargo nodejs_20 ];
        };
      });

      checks = forNativeSystems (system: let
        pkgs = pkgsFor system;
      in {
        logos-storage-nim-test = pkgs.nixosTest {
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
            machine.start()
            machine.wait_for_unit("logos-storage-nim.service")
            machine.succeed("test -d /var/lib/logos-storage-nim-test")
            machine.wait_until_succeeds("journalctl -u logos-storage-nim.service | grep 'Started Storage node'", 10)
          '';
        };
      });
    };
}
