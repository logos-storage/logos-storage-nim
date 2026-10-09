#!/usr/bin/env bash
# Bootstrap the pinned compiler and package manager without account-wide installs.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/scripts/toolchain-versions.sh
source "$script_dir/toolchain-versions.sh"
toolchain_dir=${1:?Usage: setup-nim.sh TOOLCHAIN_DIRECTORY}
mkdir -p "$toolchain_dir"
toolchain_dir=$(cd "$toolchain_dir" && pwd)

case $(uname -s) in
  MINGW*|MSYS*) exe=.exe ;;
  *) exe= ;;
esac

if [[ ! -x "$toolchain_dir/nim-$NIM_VERSION/bin/nim$exe" ]]; then
  archive="$toolchain_dir/nim-$NIM_VERSION.tar.xz"
  curl --fail --location --retry 3 "https://nim-lang.org/download/nim-$NIM_VERSION.tar.xz" -o "$archive"
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$NIM_SHA256" "$archive" | sha256sum --check
  else
    printf '%s  %s\n' "$NIM_SHA256" "$archive" | shasum -a 256 --check
  fi
  tar -xJf "$archive" -C "$toolchain_dir"
  (cd "$toolchain_dir/nim-$NIM_VERSION" && sh build.sh)
  rm "$archive"
fi
export PATH="$toolchain_dir/nim-$NIM_VERSION/bin:$PATH"

# Compile Nimble from its pinned source, including its own build dependencies.
if [[ ! -f "$toolchain_dir/nimble-revision" ]] ||
   [[ $(cat "$toolchain_dir/nimble-revision") != "$NIMBLE_REV" ]]; then
  nimble_src="$toolchain_dir/nimble-src"
  if [[ ! -d "$nimble_src/.git" ]]; then
    git clone --no-checkout https://github.com/nim-lang/nimble.git "$nimble_src"
  fi
  git -C "$nimble_src" fetch --depth=1 origin "$NIMBLE_REV"
  git -C "$nimble_src" checkout --detach "$NIMBLE_REV"
  git -C "$nimble_src" submodule update --init --recursive --depth=1
  mkdir -p "$toolchain_dir/bin"
  nim c --skipParentCfg:on --skipUserCfg:on -d:release --out:"$toolchain_dir/bin/nimble" "$nimble_src/src/nimble.nim"
  printf '%s\n' "$NIMBLE_REV" > "$toolchain_dir/nimble-revision"
fi

# Unix symlinks allow one PATH entry. On Windows, CI also adds the compiler's
# original bin directory: MSYS can copy executables instead of making symlinks.
for program in nim nimsuggest; do
  if [[ -z "$exe" && -x "$toolchain_dir/nim-$NIM_VERSION/bin/$program" ]]; then
    ln -sf "../nim-$NIM_VERSION/bin/$program$exe" "$toolchain_dir/bin/$program$exe"
  fi
done
"$toolchain_dir/nim-$NIM_VERSION/bin/nim$exe" --version
"$toolchain_dir/bin/nimble" --version
