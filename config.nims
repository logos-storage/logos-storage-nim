include "build.nims"

import std/os
const currentDir = currentSourcePath()[0 .. ^(len("config.nims") + 1)]

when getEnv("NIMBUS_BUILD_SYSTEM") == "yes" and
    # BEWARE
    # In Nim 1.6, config files are evaluated with a working directory
    # matching where the Nim command was invocated. This means that we
    # must do all file existence checks with full absolute paths:
    system.fileExists(currentDir & "nimbus-build-system.paths"):
  include "nimbus-build-system.paths"

when defined(release):
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/release/$projectName")
  )
else:
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/debug/$projectName")
  )

when defined(limitStackUsage):
  # This limits stack usage of each individual function to 1MB - the option is
  # available on some GCC versions but not all - run with `-d:limitStackUsage`
  # and look for .su files in "./build/", "./nimcache/" or $TMPDIR that list the
  # stack size of each function.
  switch("passC", "-fstack-usage -Werror=stack-usage=1048576")
  switch("passL", "-fstack-usage -Werror=stack-usage=1048576")

when defined(windows):
  # https://github.com/nim-lang/Nim/pull/19891
  switch("define", "nimRawSetjmp")

  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size
  switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:
    off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

  # The dynamic Chronicles output currently prevents us from using colors on Windows
  # because these require direct manipulations of the stdout File object.
  switch("define", "chronicles_colors=NoColors")

# This helps especially for 32-bit x86, which sans SSE2 and newer instructions
# requires quite roundabout code generation for cryptography, and other 64-bit
# and larger arithmetic use cases, along with register starvation issues. When
# engineering a more portable binary release, this should be tweaked but still
# use at least -msse2 or -msse3.

when defined(disableMarchNative):
  when defined(i386) or defined(amd64):
    switch("passC", "-mssse3")
elif defined(macosx) and defined(arm64):
  # Apple's Clang can't handle "-march=native" on M1: https://github.com/status-im/nimbus-eth2/issues/2758
  switch("passC", "-mcpu=apple-a14")
  # TODO: newer Clang >=15.0 can: https://github.com/llvm/llvm-project/commit/fcca10c69aaab539962d10fcc59a5f074b73b0de
else:
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-march=x86-64")
  else: switch("passC", "-march=native")
    

--tlsEmulation:
  off
--threads:
  on
--opt:
  speed
--excessiveStackTrace:
  on
# enable metric collection
--define:
  metrics
# for heap-usage-by-instance-type metrics and object base-type strings
--define:
  nimTypeNames
--styleCheck:
  usages
--styleCheck:
  error
--maxLoopIterationsVM:
  1000000000
--fieldChecks:
  on
--warningAsError:
  "ProveField:on"
--define:
  "libp2p_multicodec_exts:../../../codex/multicodec_exts.nim"
--define:
  "libp2p_multihash_exts:../../../codex/multihash_exts.nim"
--define:
  "libp2p_contentids_exts:../../../codex/contentids_exts.nim"

when (NimMajor, NimMinor) >= (1, 4):
  --warning:
    "ObservableStores:off"
  --warning:
    "LockLevel:off"
  --hint:
    "XCannotRaiseY:off"
when (NimMajor, NimMinor) >= (1, 6):
  --warning:
    "DotLikeOps:off"
when (NimMajor, NimMinor, NimPatch) >= (1, 6, 11):
  --warning:
    "BareExcept:off"
when (NimMajor, NimMinor) >= (2, 0):
  --mm:
    refc

switch("define", "withoutPCRE")

# the default open files limit is too low on macOS (512), breaking the
# "--debugger:native" build. It can be increased with `ulimit -n 1024`.
if not defined(macosx):
  # add debugging symbols and original files and line numbers
  --debugger:
    native
  if not (defined(windows) and defined(i386)) and not defined(disable_libbacktrace):
    # light-weight stack traces using libbacktrace and libunwind
    --define:
      nimStackTraceOverride
    switch("import", "libbacktrace")

# `switch("warning[CaseTransition]", "off")` fails with "Error: invalid command line option: '--warning[CaseTransition]'"
switch("warning", "CaseTransition:off")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

switch("define", "libp2p_pki_schemes=secp256k1")
#TODO this infects everything in this folder, ideally it would only
# apply to codex.nim, but since codex.nims is used for other purpose
# we can't use it. And codex.cfg doesn't work
switch("define", "chronicles_sinks=textlines[dynamic],json[dynamic],textlines[dynamic]")

# Workaround for assembler incompatibility between constantine and secp256k1
switch("define", "use_asm_syntax_intel=false")
switch("define", "ctt_asm=false")

# Allow the use of old-style case objects for nim config compatibility
switch("define", "nimOldCaseObjects")

# Enable compat mode for Chronos V4
switch("define", "chronosHandleException")

switch("define", "chronosProfiling")

# begin Nimble config (version 1)
when system.fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config
