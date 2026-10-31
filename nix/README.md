# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To build a Logos Storage you can use:
```sh
nix build '.#default'
```

Nix fetches the dependencies pinned in `nimble.lock`.

It can be also done without even cloning the repo:
```sh
nix build 'github:logos-storage/logos-storage-nim'
```

To build the C bindings you can use:

```sh
nix build '.#libstorage'
```

## Running

```sh
nix run 'github:logos-storage/logos-storage-nim'
```

## Testing

```sh
nix flake check
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
