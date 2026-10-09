# Usage

## Shell

A development shell can be started using:
```sh
nix develop '.#'
```

## Building

To build a Logos Storage you can use:
```sh
nix build '.#default'
```

It can be also done without even cloning the repo:
```sh
nix build 'github:logos-storage/logos-storage-nim'
```

To build the C bindings you can use:

```sh
nix build ".#libstorage"
```

## Running

```sh
nix run 'github:logos-storage/logos-storage-nim'
```

## Testing

```sh
nix flake check ".#"
```

## Running Logos Storage as a service on NixOS

Include logos-storage-nim flake in your flake inputs:
```nix
inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    logos-storage-nim-flake.url = "github:logos-storage/logos-storage-nim";
};
```

To configure the service, you can use the following example:
```nix
services.logos-storage-nim = {
   enable = true;
   settings = {
       data-dir = "/var/lib/storage-test";
   };
};
```
The settings attribute set corresponds directly to the layout of the TOML configuration file 
used by logos-storage-nim. Each option follows the same naming convention as the CLI flags, but 
with the -- prefix removed. For more details on the TOML file structure and options, 
refer to the official documentation: [logos-storage-nim configuration file](https://docs.codex.storage/learn/run#configuration-file).
## Dependencies and toolchain

Nix builds the pinned Nim and Nimble from `tools/scripts/toolchain-versions.sh`. It fetches the dependency sources listed in `nix/dependencies.json`, including their native source dependencies, and compiles with an isolated Nimble directory inside the sandbox. No repository submodules are needed.

The Nix source snapshot provides hashes for reproducible, network-free compilation. A temporary Nimble lock is generated inside the derivation to accommodate Nimble's offline URL resolver; it is not part of the package or used by ordinary Nimble builds and consumers.

The Nix toolchain patches Nimble 0.26's installed-package lookup to recognize recorded tags and commit pins, while still verifying the locked source revision. Without this fix Nimble attempts to download those packages again, even when their sources are already installed.

After changing `storage.nimble`, refresh the Nix snapshot with Nimble, Nix and Python 3 available:

```sh
python3 nix/update-deps.py --nimble-dir /absolute/path/to/isolated-nimble-dir
nix build .#default .#libstorage
```

Review `nix/dependencies.json` with the manifest changes. The updater creates its intermediate lock in a temporary directory.

Cross-compile the Windows CLI and C library from Linux with:

```sh
nix build .#packages.x86_64-windows.logos-storage-nim .#packages.x86_64-windows.libstorage
```
