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

  # `pkgs.stdenv.isLinux` answers for the BUILD platform, which is Linux even
  # when cross-compiling to Windows -- so every platform test here goes through
  # hostPlatform, and every if/elif chain tests Windows FIRST. Under mingw
  # cross isDarwin and isAarch64 are both false and x86_64 still matches, so a
  # Windows target otherwise takes the Linux branch in silence.
  hostPlatform = pkgs.stdenv.hostPlatform;
  isWindows = hostPlatform.isWindows;

  tools = callPackage ./tools.nix {};

  # Pin GCC/Clang versions -- but only where we own the toolchain. On a cross
  # build pkgs.stdenv IS the mingw stdenv; replacing it with gcc13Stdenv would
  # silently retarget the whole build at the build platform.
  stdenv =
    if isWindows then pkgs.stdenv
    else if hostPlatform.isLinux then pkgs.gcc13Stdenv
    else pkgs.clang18Stdenv;

  # Win32 imports that the Nim runtime, chronos and the vendored C libraries
  # need, plus two that are specific to this closure:
  #   -lstdc++      nim-leveldbstatic compiles LevelDB's C++ sources through
  #                 nim's {.compile.} pragma, but nim drives the LINK through
  #                 gcc, not g++, so nothing else pulls in the C++ runtime or
  #                 __gxx_personality_seh0.
  #   -lwinpthread  winpthreads' pthread_time.h inlines clock_gettime as a call
  #                 to clock_gettime64, which lives in libwinpthread; having the
  #                 headers on the include path is not enough.
  # Passed as separate --passL: flags rather than one quoted string so nothing
  # has to survive make's word splitting on the way to the nim command line.
  windowsLinkFlags = [
    "-lws2_32" "-lbcrypt" "-liphlpapi" "-luserenv" "-lntdll" "-ldbghelp"
    "-lwinpthread" "-lstdc++"
  ];

  # A Windows shared library is TWO artifacts: consumers LINK against the import
  # library and SHIP the .dll. nim emits only the .dll, and CMake's find_library
  # will not return a bare .dll -- so a consumer silently falls through to
  # libstorage.a and tries to link the whole Nim runtime statically, which then
  # fails on every leveldb/setjmp symbol. Emitting the import lib is what makes
  # `-lstorage` mean the DLL.
  windowsNimFlags =
    map (f: "--passL:${f}") windowsLinkFlags
    ++ [ "--passL:-Wl,--out-implib,build/libstorage.dll.a" ];

  # Windows splits a shared library in two: the import half is a link-time
  # artifact and belongs in lib/, but the .dll is a RUNTIME artifact and belongs
  # in bin/ -- CMake's own RUNTIME destination, and what openssl and every
  # autotools port in this closure already do. Following it is not cosmetic:
  # nixpkgs' win-dll-link hook stages a PE's dependency DLLs automatically, but
  # its fixup only ever walks $prefix/bin, so a .dll in lib/ ships with none of
  # libgcc_s_seh-1 / libstdc++-6 / libwinpthread-1 beside it and fails to load
  # on Windows with no diagnostic.
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
    # nixpkgs builds mingw-w64 against mcfgthread, so pthread.h and
    # libpthread.a exist nowhere in the default closure; the vendored C carries
    # POSIX-threads assumptions regardless.
    windows.pthreads
  ];

  # Dependencies that should only exist in the build environment. Every one of
  # these RUNS on the builder, so under cross they must come from
  # buildPackages: in a cross package set `pkgs.git` is a git compiled FOR
  # Windows, and `pkgs.nim-2_2` is the mingw-HOSTED nim wrapper, which does not
  # even evaluate (it wants a Windows bash).
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
    # `buildPackages.nim-2_2` is the x86_64-w64-mingw32-nim wrapper: it runs on
    # the builder, has os/cpu baked into its nim.cfg, and takes its backend from
    # $CC at invocation time -- which the cross stdenv has already set to
    # x86_64-w64-mingw32-gcc. Used together with USE_SYSTEM_NIM=1 below, because
    # nimbus-build-system's own bootstrap would compile the Nim COMPILER with
    # $CC and produce a PE that cannot run on the builder.
    nim-2_2
    gnumake
    # Only the Windows branch of nim-boringssl has hand-written asm, and it
    # shells out to `nasm -f win64` from a compile-time macro.
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
    # nim-libbacktrace vendors libbacktrace and builds it with a POSIX-shaped
    # configure run; config.nims only reaches for it when this is on.
    "USE_LIBBACKTRACE=0"
  ];

  postPatch = lib.optionalString isWindows ''
    chmod -R +w .

    # ---- The compile-time DirSep trap, three vendored instances -----------
    #
    # Nim's os.parentDir normalises to the TARGET's DirSep, which is '\' the
    # moment os=Windows -- and it rewrites the WHOLE path, not just the
    # component being split. So a compile-time `currentSourcePath.parentDir`
    # yields \build\storage-nim\... , which the Linux builder then treats as a
    # single relative filename and cannot open. The failure surfaces as
    # "cannot open file" naming a path that visibly exists.
    #
    # Note what does NOT need patching: the `currentSourcePath.rsplit({DirSep,
    # AltSep}, 1)[0] & "/..."` idiom returns an unmodified substring and is
    # already correct -- that is what nim-bearssl, nim-blscurve, nim-secp256k1,
    # nim-zlib, nim-lsquic and boringssl's own srcPath use. nim-nat-traversal
    # has learned the lesson explicitly and appends .replace('\\', '/').
    # Only plain `parentDir` is unsafe, and only three files on this build's
    # code path use it.
    #
    # All of this is invisible on MSYS2, where the filesystem accepts either
    # separator -- which is why upstream CI has never seen any of it.

    # (a) nim-leveldbstatic/leveldbstatic/raw.nim -- `root` feeds every
    #     {.compile.} and {.passc: "-I".} line in the file, so it mangles the
    #     entire LevelDB build, not just one lookup. Nim 2.2's normalizePath
    #     takes no dirSep argument, so pin the value: the build always runs
    #     from the source root and a string literal is never re-normalised.
    R=vendor/nim-leveldbstatic/leveldbstatic/raw.nim
    sed -i "s|root = currentSourcePath.parentDir.parentDir|root = \"$(pwd)/vendor/nim-leveldbstatic\"|" $R
    sed -i 's|root/"vendor"/"util"/"env_windows.cc"|root \& "/vendor/util/env_windows.cc"|' $R
    sed -i 's|root/"vendor"/"util"/"env_posix.cc"|root \& "/vendor/util/env_posix.cc"|'     $R
    sed -i 's|\$(root/"vendor")|root \& "/vendor"|'                                         $R
    sed -i 's|\$(root/"build")|root \& "/build"|'                                           $R
    sed -i 's|buildDir/"Makefile"|buildDir \& "/Makefile"|'                                 $R

    # (b) nim-leveldbstatic/leveldbstatic.nim -- reads its own .nimble at
    #     compile time to report a version. fileExists() on the mangled parent
    #     path merely returns false; it is the staticRead of the mangled local
    #     path that aborts the compile.
    L=vendor/nim-leveldbstatic/leveldbstatic.nim
    sed -i "s|const parentConfig = sourcePath.parentDir.parentDir / configFile|const parentConfig = \"$(pwd)/vendor/\" \& configFile|" $L
    sed -i "s|const localConfig = sourcePath.parentDir / configFile|const localConfig = \"$(pwd)/vendor/nim-leveldbstatic/\" \& configFile|" $L

    # (c) nim-boringssl/boringssl.nim -- baseDir feeds linkAsmFiles, which
    #     assembles 25 .asm files with nasm on the Windows branch. Rewritten to
    #     the rsplit idiom the same file already uses for srcPath (line 21), so
    #     no new import is needed and the expression stays platform-neutral.
    sed -i "s|const baseDir = currentSourcePath.parentDir|const baseDir = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]|" \
      vendor/nim-boringssl/boringssl.nim
    #     Fixing baseDir is necessary but NOT sufficient: nim's `/` operator
    #     re-mangles the whole path at each use, so the two staticRead calls
    #     feeding nasm's prefix includes still resolve to
    #     \boringssl\gen\..._win_asm.inc. That file already wraps its OTHER
    #     joins in normalizePath(dirSep = '/'); rewrite only the ones that are
    #     not, to plain concatenation.
    sed -i "/normalizePath/!s|baseDir /|baseDir \& \"/\" \&|" \
      vendor/nim-boringssl/boringssl.nim

    # Fail loudly if upstream moved any of these out from under the patch --
    # a silently-unapplied sed would resurface hours later as an unrelated
    # "cannot open file" deep in the compile.
    for f in "$R:parentDir" "$L:sourcePath.parentDir" \
             "vendor/nim-boringssl/boringssl.nim:currentSourcePath.parentDir" \
             "vendor/nim-boringssl/boringssl.nim:[^(]baseDir /"; do
      if grep -q "''${f#*:}" "''${f%%:*}"; then
        echo "error: DirSep patch did not apply to ''${f%%:*}" >&2; exit 1
      fi
    done

    # (d) nim-libplum/libplum/plum.nim -- a BARE `raise` re-raising inside
    #     `except CancelledError`, in a proc declared
    #     `{.async: (raises: [CancelledError]).}`. Nim infers a bare re-raise
    #     conservatively, and under --os:windows that inference widens to
    #     Exception, so the compile fails with
    #         Error: Exception can raise an unlisted exception: Exception
    #     Naming the caught exception and re-raising it by name pins the type
    #     to the one already declared. Behaviour is identical -- `raise exc` in
    #     an except branch re-raises the same object -- and the edit is
    #     platform-neutral, so it is a candidate to send upstream rather than
    #     something Windows needs specially.
    #
    #     Not caused by the -d:debug that USE_LIBBACKTRACE=0 implies: adding
    #     -d:release changes nothing here (measured).
    P=vendor/nim-libplum/libplum/plum.nim
    sed -i 's|^  except CancelledError:$|  except CancelledError as exc:|' $P
    sed -i 's|^    raise$|    raise exc|' $P
    if grep -q '^    raise$' $P; then
      echo "error: libplum bare-raise patch did not apply" >&2; exit 1
    fi

    # 2. buildLevelDb() shells out to cmake AT COMPILE TIME, and its Windows
    #    branch asks for -G"MSYS Makefiles", a generator a Nix builder does not
    #    have. Correcting the generator is not enough either: leveldb's own
    #    CMakeLists then runs check_cxx_source_compiles/try_run probes, which
    #    under cross would have to EXECUTE a PE on the Linux builder.
    #
    #    That whole step is vestigial for this build. The only artifact it
    #    produces is port/port_config.h in the BUILD directory, and none of the
    #    {.passc: "-I"...} lines below put that directory on the include path --
    #    so port_stdcxx.h's __has_include("port/port_config.h") never finds it
    #    and falls back to its defaults, on Linux and macOS just as much as
    #    here. Seed the sentinel the function itself checks for, so it returns
    #    before running anything.
    #
    #    Windows-only on purpose: the native builds keep running it, so their
    #    output stays bit-identical to what upstream produces today.
    mkdir -p vendor/nim-leveldbstatic/build
    echo '# cross build: leveldb cmake step skipped -- see nix/default.nix' \
      > vendor/nim-leveldbstatic/build/Makefile
  '';

  configurePhase = ''
    # Avoid Nim cache permission errors.
    export XDG_CACHE_HOME=$TMPDIR
    # Force build of Nimble from dist/nimble source.
    export NIMBLE_COMMIT=""
    patchShebangs . vendor/nimbus-build-system > /dev/null
    # Only the variables this target needs -- NOT $makeFlags, which carries the
    # build TARGETS (`libstorage`). Passing those here would run the entire
    # build inside configurePhase, i.e. before preBuild has staged the nat
    # libraries, and the link would then fail on a missing libminiupnpc.a with
    # nothing in the log to suggest an ordering problem.
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
    # For --app:staticlib nim shells out to a BARE `ar`, and a cross stdenv has
    # only x86_64-w64-mingw32-ar on PATH: the nixpkgs nim wrapper rewrites
    # gcc.exe/gcc.linkerexe from $CC/$CXX but never the archiver, and nim
    # exposes no config key for it. Every archive produced in this build is for
    # the target, so shadowing ar with $AR is correct and not merely expedient.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    # nimbus-build-system's nat-libs targets branch on $(OS) -- the variable
    # Windows' cmd.exe sets, which is empty on a Linux builder -- so a cross
    # build silently takes their POSIX branch and produces archives that are
    # wrong in three ways. Build them correctly here FIRST; the `make deps`
    # inside the libstorage target then finds every object already newer than
    # its sources and does nothing.
    #
    #   -fPIC is dropped: it is meaningless on PE (everything is relocatable)
    #   and gcc warns on it.
    #
    #   -D*_STATICLIB is added: miniupnpc_declspec.h and natpmp_declspec.h both
    #   resolve their LIBSPEC to __declspec(dllimport) on _WIN32 unless the
    #   macro is defined. nim-nat-traversal defines them for the nim-GENERATED
    #   C but not for the vendored library build, so each archive ends up
    #   calling its own symbols through import stubs:
    #   "undefined reference to `__imp_upnpDiscoverDevices'".
    #
    # Both vendored makefiles derive their target from `$(CC) -dumpmachine`
    # rather than uname, so handing them the cross compiler is enough to select
    # the MinGW branch. Note libnatpmp's MinGW branch then assigns
    # CC = i686-w64-mingw32-gcc -- a command-line CC= overrides that, a
    # CFLAGS-only invocation would not.
    make -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-Os -DMINIUPNP_STATICLIB" build/libminiupnpc.a

    make -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-Wall -Os -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 -DNATPMP_STATICLIB" \
      libnatpmp.a

    # libplum (new in v0.4.4) is configured by the Makefile with a bare
    # `cmake -B build`, which under this stdenv picks the cross compiler up from
    # $CC but leaves CMAKE_SYSTEM_NAME as the BUILD system. libplum's CMakeLists
    # gates both `add_definitions(-DWIN32_LEAN_AND_MEAN)` and its
    # `target_link_libraries(... ws2_32 iphlpapi)` on CMake's WIN32, so neither
    # applies and its example executable fails to link with
    #     libplum.a(upnp.c.o): undefined reference to `__imp_closesocket'
    # (the archive itself is fine -- a static lib records no imports -- which is
    # why only the example target dies).
    #
    # Configure it here with the system name it should have had, and with the
    # example off: we consume libplum.a only, and building a sample executable
    # for a platform the builder cannot run is pure cost on every platform.
    # CMake persists both in build/CMakeCache.txt, so when `make deps` re-runs
    # its own `cmake -B build` the cached values survive and the subsequent
    # `make -C build` finds everything up to date.
    cmake -B vendor/nim-libplum/vendor/libplum/build \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_SYSTEM_NAME=Windows -DPLUM_NO_EXAMPLE=ON \
      vendor/nim-libplum/vendor/libplum

    # nim-nat-traversal expects libminiupnpc.a at the miniupnpc ROOT on Windows
    # and under build/ everywhere else -- see the "the Makefiles of the miniupnp
    # library have an inconsistency" comment in nat_traversal/miniupnpc.nim.
    # That root layout is what Makefile.mingw produces, but Makefile.mingw
    # generates miniupnpcstrings.h by building and RUNNING a .exe, which a Linux
    # builder cannot do. So: build with the portable Makefile, then stage the
    # archive where the Windows branch of the nim wrapper looks for it.
    cp vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc/build/libminiupnpc.a \
       vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc/libminiupnpc.a
  '';

  installPhase = ''
    if [ -f build/storage${lib.optionalString isWindows ".exe"} ]; then
      mkdir -p $out/bin
      cp build/storage${lib.optionalString isWindows ".exe"} $out/bin/
    else
      mkdir -p $out/lib $out/include${lib.optionalString isWindows " $out/bin"}
      cp build/libstorage.${libExt} $out/${dllDir}/ 2>/dev/null || true
      cp build/libstorage.a         $out/lib/       2>/dev/null || true
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
    # stableSystems is the NATIVE set; the Windows target is a cross build and
    # its pseudo-system key is not a platform nixpkgs knows about, so it is
    # spelled out here. Omitting it is an evaluation-time hard failure, not a
    # build one -- meta.platforms is checked long before anything compiles.
    platforms = stableSystems ++ platforms.windows;
  };
}
