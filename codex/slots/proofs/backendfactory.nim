import os
import strutils
import pkg/chronos
import pkg/chronicles
import pkg/taskpools
import pkg/questionable
import pkg/confutils/defs
import pkg/stew/io2
import pkg/ethers

import ../../conf
import ./backends
import ./backendutils

proc initializeFromConfig(
    config: CodexConf, utils: BackendUtils, taskpool: Taskpool
): ?!AnyBackend =
  if not fileAccessible($config.circomR1cs, {AccessFlags.Read}) or
      not endsWith($config.circomR1cs, ".r1cs"):
    return failure("Circom R1CS file not accessible")

  if not fileAccessible($config.circomWasm, {AccessFlags.Read}) or
      not endsWith($config.circomWasm, ".wasm"):
    return failure("Circom wasm file not accessible")

  if not fileAccessible($config.circomZkey, {AccessFlags.Read}) or
      not endsWith($config.circomZkey, ".zkey"):
    return failure("Circom zkey file not accessible")

  trace "Initialized prover backend from cli config"
  success(
    utils.initializeCircomBackend(
      $config.circomR1cs, $config.circomWasm, $config.circomZkey, taskpool
    )
  )

proc r1csFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.r1cs"

proc wasmFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.wasm"

proc zkeyFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.zkey"

proc initializeFromCircuitDirFiles(
    config: CodexConf, utils: BackendUtils, taskpool: Taskpool
): ?!AnyBackend {.gcsafe.} =
  if fileExists(config.r1csFilePath) and fileExists(config.wasmFilePath) and
      fileExists(config.zkeyFilePath):
    trace "Initialized prover backend from local files"
    return success(
      utils.initializeCircomBackend(
        config.r1csFilePath, config.wasmFilePath, config.zkeyFilePath, taskpool
      )
    )

  failure("Circuit files not found")

proc suggestDownloadTool(config: CodexConf) =
  without address =? config.marketplaceAddress:
    raise (ref Defect)(
      msg: "Proving backend initializing while marketplace address not set."
    )

  let
    tokens = ["cirdl", "\"" & $config.circuitDir & "\"", config.ethProvider, $address]
    instructions = "'./" & tokens.join(" ") & "'"

  warn "Proving circuit files are not found. Please run the following to download them:",
    instructions

proc initializeBackend*(
    config: CodexConf, utils: BackendUtils = BackendUtils(), taskpool: Taskpool
): ?!AnyBackend =
  without backend =? initializeFromConfig(config, utils, taskpool), cliErr:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    without backend =? initializeFromCircuitDirFiles(config, utils, taskpool), localErr:
      info "Could not initialize prover backend from circuit dir files...",
        msg = localErr.msg
      suggestDownloadTool(config)
      return failure("CircuitFilesNotFound")
    # Unexpected: value of backend does not survive leaving each scope. (definition does though...)
    return success(backend)
  return success(backend)
