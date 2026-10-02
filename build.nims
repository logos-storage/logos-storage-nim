mode = ScriptMode.Verbose

import std/os except commandLineParams
import std/strutils

### Helper functions
proc truthy(val: string): bool =
  const truthySwitches = @["yes", "1", "on", "true"]
  return val in truthySwitches

proc buildBinary(
    srcName: string,
    outName = os.lastPathPart(srcName),
    srcDir = "./",
    params = "",
    lang = "c",
) =
  if not dirExists "build":
    mkDir "build"

  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  when defined(commandLineParams):
    for param in commandLineParams():
      extra_params &= " " & param
  else:
    for i in 2 ..< paramCount():
      extra_params &= " " & paramStr(i)

  let
    # Place build output in 'build' folder, even if name includes a longer path.
    cmd =
      "nim " & lang & " --out:build/" & outName & " " & extra_params & " " & srcDir &
      srcName & ".nim"

  exec(cmd)

proc buildLibrary(name: string, srcDir = "./", params = "", `type` = "dynamic") =
  if not dirExists "build":
    mkDir "build"

  if `type` == "dynamic":
    let lib_name = (
      when defined(windows): name & ".dll"
      elif defined(macosx): name & ".dylib"
      else: name & ".so"
    )
    exec "nim c" & " --out:build/" & lib_name &
      " --threads:on --app:lib --opt:size --noMain --mm:refc --header --d:metrics " &
      "--nimMainPrefix:libstorage -d:noSignalHandler " &
      "-d:chronicles_runtime_filtering " & "-d:chronicles_log_level=TRACE " & params &
      " " & srcDir & name & ".nim"
  else:
    exec "nim c" & " --out:build/" & name &
      ".a --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --d:metrics " &
      "--nimMainPrefix:libstorage -d:noSignalHandler " &
      "-d:chronicles_runtime_filtering " & "-d:chronicles_log_level=TRACE " & params &
      " " & srcDir & name & ".nim"

proc test(name: string, outName = name, srcDir = "tests/", params = "", lang = "c") =
  buildBinary name, outName, srcDir, params
  exec "build/" & outName

task storage, "build logos storage binary":
  buildBinary "storage",
    outname = "storage",
    params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE"

task mixTools, "build mix tools (mix_pool, mix_relay_dht)":
  let (desc, ec) = gorgeEx("git describe --tags --always --dirty")
  let mixVersion =
    if ec == 0 and desc.strip().len > 0:
      desc.strip()
    else:
      "unknown"
  let mixParams =
    "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE " & "-d:mixVersion:" &
    mixVersion
  buildBinary "mix_pool",
    outName = "mix_pool", srcDir = "tools/mix/", params = mixParams
  buildBinary "mix_relay_dht",
    outName = "mix_relay_dht", srcDir = "tools/mix/", params = mixParams

task checkSpr, "build check_spr used for checking bootstrap node health":
  buildBinary "check_spr",
    srcDir = "tools/",
    params = "-d:release -d:chronicles_runtime_filtering -d:chronicles_log_level=WARN"

task bootstrapHealthCheck, "ping preset bootstrap nodes; non-zero exit if any are unreachable":
  checkSprTask()

  # get CI param from make if present
  var args = ""
  for i in 2 ..< paramCount():
    if "ci" in paramStr(i) and truthy paramStr(i).split('=')[1]:
      # Writes the JSON summary to a file before exiting, so the scheduled workflow
      args = "--network logos.dev --network logos.test --format json --out build/bootstrap-health-report.json"
      break
  
  # can read it. check_spr exits non-zero when a node is unreachable, failing
  # the workflow run.
  exec "build/check_spr " & args

task testStorage, "Build & run Logos Storage tests":
  test "testStorage", outName = "testStorage"

task testIntegration, "Run integration tests":
  buildBinary "storage",
    outName = "storage",
    params = "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE"
  test "testIntegration"
  # use params to enable logging from the integration test executable
  # test "testIntegration", params = "-d:chronicles_sinks=textlines[notimestamps,stdout],textlines[dynamic] " &
  #   "-d:chronicles_enabled_topics:integration:TRACE"

task testNatIntegration,
  "Run NAT real-topology scenarios (needs the storage-nat image + podman-compose)":
  test "testNatIntegration"

task testLibstorage, "Run libstorage Nim tests":
  test "testLibstorage", outName = "testLibstorage"

task build, "build Logos Storage binary":
  storageTask()

task test, "Run tests":
  testStorageTask()

task testAll, "Run all tests (except for Taiko L2 tests)":
  testStorageTask()
  testIntegrationTask()

import strutils
import os

task coverage, "generates code coverage report":
  var (output, exitCode) = gorgeEx("which lcov")
  if exitCode != 0:
    echo "  ************************** ⛔️ ERROR ⛔️ **************************"
    echo "  **   ERROR: lcov not found, it must be installed to run code   **"
    echo "  **   coverage locally                                          **"
    echo "  *****************************************************************"
    quit 1

  (output, exitCode) = gorgeEx("gcov --version")
  if output.contains("Apple LLVM"):
    echo "  ************************* ⚠️ WARNING ⚠️  *************************"
    echo "  **   WARNING: Using Apple's llvm-cov in place of gcov, which   **"
    echo "  **   emulates an old version of gcov (4.2.0) and therefore     **"
    echo "  **   coverage results will differ than those on CI (which      **"
    echo "  **   uses a much newer version of gcov).                       **"
    echo "  *****************************************************************"

  var nimSrcs = " "
  for f in walkDirRec("storage", {pcFile}):
    if f.endswith(".nim"):
      nimSrcs.add " " & f.absolutePath.quoteShell()

  echo "======== Running Tests ======== "
  test "coverage",
    srcDir = "tests/", params = " --nimcache:nimcache/coverage -d:release"
  exec("rm nimcache/coverage/*.c")
  rmDir("coverage")
  mkDir("coverage")
  echo " ======== Running LCOV ======== "
  exec(
    "lcov --capture --keep-going --directory nimcache/coverage --output-file coverage/coverage.info"
  )
  exec(
    "lcov --extract coverage/coverage.info --keep-going --output-file coverage/coverage.f.info " &
      nimSrcs
  )
  echo " ======== Generating HTML coverage report ======== "
  exec(
    "genhtml coverage/coverage.f.info --keep-going --output-directory coverage/report "
  )
  echo " ======== Coverage report Done ======== "

