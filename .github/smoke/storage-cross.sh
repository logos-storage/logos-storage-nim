#!/usr/bin/env bash

# Smoke test to ensure cross-compiled storage was built successfully.

set -euo pipefail
STORAGE="${STORAGE:-logos-storage-nim/bin/storage.exe}"
LIBDIR="${LIBDIR:-libstorage}"

version=$(run "$STORAGE" --version); echo "$version"
grep -q "Storage version:"  <<<"$version" || { echo "::error::version banner missing"; exit 1; }
grep -q "Storage revision:" <<<"$version" || { echo "::error::revision banner missing"; exit 1; }

# Ensure NAT options are available via --help
help=$(run "$STORAGE" --help); echo "$help"
grep -q -- "--nat-port-mapping-timeout" <<<"$help" || { echo "::error::NAT options missing from --help"; exit 1; }

# Ensure the DLL and header are built
test -f "$LIBDIR/bin/libstorage.dll"   || { echo "::error::libstorage.dll missing"; exit 1; }
test -f "$LIBDIR/lib/libstorage.dll.a" || { echo "::error::import library missing -- consumers cannot link the DLL"; exit 1; }
test -f "$LIBDIR/include/libstorage.h" || { echo "::error::public header missing"; exit 1; }

# A missing DLL fails to load on Windows.
for dep in libgcc_s_seh-1.dll libstdc++-6.dll libwinpthread-1.dll libmcfgthread-2.dll; do
  test -f "$LIBDIR/bin/$dep" || { echo "::error::$dep not staged beside libstorage.dll"; exit 1; }
done

echo "storage-cross smoke: OK"
