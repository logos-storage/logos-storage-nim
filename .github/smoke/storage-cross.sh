#!/usr/bin/env bash
# Windows smoke test for the nix cross outputs.
#
# Runs from the staged tree ROOT, which holds one directory per target, so every
# path below starts with a target name. PEs go through the `run` wrapper on
# PATH: wine on the Linux leg, a direct exec on the Windows one, so this single
# file serves both.
#
# STORAGE is a variable rather than a literal so the same file runs against a
# native build during development:
#     STORAGE=result/bin/storage bash .github/smoke/storage-cross.sh
# from a directory that also holds libstorage/. That is how the assertions
# below were shown to bite.
#
# `set -e` is redundant -- the smoke action already runs this with
# `bash -euo pipefail` -- and is kept so a by-hand run behaves identically.
set -euo pipefail
STORAGE="${STORAGE:-logos-storage-nim/bin/storage.exe}"
LIBDIR="${LIBDIR:-libstorage}"

# --- The binary runs at all --------------------------------------------------
# Measured on Windows 10.0.26200: both of these exit 0.
run "$STORAGE" --version | tee version.txt
grep -q "Storage version:"  version.txt
grep -q "Storage revision:" version.txt

# --- The NAT stack linked ----------------------------------------------------
# Not decoration. libplum is new in v0.4.4 and is the one vendored dependency
# whose CMake had to be told CMAKE_SYSTEM_NAME=Windows by hand -- without that
# its if(WIN32) never fires and it links neither ws2_32 nor iphlpapi. These
# options exist only if that half of the NAT stack made it into the binary, so
# this assertion is what would catch a regression there.
run "$STORAGE" --help | tee help.txt
grep -q -- "--nat-port-mapping-timeout" help.txt

# --- The library half --------------------------------------------------------
# libstorage builds no executable, so there is nothing to run here; what matters
# is that all THREE artifacts a consumer needs are present. The import library
# is the one worth asserting: nim emits only the .dll, CMake find_library will
# not return a bare .dll, and a consumer that cannot find libstorage.dll.a
# silently falls through to the static archive and fails much later on
# Nim-runtime symbols.
test -f "$LIBDIR/bin/libstorage.dll"   || { echo "::error::libstorage.dll missing"; exit 1; }
test -f "$LIBDIR/lib/libstorage.dll.a" || { echo "::error::import library missing -- consumers cannot link the DLL"; exit 1; }
test -f "$LIBDIR/include/libstorage.h" || { echo "::error::public header missing"; exit 1; }

# The DLL ships beside its own mingw runtime, which is why it loads at all when
# a consumer drops it next to a plugin. A .dll installed to lib/ instead of bin/
# gets none of this staged by nixpkgs win-dll-link, and fails to load on Windows
# with no diagnostic.
for dep in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll; do
  test -f "$LIBDIR/bin/$dep" || { echo "::error::$dep not staged beside libstorage.dll"; exit 1; }
done

echo "storage-cross smoke: OK"
