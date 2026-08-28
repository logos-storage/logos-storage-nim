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

const cBindingsDir = "library/generated"

## `-d:ffiSrcPath` is required: the derived path needs `getcwd` at compile time.
const cBindingsFlags =
  " -d:ffiGenBindings -d:targetLang=c -d:ffiOutputDir=" & cBindingsDir &
  " -d:ffiSrcPath=../libstorage.nim "

proc buildLibrary(name: string, srcDir = "./", params = "", `type` = "dynamic") =
  if not dirExists "build":
    mkDir "build"
  mkDir cBindingsDir

  let common =
    " --threads:on --opt:size --noMain --mm:refc --header --d:metrics " &
    "--nimMainPrefix:libstorage -d:noSignalHandler " &
    "-d:chronicles_runtime_filtering -d:chronicles_log_level=TRACE " & cBindingsFlags &
    params & " " & srcDir & name & ".nim"

  if `type` == "dynamic":
    let lib_name = (
      when defined(windows): name & ".dll"
      elif defined(macosx): name & ".dylib"
      else: name & ".so"
    )
    exec "nim c --out:build/" & lib_name & " --app:lib" & common
  else:
    exec "nim c --out:build/" & name & ".a --app:staticlib" & common

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
