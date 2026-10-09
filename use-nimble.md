You are to migrate this repository from using nimbus-build-system (https://github.com/status-im/nimbus-build-system) to Nimble (https://nim-lang.github.io/nimble/).

You will, as much as possible try to use version ranges for libraries. Nim packages are often versioned poorly or without respecting semantic versioning, however, so you might be forced to:

1. pin a specific version in the nimble file;
2. pin a commit hash for packages that have no released versions.

Use an isolated/separate package directory (--nimbleDir) so packages you download don't mingle with my global account packages. Feel free to delete your nimbleDir as often as you'd like. You might need to install the latest version of nimble itself (nimble install nimble).

A successful outcome means you are able to delete our ./vendor folder and build logos-storage-nim and libstorage using nimble. This is the first part of your task. Once that is done, you should update the Makefile to use nimble as well. The makefile should also use an isolated nimbleDir and not mix things up with the account packages. Finally, when all is done, you should update the README files.

I want you to log your decisions and anything else you might deem relevant for understanding your changes (including to your future self) in this file, under the "Agent" session.

## Agent

### Initial investigation (2026-10-08)

- Use `/tmp/storage-nimble-migration` for dependency resolution experiments; every Nimble invocation must specify `--nimbleDir`. System Nim is 2.2.12 and Nimble is 0.26.0.
- Preserve the existing vendor checkout, including the untracked libp2p note, and user configuration/experiment files. Verify independence in a separate vendor-free source tree before removing any submodule wiring.
- Start with bounded version ranges and pin only unreleased mix packages. The old submodules bypassed dependency constraints: mix requires libp2p 2.3.5 while vendor has 2.3.6; datastore requires stew < 0.5 while vendor has 0.5.2. Resolve and test these constraints rather than copying vendor paths into Nimble.
- The compiler extension paths and two mix includes explicitly reference vendor and must become location independent. Native library build requirements also need verification.

### Dependency and task decisions

- Consulted the Nimble guide at https://nim-lang.github.io/nimble/ and the installed Nimble 0.26.0 source. Use `getPaths()` to supply resolved dependency paths to custom tasks, and `--noNimblePath` to avoid implicit global packages. `commandLineParams` in Nimble is a sequence, not a procedure.
- Use Nimble's built-in `build` action with `bin = @["storage"]`; preserve the other existing tasks, including shared/static library builds.
- `datastore` is absent from the official package list, so name its repository explicitly. Select Logos Storage's serde/leveldb and Status's zippy explicitly. Pin blscurve and merkletree to the existing revisions because they have no release tags.
- Compiler extension definitions now use absolute project paths, and nested mix includes use Nim's dependency search paths.
- Make invokes Nimble with `--nimbleDir:$(NIMBLE_DIR)` and defaults to `./nimbledeps`; `make update` installs locked dependencies, and dependency upgrades must be explicit (`nimble lock --refresh`).

### Merkletree detour (authorized by user)

- Confirmed `chronos ~= 4.0.4` means >= 4.0.4 and < 4.1.0; libp2p 2.3.5 requires >= 4.2.2. Older merkletree history does not provide a usable compatible manifest.
- Worktree `/tmp/storage-nimble-merkletree`, branch `chore/update-chronos`, based on upstream master `beeb3118c2f77c20682d3c0b6b610fd69f32b5a4`: allow Chronos >= 4.2.2 < 5 and taskpools >= 0.2 < 0.3.
- Specialize both `compressor: CompressFn` parameters as `CompressFn[H, K]`. This fixes compilation on Nim 2.2.12 without Storage's legacy compiler switch. Update CI to test Nim 2.2.6 and 2.2.12 (2.0.16 was already below the package's minimum compiler requirement).
- Both merkletree suites pass (4 tests each) with Chronos 4.2.4, taskpools 0.2.2 and Nim 2.2.12; log `/tmp/storage-merkletree-test-fixed.log`.
- The root Nimble solver repeatedly spent several minutes with no result. Test an alternative installed Nimble 0.22.3 binary (copied to `/tmp/storage-nimble-0.22.3`, independent of vendor), with the same isolated directory.
- secp256k1 has no tag for the compatible old 0.6.0.3.2 version, and its two released versions require newer stew. Pin the existing revision d8f1288b7c72f00be5fc2c5ea72bf5cae1eafb15.

