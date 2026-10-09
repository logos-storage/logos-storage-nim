{ pkgs }:
let
  inherit (pkgs) lib;
  snapshot = builtins.fromJSON (builtins.readFile ./dependencies.json);
  sources = lib.mapAttrs (_: package: builtins.fetchTree {
    type = "git";
    url = package.url;
    rev = package.vcsRevision;
    narHash = package.narHash;
    submodules = true;
  }) snapshot.packages;
  # Nimble's offline resolver needs a lock for URL requirements. This file is
  # private to the Nix build; it is never installed or used by Nimble consumers.
  lockEntry = package: builtins.removeAttrs package [ "narHash" "srcDir" "packageVersion" ];
  lock = pkgs.buildPackages.writeText "nimble.lock" (builtins.toJSON {
    version = 2;
    packages = (lib.mapAttrs (_: lockEntry) snapshot.packages) // { nim = snapshot.nim; };
  });
  registry = pkgs.buildPackages.writeText "packages_official.json" (builtins.toJSON
    (lib.mapAttrsToList (name: package: {
      inherit name;
      inherit (package) url;
      method = "git";
      description = "Nix source snapshot for ${name}";
      license = "unknown";
      tags = [];
    }) snapshot.packages));
in {
  inherit lock;
  # Writable copies are needed by native dependency configuration (LevelDB).
  prepare = ''
    mkdir -p "$NIMBLE_DIR"
    cp ${registry} "$NIMBLE_DIR/packages_official.json"
  '' + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: package:
    let
      dirName = "${name}-${package.packageVersion}-${package.checksums.sha1}";
      metadata = pkgs.buildPackages.writeText "${name}-nimblemeta.json" (builtins.toJSON {
        version = 1;
        metaData = {
          inherit (package) url downloadMethod vcsRevision;
          files = [];
          binaries = [];
          specialVersions = [ package.version package.packageVersion ];
        };
      });
    in ''
      mkdir -p "$NIMBLE_DIR/pkgs2/${dirName}"
      cp -R ${sources.${name}.outPath}/. "$NIMBLE_DIR/pkgs2/${dirName}/"
      ${lib.optionalString (package.srcDir != "" && package.srcDir != ".") ''
        cp -R ${sources.${name}.outPath}/${package.srcDir}/. "$NIMBLE_DIR/pkgs2/${dirName}/"
      ''}
      chmod -R u+w "$NIMBLE_DIR/pkgs2/${dirName}"
      cp ${metadata} "$NIMBLE_DIR/pkgs2/${dirName}/nimblemeta.json"
    ''
  ) snapshot.packages);
}
