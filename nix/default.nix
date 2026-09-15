{
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  targets ? ["all"],
  # Options: 0,1,2
  verbosity ? 1,
  commit ? builtins.substring 0 7 (src.rev or "dirty"),
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
    "x86_64-darwin" "aarch64-darwin"
  ],
  # Perform 2-stage bootstrap instead of 3-stage to save time.
  quickAndDirty ? true,
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) lib writeScriptBin callPackage;

  revision = lib.substring 0 8 (src.rev or "dirty");

  tools = callPackage ./tools.nix {};

  # Pin GCC/CLang versions
  stdenv = if pkgs.stdenv.isLinux then pkgs.gcc13Stdenv else pkgs.clang18Stdenv;

in stdenv.mkDerivation rec {
  pname = "storage";

  version = "${tools.findKeyValue "version = \"([0-9]+\.[0-9]+\.[0-9]+)\"" ../storage.nimble}-${revision}";

  inherit src;

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [
    openssl
    gmp
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    cmake
    which
    fakeGit
  ] ++ lib.optionals stdenv.isLinux [
    lsb-release
  ] ++ lib.optionals stdenv.isDarwin [
    darwin.cctools
  ];

  # Disable CPU optimizations that make binary not portable.
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "QUICK_AND_DIRTY_COMPILER=${if quickAndDirty then "1" else "0"}"
    "QUICK_AND_DIRTY_NIMBLE=${if quickAndDirty then "1" else "0"}"
  ];

  configurePhase = ''
    # Avoid Nim cache permission errors.
    export XDG_CACHE_HOME=$TMPDIR
    # Force build of Nimble from dist/nimble source.
    export NIMBLE_COMMIT=""
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
  '';

  preBuild = ''
    pushd vendor/nimbus-build-system/vendor/Nim
    mkdir dist
    cp -r ${callPackage ./nimble.nix {}}    dist/nimble
    cp -r ${callPackage ./checksums.nix {}} dist/checksums
    cp -r ${callPackage ./csources.nix {}}  csources_v3
    chmod 777 -R dist/nimble csources_v3
    popd
  '';

  installPhase = ''
    if [ -f build/storage ]; then
      mkdir -p $out/bin
      cp build/storage $out/bin/
    else
      mkdir -p $out/lib $out/include/generated
      cp build/libstorage* $out/lib/
      cp library/libstorage.h $out/include/
      cp library/generated/*.h $out/include/generated/
    fi
  '';

  meta = with pkgs.lib; {
    description = "Logos Storage storage system";
    homepage = "https://github.com/logos-storage/logos-storage-nim";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