### Handoff

- Merkletree changes are in `/tmp/storage-nimble-merkletree` on `chore/update-chronos`, local commit `7250767851b792c5a8adbb9dceb8a97b3ab72d37`. A copy of the patch is preserved in `tools/nimble/merkletree-modern-chronos.patch`.
- Push was rejected by GitHub because the CLI OAuth token lacks workflow scope for the CI file; no remote branch was published. The user will handle committing/publishing.
- Storage migration remains work in progress: no successful full dependency lock or vendor-free Storage/libstorage build yet. The narrowed experimental manifest is `/tmp/storage-nimble-source/storage.nimble`; it uses the merkletree development checkout. Main-repository Makefile/config/task edits are unvalidated drafts, and READMEs/submodule/Nix/CI migration is not complete.
- Stable Nimble comparison log: `/tmp/storage-nimble-stable.log`; newer resolver logs: `/tmp/storage-nimble-lock.log` and `/tmp/storage-nimble-minver.log`. Stopped active resolution at handoff.

### Resumed after merkletree v1.0.0

- User merged the detour and released v1.0.0 (tag commit `5c69a51bf2561ab568546d512b606232a1c07756`). Require >= 1.0.0 < 2.0.0 from the public repository and remove the temporary develop override and superseded patch.
- Remove the old Nim 2.2.12 compatibility switch now that merkletree specializes the compressor parameter types. Remove task definitions from compiler config; tasks belong in the Nimble manifest.

### Resolved dependencies and validation scope

- v1.0.0's merkletree manifest still says 0.1.0, so use `#v1.0.0` rather than a >= 1.0.0 range. The compiler compatibility workaround is no longer needed.
- Metrics 0.2.2 has no tag; the newer 0.2.3 release requires stew >= 0.5.2, conflicting with datastore < 0.5. Pin the original metrics revision b4b70a88fe1755d281366cbc3f22d7515240d192.
- Nimble resolved the graph after fixing these constraints. It then failed with `Package not found in solution: https://github.com/logos-storage/nim-leveldb 0.2.3`; use the registered `leveldbstatic` name (its old codex-storage URL redirects to the same repository), avoiding duplicate aliases.
- Added the directly imported Status fork of lrucache and explicit faststreams requirement. Incremental relocking stalled, but generating a fresh lock via `--lockFile:/tmp/storage-nimble-new.lock` succeeded. Copied that generated lock to `nimble.lock`.
- Scope clarified by user: only Nimble, Makefile and READMEs. Retain vendor/submodule definitions; Nix, CI and Docker migration is separate work and their current Nimbus-based configurations are not validated by this change.
- Nimble 0.26 uses the configured global `buildtemp` directory for some native package installation even with `--nimbleDir`. Installed/downloaded project packages remain under `/tmp/storage-nimble-migration`; package compilation staging in `~/.nimble/buildtemp` is a Nimble limitation.

### Lockfile-free validation and custom tasks (2026-10-09)

