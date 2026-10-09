#!/usr/bin/env python3
"""Snapshot Nimble's resolved sources for Nix's network-free builds.

The temporary Nimble lock is only a resolver interchange format. No lockfile is
added to the package: ordinary Nimble consumers resolve storage.nimble normally.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)


def prefetch(item):
    name, package = item
    url = package["url"]
    fetched = json.loads(run("nix", "flake", "prefetch", "--json",
                             f"git+{url}?rev={package['vcsRevision']}&submodules=1"))
    source = Path(fetched["storePath"])
    manifest = (source / f"{name}.nimble")
    if not manifest.exists():
        manifests = list(source.glob("*.nimble"))
        if len(manifests) != 1:
            raise ValueError(f"Cannot identify manifest for {name}")
        manifest = manifests[0]
    contents = manifest.read_text()
    match = re.search(r'^\s*srcDir\s*=\s*"([^"]*)"', contents, re.M | re.I)
    version = re.search(r'^\s*version\s*=\s*"([^"]*)"', contents, re.M | re.I)
    if not version:
        raise ValueError(f"Cannot identify version for {name}")
    print(f"Fetched {name}", flush=True)
    return name, dict(package, narHash=fetched["hash"],
                      srcDir=match[1] if match else "", packageVersion=version[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nimble-dir", type=Path, default=ROOT / "nimbledeps")
    parser.add_argument("--lock-file", type=Path,
                        help="Reuse a previously resolved diagnostic lock")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="storage-nix-deps-") as temporary:
        lock = args.lock_file or Path(temporary) / "nimble.lock"
        if not args.lock_file:
            subprocess.run(["nimble", f"--nimbleDir:{args.nimble_dir.resolve()}",
                            "--accept", f"--lockFile:{lock}", "lock"], cwd=ROOT, check=True)
        resolved = json.loads(lock.read_text())
        packages = {k: v for k, v in resolved["packages"].items() if k != "nim"}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            fetched = dict(pool.map(prefetch, sorted(packages.items())))
        snapshot = {"nim": resolved["packages"]["nim"], "packages": fetched}
        (ROOT / "nix/dependencies.json").write_text(json.dumps(snapshot, indent=2) + "\n")


if __name__ == "__main__":
    main()
