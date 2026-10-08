
## Intro

`codex.zshrc` will source the NBS environment setup script (`./env.sh`)
automatically on startup into the integrated terminal environment so
VSCode (or Codium) does not need to launched with `./env.sh codium .`.

Additionally, to benefit from nimble updates, `nimble` will be symlinked from the user's home nimble
installation folder (`~/.nimble/bin/nimble`). Nimble at this location should be at a version
compatible with `nimlangserver` (`>= 0.16.1` ). Nimble can be updated with `nimble install
nimble`.

As of 1.8.0, `nimlangserver` is known to have bugs, so it's best to build it
from master, by clong [the repo](https://github.com/nim-lang/langserver), then
running `nimble install`.

## Installation

To ensure this script runs at startup and to properly setup VSCode's integrated
terminal, you'll need to update your workspace settings to look like this:

```json
"terminal.integrated.profiles.osx": {
  "zsh": {
    "path": "/bin/zsh",
    "args": [
      "-l",
      "-c",
      "source ${workspaceFolder}/.vscode/codex.zshrc && zsh -i"
    ]
  },
},
"terminal.integrated.defaultProfile.osx": "zsh"
```

## Output on startup

Once installed, on terminal startup, `codex.zshrc` will be sourced, and it will output all the
relevant versions of libraries in the environment, eg:
```shell
Sourced NBS environment (/Users/egonat/repos/codex-storage/nim-codex/env.sh)

nim:            2.0.14
nimble:         0.16.4 (~/.nimble/bin/nimble)
nimsuggest:     1.6.21
nimlangserver:  1.8.1
vscode-nim:     1.4.1
```