task showCoverage, "open coverage html":
  echo " ======== Opening HTML coverage report in browser... ======== "
  if findExe("open") != "":
    exec("open coverage/report/index.html")

task libstorageDynamic, "Generate bindings":
  var params = ""
  when compiles(commandLineParams):
    for param in commandLineParams():
      if param.len > 0 and param.startsWith("-"):
        params.add " " & param

  let name = "libstorage"
  buildLibrary name, "library/", params, "dynamic"

task libstorageStatic, "Generate bindings":
  var params = ""
  when compiles(commandLineParams):
    for param in commandLineParams():
      if param.len > 0 and param.startsWith("-"):
        params.add " " & param

  let name = "libstorage"
  buildLibrary name, "library/", params, "static"

################
## Android    ##
################
# Cross-compiles libstorage.so for a single Android ABI. CPU and ABIDIR are
# read from the environment (set by the Makefile's per-arch targets below),
# mirroring the CPU/ABIDIR env-var handoff logos-delivery uses for its own
# Android build (see liblogosdelivery-android-* in that repo's Makefile).
proc buildLibraryAndroid(name: string, srcDir = "./", params = "") =
  let cpu = getEnv("CPU")
  let abiDir = getEnv("ABIDIR")
  let ccExe = getEnv("CC")
  doAssert cpu.len > 0, "CPU env var must be set (use the Makefile android targets)"
  doAssert abiDir.len > 0, "ABIDIR env var must be set (use the Makefile android targets)"
  doAssert ccExe.len > 0, "CC env var must be set (use the Makefile android targets)"

  let outDir = "build/android/" & abiDir
  if not dirExists outDir:
    mkDir outDir

  # -d:disableMarchNative: config.nims otherwise unconditionally passes
  # -march=native (host-arch tuning), which is meaningless — and breaks the
  # cross-compiler's include-path resolution — when targeting Android ARM
  # from an x86_64 host.
  #
  # --passL:-lc++_shared: this library vendors LevelDB (C++), so the linked
  # .so references C++ std symbols. Without this the .so is missing a
  # `NEEDED libc++_shared.so` entry and fails to dlopen on-device with
  # "cannot locate symbol", even though the build itself succeeds. Same
  # class of fix vpavlin/logos-delivery's Android fork needed for
  # liblogosdelivery.so (see its WRITEUP.md) — do not try to patch this in
  # after the fact with patchelf, which corrupts DT_GNU_HASH; it must be a
  # link-time flag.
  #
  # --passL:-llog: Nim's own runtime (system.nim's echoBinSafe on Android)
  # calls __android_log_print, which lives in Android's liblog, not libc.
  # Without this the link fails with "undefined symbol: __android_log_print"
  # — confirmed empirically with a minimal `nim c --os:android` hello-world,
  # not just inferred from delivery's recipe (which also passes this flag).
  #
  # --clang.exe / --clang.linkerexe (not --cc:env): Nim's `cc` setting
  # defaults to `gcc` (see nim.cfg). `--cc:env` makes Nim read the compiler
  # path from the `CC` env var at compile-config-resolution time — but that
  # resolution happens inside the `exec()`'d `nim c` subprocess, one level
  # below this task, and empirically loses the Makefile's `CC=<NDK clang>`
  # somewhere in that nested-process chain (reproducible: a top-level `nim
  # <task> foo.nims` task body sees `getEnv("CC")` correctly, but the
  # grandchild `nim c --cc:env` it `exec()`s reports "Compiler 'env' doesn't
  # support the requested target", i.e. an empty CC at that point — root
  # cause not fully isolated). Baking the resolved path directly into the
  # generated command string via `--cc:clang --clang.exe:<path>
  # --clang.linkerexe:<path>` sidesteps env-var propagation entirely: the
  # path is a literal argument by the time the subprocess sees it, not
  # something it has to re-resolve from its own environment.
  exec "nim c" & " --out:" & outDir & "/" & name & ".so" &
    " --threads:on --app:lib --opt:size --noMain --mm:refc --header --d:metrics " &
    "--nimMainPrefix:libstorage -d:noSignalHandler -d:chronicles_runtime_filtering " &
    "-d:chronicles_log_level=TRACE -d:disableMarchNative --passL:-lc++_shared " &
    "--passL:-llog --cc:clang --clang.exe:" & ccExe & " --clang.linkerexe:" & ccExe &
    " --cpu:" & cpu & " --os:android -d:androidNDK " &
    params & " " & srcDir & name & ".nim"

task libstorageAndroid, "Build libstorage.so for Android (single ABI; set CPU/ABIDIR env vars)":
  var params = ""
  when compiles(commandLineParams):
    for param in commandLineParams():
      if param.len > 0 and param.startsWith("-"):
        params.add " " & param

  buildLibraryAndroid "libstorage", "library/", params
