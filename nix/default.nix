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
}:

let
  inherit (pkgs) lib callPackage;

  source = src;
  revision = lib.substring 0 8 (src.rev or "dirty");
  hostPlatform = pkgs.stdenv.hostPlatform;
  isWindows = hostPlatform.isWindows;
  compiler = if hostPlatform.isDarwin then "clang" else "gcc";

  tools = callPackage ./tools.nix {};
  toolchain = import ./toolchain.nix { inherit pkgs; };
  dependencies = import ./dependencies.nix { inherit pkgs; };

  # Determine the compiler.
  # pkgs.stdenv is the mingw compiler for windows.
  stdenv =
    if isWindows then pkgs.stdenv
    else if hostPlatform.isLinux then pkgs.gcc13Stdenv
    else pkgs.clang18Stdenv;

  # -lws2_32: Windows sockets, used by boringssl, libplum and miniupnpc.
  # -lbcrypt: Windows CNG, the random source for boringssl, libplum and Nim.
  # -liphlpapi: IP Helper API used by miniupnpc and libplum.
  # -lwinpthread: pthread_time.h inlines clock_gettime into a clock_gettime64 call.
  # --out-implib because nim emits only the .dll, and CMake's find_library
  # ignores a bare .dll.
  windowsNimFlags = [
    "--passL:-lws2_32" "--passL:-lbcrypt" "--passL:-liphlpapi"
    "--passL:-lwinpthread"
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

  src = lib.cleanSourceWith {
    src = source;
    filter = path: type:
      !(builtins.elem (baseNameOf path) [ "nimbledeps" "nimcache" "build" ".toolchain" "nimble.paths" "nimble.lock" ]);
  };

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
    # Version banners are evaluated at compile time in the network-free sandbox.
    fakeGit = pkgs.buildPackages.writeShellScriptBin "git" "echo ${version}";
  in with pkgs.buildPackages; [
    toolchain.nim toolchain.nimble cmake which fakeGit
  ] ++ lib.optionals hostPlatform.isLinux [ lsb-release ]
    ++ lib.optionals hostPlatform.isDarwin [ darwin.cctools ]
    ++ lib.optionals isWindows [ nasm ];

  # Disable CPU optimizations that make binary not portable.
  NIMFLAGS = lib.concatStringsSep " " (
    [ "-d:disableMarchNative" "-d:git_revision_override=${revision}" ]
    ++ lib.optionals isWindows ([ "--os:windows" "--cpu:amd64" ] ++ windowsNimFlags)
  );

  makeFlags = targets ++ [ "V=${toString verbosity}" ];

  configurePhase = ''
    runHook preConfigure
    export XDG_CACHE_HOME=$TMPDIR/cache
    export NIMBLE_DIR=$PWD/nimbledeps
    export NIMBLE_FLAGS="--offline --useSystemNim ${if verbosity > 1 then "--debug" else if verbosity > 0 then "--verbose" else ""}"
    ${dependencies.prepare}
    cp ${dependencies.lock} nimble.lock
    patchShebangs . > /dev/null

    # LevelDB compiles its C++ sources through Nim. Its CMake invocation only
    # configures a build tree, which is unused and selects a native generator
    # even when cross compiling. Skip that configuration step on Windows.
    ${lib.optionalString isWindows ''
      for leveldb in "$NIMBLE_DIR"/pkgs2/leveldbstatic-*; do
        mkdir -p "$leveldb/build"
        touch "$leveldb/build/Makefile"
      done
    ''}
    # LevelDB and libbacktrace contain C++ objects, so link with the C++ driver.
    export NIMFLAGS="$NIMFLAGS --parallelBuild:$NIX_BUILD_CORES --cc:${compiler} --${compiler}.exe:$CC --${compiler}.linkerexe:$CXX --${compiler}.cpp.exe:$CXX --${compiler}.cpp.linkerexe:$CXX"
    # Nim's static archive action invokes ar directly, also for cross builds.
    mkdir -p $TMPDIR/arshim
    ln -s "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH
    runHook postConfigure
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
