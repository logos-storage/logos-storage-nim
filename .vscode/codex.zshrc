SCRIPT_DIR=$(dirname $(readlink -f ${(%):-%N}))
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.."; pwd)

source "$PROJECT_ROOT/env.sh"
echo Sourced NBS environment \($PROJECT_ROOT/env.sh\)

# Create symbolic link only if it doesn't exist
REAL_NIMBLE_DIR=$PROJECT_ROOT/vendor/nimbus-build-system/vendor/Nim/bin
if [ ! -L "$REAL_NIMBLE_DIR/nimble" ]; then
    ln -s -F ~/.nimble/bin/nimble "$REAL_NIMBLE_DIR/nimble"
fi
echo ""
echo "nim:           " $(nim --version | head -n1  | sed 's/Nim Compiler Version \([0-9.]*\).*/\1/')
echo "nimble:        " $($REAL_NIMBLE_DIR/nimble --version | grep "nimble v" | sed 's/nimble v\([0-9.]*\).*/\1/')  \(~/.nimble/bin/nimble\)
echo "nimsuggest:    " $(nimsuggest --version | head -n1 | sed 's/Nim Compiler Version \([0-9.]*\).*/\1/')
if command -v nimlangserver >/dev/null 2>&1; then
  echo "nimlangserver: " $(nimlangserver --version)
fi
if command -v codium >/dev/null 2>&1; then
   VSCODE_CMD="codium"
elif command -v code >/dev/null 2>&1; then
   VSCODE_CMD="code"
else
   echo "Neither VSCode nor VSCodium found"
   exit 1
fi
echo "vscode-nim:    " $($VSCODE_CMD --list-extensions --show-versions | grep "^nimlang.nimlang@" | cut -d'@' -f2)
