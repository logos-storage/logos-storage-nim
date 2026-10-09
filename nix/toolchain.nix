{ pkgs }:
let
  tools = pkgs.callPackage ./tools.nix {};
  versions = ../tools/scripts/toolchain-versions.sh;
  value = key: tools.findKeyValue "${key}=(.*)" versions;
  native = pkgs.pkgsBuildBuild;
  unwrapped = native.nim-unwrapped-2_2.overrideAttrs (old: {
    version = value "NIM_VERSION";
    src = native.fetchurl {
      url = "https://nim-lang.org/download/nim-${value "NIM_VERSION"}.tar.xz";
      sha256 = value "NIM_SHA256";
    };
    patches = builtins.filter
      (p: baseNameOf (toString p) != "extra-mangling-2.patch") old.patches;
    kochArgs = builtins.filter (f: f != "-d:nativeStacktrace") old.kochArgs;
  });
  nim = (native.nim-2_2.override { nim-unwrapped-2_2 = unwrapped; }).overrideAttrs (old:
    native.lib.optionalAttrs pkgs.stdenv.hostPlatform.isWindows {
      # Keep the compiler native, but let --os/--cpu select the target before
      # config conditionals run. nixpkgs' forced Linux setting adds -ldl even
      # when the eventual target is Windows.
      postInstall = (old.postInstall or "") + ''
        sed -i '/^os = /d; /^cpu = /d' "$out/etc/nim/nim.cfg"
        sed -i '/^switch("os",/d; /^switch("cpu",/d' "$out/etc/nim/config.nims"
      '';
    });
  nimbleSource = builtins.fetchTree {
    type = "git";
    url = "https://github.com/nim-lang/nimble.git";
    rev = value "NIMBLE_REV";
    submodules = true;
    narHash = "sha256-48g2K3swvjSOAYs7Eait7BLxIye8nLiqhyqi6xYPGXk=";
  };
in {
  inherit nim;
  nimble = native.stdenv.mkDerivation {
    pname = "nimble";
    version = value "NIMBLE_VERSION";
    src = nimbleSource.outPath;
    # Nimble 0.26 otherwise re-downloads installed #tag/#commit dependencies,
    # which is impossible inside the network-free build sandbox.
    patches = [ ./nimble-offline-pins.patch ];
    nativeBuildInputs = [ nim native.makeWrapper ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      nim c -d:release --parallelBuild:$NIX_BUILD_CORES --nimcache:$TMPDIR/nimcache --out:nimble src/nimble.nim
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 nimble $out/bin/nimble
      wrapProgram $out/bin/nimble \
        --prefix LD_LIBRARY_PATH : ${native.lib.makeLibraryPath [ native.openssl ]}
      runHook postInstall
    '';
  };
}