- User requires successful builds without a lockfile because libstorage can be consumed as a dependency. Removed the generated `nimble.lock` from the proposed change; all compatibility constraints belong in `storage.nimble`. Prior locks are diagnostic artifacts under `/tmp` only. Updated Makefile/README wording accordingly.
- Nimble 0.26 no longer populates `__NIMBLE_PATHS`, so `getPaths()` returns no useful paths in custom tasks. Custom build/test tasks invoke the same Nimble executable's `c` action, with the inherited isolated directory and selected compiler. This supplies the dependency paths and forwards compiler options.
- Without a lockfile, Nimble's `--offline` resolver rejects pinned URL dependencies even when cached (`Cannot check URL type in offline mode`). Use normal online resolution for the final lockfile-free checks; nested compiler actions cannot force offline mode.
- libstorage imports taskpools/channels_spsc_single, removed in releases 0.2.1 and 0.2.2. Version 0.2.0 has no tag. Pin the existing vendor revision `97f76faef6ba64bc77d9808c27ec5e9917e7cfde` (manifest version 0.2.0), compatible with the updated merkletree requirement, rather than changing the threading implementation.
- First full unit run compiled and executed 680 tests; 624 passed and 56 failed with sandbox socket restrictions. Rerunning outside the sandbox for a meaningful result.

- Vendor-free, lockfile-free `make` succeeds. `build/storage --version` reports v0.5.3 / 9abeb709; `--help` succeeds. Log: `/tmp/storage-nimble-unlocked-cli-online.log`.
- Full unit suite rerun outside the sandbox: 680 tests, 677 passed, 0 failed, 3 skipped. Log: `/tmp/storage-nimble-tests-unrestricted.log`. This run used the final dependency versions, initially resolved from the diagnostic lock before its removal.
- Shared library rebuilt successfully without vendor or lockfile, through `make testLibstorage`; final C/Nim results are below.
- `make build-nph` succeeds with a separate `NIMBLE_DIR/tools` package graph. Correct CLI range syntax is `nph@>=0.7.0 & <0.8.0`.
- Both executable and sourced Bash forms of `env.sh` succeed without the lockfile. Earlier Nimble shell actions errored during lock/manifest mismatch; matching, lockfile-free resolution works.
- Expanded the old installation whitelist (which only contained build.nims) to include storage/library sources, compiler config, root module, embedded network presets and licenses. This is necessary for consuming the package as a dependency.

- Lockfile-free `make testLibstorage` completed successfully: 28 C API checks and all 22 Nim library tests passed. Log: `/tmp/storage-nimble-unlocked-library-tests.log`.
- libp2p resolves to 2.3.5 because both mix packages require that exact release, versus 2.3.6 in vendor. The full unit and library tests pass with this resolution; it does not include later 2.3.6 fixes.

- Direct `nimble --nimbleDir:/tmp/storage-nimble-migration --accept libstorageStatic -d:release --parallelBuild:4` succeeds without vendor or lockfile, producing `build/libstorage.a`. Log: `/tmp/storage-nimble-unlocked-static.log`.
- `make deps` succeeds without a lockfile and generates `nimble.paths`. No lockfile is present in either the working repository or validation checkout.

### Final outcome

- Completed the requested Nimble/Makefile/README migration in the working checkout, leaving changes uncommitted. Nix/CI/Docker and submodule wiring remain outside this change as requested. Existing user configuration/experiment files and the dirty libp2p submodule were preserved.
- Validation source tree: `/tmp/storage-nimble-source`; isolated package directory: `/tmp/storage-nimble-migration`. The source tree has neither `vendor/` nor `nimble.lock`. CLI, shared libstorage and static libstorage builds all succeed there.
- Test results: 677 unit tests passed (3 skipped), 28 C API checks passed, 22 Nim library tests passed. Formatter installation and Make dependency setup also passed. `git diff --check`, Bash syntax and Zsh syntax checks pass.
- A separate downstream project at `/tmp/storage-nimble-consumer` requires Storage plus its own Chronos range, references the validation tree through `nimble.develop`, includes Storage's compiler configuration, and imports the public `storage` module and `library/ffi_types`. With no lockfile it resolves, compiles, and runs successfully. Log: `/tmp/storage-nimble-consumer.log`. This tests dependency consumption from source; it is not a published-package installation test.
- No integration/NAT-container, Nix, CI or Docker builds were run. Native builds were validated on Linux x86-64 with Nim 2.2.12 and Nimble 0.26.0.
