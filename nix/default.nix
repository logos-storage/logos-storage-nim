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
  hostPlatform = pkgs.stdenv.hostPlatform;
  isWindows = hostPlatform.isWindows;

  tools = callPackage ./tools.nix {};

  # Determine the compiler.
  # pkgs.stdenv is the mingw compiler for windows.
  stdenv =
    if isWindows then pkgs.stdenv
    else if hostPlatform.isLinux then pkgs.gcc13Stdenv
    else pkgs.clang18Stdenv;

  # -lws2_32: Windows sockets, used by boringssl, libplum and miniupnpc.
  # -lbcrypt: Windows CNG, the random source for boringssl, libplum and Nim.
  # -liphlpapi: IP Helper API used by miniupnpc and libplum.
  # -lstdc++: nim links LevelDB's C++ objects through gcc, not g++.
  # -lwinpthread: pthread_time.h inlines clock_gettime into a clock_gettime64 call.
  # --out-implib because nim emits only the .dll, and CMake's find_library
  # ignores a bare .dll.
  windowsNimFlags = [
    "--passL:-lws2_32" "--passL:-lbcrypt" "--passL:-liphlpapi"
    "--passL:-lwinpthread" "--passL:-lstdc++"
    "--passL:-Wl,--out-implib,build/libstorage.dll.a"
  ];

  # nixpkgs' win-dll-link hook only walks $prefix/bin
  dllDir = if isWindows then "bin" else "lib";

  libExt =
    if isWindows then "dll"
    else if hostPlatform.isDarwin then "dylib"
    else "so";

in stdenv.mkDerivation rec {
  pname = "storage";

  version = "${tools.findKeyValue "version = \"([0-9]+\.[0-9]+\.[0-9]+)\"" ../storage.nimble}-${revision}";

  inherit src;

  # Dependencies that should exist in the runtime environment.
  buildInputs = with pkgs; [
    openssl
    gmp
  ] ++ lib.optionals isWindows [
    # nixpkgs' mingw uses mcfgthread, so pthread.h needs adding back.
    windows.pthreads
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs.buildPackages; [
    cmake
    which
    fakeGit
  ] ++ lib.optionals hostPlatform.isLinux [
    lsb-release
  ] ++ lib.optionals hostPlatform.isDarwin [
    darwin.cctools
  ] ++ lib.optionals isWindows [
    # Paired with USE_SYSTEM_NIM=1 below: nimbus-build-system would
    # otherwise build the Nim compiler itself as a Windows binary.
    nim-2_2
    gnumake
    # Only nim-boringssl's Windows branch has hand-written asm
    # https://github.com/vacp2p/nim-boringssl/blob/c9505c71ecc67fd232d6ab23e5ae5810957e514f/prelude.nim#L321-L324
    nasm
  ];

  # Disable CPU optimizations that make binary not portable.
  NIMFLAGS = lib.concatStringsSep " " (
    [ "-d:disableMarchNative" "-d:git_revision_override=${revision}" ]
    ++ lib.optionals isWindows windowsNimFlags
  );

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "QUICK_AND_DIRTY_COMPILER=${if quickAndDirty then "1" else "0"}"
    "QUICK_AND_DIRTY_NIMBLE=${if quickAndDirty then "1" else "0"}"
  ] ++ lib.optionals isWindows [
    "USE_SYSTEM_NIM=1"
  ];

  postPatch = lib.optionalString isWindows ''
    chmod -R +w .

    # Skip the LevelDB setup
    mkdir -p vendor/nim-leveldbstatic/build
    touch vendor/nim-leveldbstatic/build/Makefile
  '';

  configurePhase = ''
    # Avoid Nim cache permission errors.
    export XDG_CACHE_HOME=$TMPDIR
    # Force build of Nimble from dist/nimble source.
    export NIMBLE_COMMIT=""
    patchShebangs . vendor/nimbus-build-system > /dev/null
    # nixpkgs only passes makeFlags to its own make so USE_SYSTEM_NIM=1 is passed here.
    make nimbus-build-system-paths ${lib.optionalString isWindows "USE_SYSTEM_NIM=1"}
  '';

  preBuild = lib.optionalString (!isWindows) ''
    pushd vendor/nimbus-build-system/vendor/Nim
    mkdir dist
    cp -r ${callPackage ./nimble.nix {}}    dist/nimble
    cp -r ${callPackage ./checksums.nix {}} dist/checksums
    cp -r ${callPackage ./csources.nix {}}  csources_v3
    chmod 777 -R dist/nimble csources_v3
    popd
  '' + lib.optionalString isWindows ''
    # For --app:staticlib nim runs a hardcoded `ar` (extccomp.nim:86), with no
    # config key to override it, and a cross stdenv only has $AR.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    # Put the Windows archive where nat_traversal/miniupnpc.nim:29 looks for it,
    # at the miniupnpc root. nimbus-build-system detects Windows with $(OS),
    # which reports the build machine os, not the target os.
    make -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc -f Makefile.mingw \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" libminiupnpc.a

    make -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-Wall -Os -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 -DNATPMP_STATICLIB" \
      libnatpmp.a
  '';

  installPhase = ''
    if [ -f build/storage${lib.optionalString isWindows ".exe"} ]; then
      mkdir -p $out/bin
      cp build/storage${lib.optionalString isWindows ".exe"} $out/bin/
    else
      mkdir -p $out/lib $out/include${lib.optionalString isWindows " $out/bin"}
      if [ -f build/libstorage.${libExt} ]; then
        cp build/libstorage.${libExt} $out/${dllDir}/
      else
        cp build/libstorage.a $out/lib/
      fi
  '' + lib.optionalString isWindows ''
      # Fail loudly rather than shipping a lib/ that a consumer cannot link.
      if [ ! -f build/libstorage.dll.a ]; then
        echo "error: no import library was produced -- consumers cannot link the DLL" >&2
        exit 1
      fi
      cp build/libstorage.dll.a $out/lib/
  '' + ''
      cp library/libstorage.h $out/include/
    fi
  '';

  meta = with pkgs.lib; {
    description = "Logos Storage storage system";
    homepage = "https://github.com/logos-storage/logos-storage-nim";
    license = licenses.mit;
    platforms = stableSystems ++ platforms.windows;
  };
}
