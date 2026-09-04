{
  description = "Logos Storage build flake";

  inputs = {
    # A commit from nixpkgs 25.11 release: https://github.com/NixOS/nixpkgs/tree/release-25.11
    nixpkgs.url = "github:NixOS/nixpkgs/535f3e6942cb1cead3929c604320d3db54b542b9";

    # WINDOWS TARGET ONLY -- a second nixpkgs, scoped to the cross package set
    # so the native Linux and macOS outputs stay bit-identical.
    #
    # The rev is deliberately the SAME one logos-nix pins for its own Windows
    # target (logos-nix/flake.nix `nixpkgs-windows`). libstorage.dll and the C++
    # plugin that loads it end up in ONE directory, and both need
    # libstdc++-6.dll / libgcc_s_seh-1.dll / libwinpthread-1.dll -- filenames,
    # not store paths, once they are staged. Two nixpkgs revs would put two
    # different builds of each in contention for the same name, with whichever
    # is staged last silently winning for both. Matching the pin removes the
    # question.
    #
    # Not a compiler requirement: the pin above (gcc 14.3) cross-builds this
    # library just as well as logos-nix's (gcc 15.2) -- both were tried. The
    # constraint is agreement with the consumer, not any one version. If
    # logos-nix ever moves to this rev, drop this input entirely.
    nixpkgs-windows.url = "github:NixOS/nixpkgs/b5aa0fbd538984f6e3d201be0005b4463d8b09f8";
  };

  outputs = { self, nixpkgs, nixpkgs-windows }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];

      # x86_64-windows is a PSEUDO-SYSTEM. nixpkgs has no native Windows stdenv
      # -- `import nixpkgs { system = "x86_64-windows"; }` dies in cc-wrapper
      # ("called without required argument 'runtimeShell'") -- so this key means
      # "cross-compiled to x86_64-w64-mingw32". The derivations under it carry
      # system = x86_64-linux (a cross derivation's `system` is its BUILD
      # platform), which is exactly why `nix build .#packages.x86_64-windows.…`
      # runs on an ordinary Linux builder.
      #
      # The spelling is load-bearing: consumers reach these outputs by plain
      # string interpolation, `logos-storage.packages.${system}.libstorage`.
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
              # UCRT, not the legacy MSVCRT. This is not a style choice:
              # library/libstorage.nim allocates the strings it hands out with
              # <stdlib.h> malloc (see storage_version), and the C++ consumer
              # calls free() on them. msvcrt and ucrt keep SEPARATE heaps, so a
              # mismatch across that boundary is heap corruption, not a warning.
              # Everything downstream (logos-nix, and therefore every Qt module)
              # is ucrt, so libstorage must be too.
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
