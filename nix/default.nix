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
  inherit (pkgs) lib writeScriptBin callPackage;

  revision = lib.substring 0 8 (src.rev or "dirty");
  hostPlatform = pkgs.stdenv.hostPlatform;
  isWindows = hostPlatform.isWindows;

  tools = callPackage ./tools.nix {};

  # The dependencies pinned by nimble.lock. Nix fetches them, not Nimble:
  # a Nix build has no network.
  lock = builtins.fromJSON (builtins.readFile ../nimble.lock);
  deps = lib.mapAttrs (name: pkg: rec {
    dirName = "${name}-${pkg.version}";
    src = builtins.fetchGit {
      url = pkg.url;
      rev = pkg.vcsRevision;
      allRefs = true;
      submodules = true;
    };
    srcDir = srcDirOf src;
  }) (removeAttrs lock.packages [ "nim" ]);

  # The `srcDir` of the package's .nimble file, as Nimble puts it in nimble.paths.
  srcDirOf = src:
    let
      nimbleFile = lib.findFirst (f: lib.hasSuffix ".nimble" f)
        (throw "no .nimble file in ${src}")
        (lib.attrNames (builtins.readDir src));
      lines = lib.splitString "\n" (builtins.readFile "${src}/${nimbleFile}");
      found = lib.remove null (map
        (builtins.match "^[[:space:]]*srcDir[[:space:]]*=[[:space:]]*\"([^\"]*)\".*")
        lines);
    in if found == [] then "" else "/${lib.head (lib.head found)}";

  # Determine the compiler.
  # pkgs.stdenv is the mingw compiler for windows.
  stdenv =
    if isWindows then pkgs.stdenv
    else if hostPlatform.isLinux then pkgs.gcc13Stdenv
    else pkgs.clang18Stdenv;

  # -lws2_32: Windows sockets, used by boringssl and libplum.
  # -lbcrypt: Windows CNG, the random source for boringssl, libplum and Nim.
  # -liphlpapi: IP Helper API used by libplum.
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
    nim-2_2
    cmake
    which
    fakeGit
  ] ++ lib.optionals hostPlatform.isLinux [
    lsb-release
  ] ++ lib.optionals hostPlatform.isDarwin [
    darwin.cctools
  ] ++ lib.optionals isWindows [
    gnumake
    # Only nim-boringssl's Windows branch has hand-written asm
    # https://github.com/vacp2p/nim-boringssl/blob/c9505c71ecc67fd232d6ab23e5ae5810957e514f/prelude.nim#L321-L324
    nasm
  ];

  # Disable CPU optimizations that make binary not portable.
  # The nixpkgs Nim links LevelDB's C++ objects through the C compiler, so the
  # C++ runtime is added by hand (Windows adds it in windowsNimFlags).
  NIMFLAGS = lib.concatStringsSep " " (
    [ "-d:disableMarchNative" "-d:git_revision_override=${revision}" ]
    ++ lib.optionals hostPlatform.isLinux [ "--passL:-lstdc++" ]
    ++ lib.optionals hostPlatform.isDarwin [ "--passL:-lc++" ]
    ++ lib.optionals isWindows windowsNimFlags
  );

  # Same layout as `nimble setup -l`: the dependencies in nimbledeps/, listed
  # in nimble.paths, which config.nims includes. Copies, because some
  # packages build C code in their own folder.
  configurePhase = ''
    runHook preConfigure
    # Avoid Nim cache permission errors.
    export XDG_CACHE_HOME=$TMPDIR
    mkdir -p nimbledeps/pkgs2
    echo '--noNimblePath' > nimble.paths
  '' + lib.concatStrings (lib.mapAttrsToList (name: dep: ''
    cp -r ${dep.src} nimbledeps/pkgs2/${dep.dirName}
    echo "--path:\"$PWD/nimbledeps/pkgs2/${dep.dirName}${dep.srcDir}\"" >> nimble.paths
  '') deps) + ''
    chmod -R u+w nimbledeps
    patchShebangs nimbledeps > /dev/null
    runHook postConfigure
  '';

  preBuild = lib.optionalString isWindows ''
    # config.nims joins nimcache with the target's `\`, a relative path on the build host.
    export NIMFLAGS="$NIMFLAGS --nimcache:$PWD/nimcache/release/${lib.concatStringsSep "-" targets}"

    # For --app:staticlib nim runs a hardcoded `ar` (extccomp.nim:86), with no
    # config key to override it, and a cross stdenv only has $AR.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    # Skip the LevelDB setup
    mkdir -p nimbledeps/pkgs2/${deps.leveldbstatic.dirName}/build
    touch nimbledeps/pkgs2/${deps.leveldbstatic.dirName}/build/Makefile

    # The wrapper's system config sets os = windows, and `nim e` runs the script before the cmdline can override it.
    substituteInPlace nimbledeps/pkgs2/${deps.bearssl.dirName}/bearssl/abi/csources.nim \
      --replace-fail '" e --hints:off' '" e --skipCfg --hints:off'
  '';

  # `make all` runs `nimble build`, which needs the network: nim builds the
  # binary directly, with the -d:release that make adds.
  buildPhase = ''
    runHook preBuild
  '' + lib.concatMapStrings (target:
    if target == "all" then ''
      nim storage $NIMFLAGS -d:release build.nims
    '' else ''
      make ${target} V=${toString verbosity}
    '') targets + ''
    runHook postBuild
  '';

  installPhase = ''
    if [ -f build/storage${lib.optionalString isWindows ".exe"} ]; then
      mkdir -p $out/bin
      cp build/storage${lib.optionalString isWindows ".exe"} $out/bin/
    else
      mkdir -p $out/lib $out/include/generated${lib.optionalString isWindows " $out/bin"}
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
      cp library/generated/*.h $out/include/generated/
      cp -r nimbledeps/pkgs2/${deps.ffi.dirName}/ffi/codegen/templates/cpp/vendor/tinycbor $out/include/
    fi
  '';

  meta = with pkgs.lib; {
    description = "Logos Storage storage system";
    homepage = "https://github.com/logos-storage/logos-storage-nim";
    license = licenses.mit;
    platforms = stableSystems ++ platforms.windows;
  };
}
