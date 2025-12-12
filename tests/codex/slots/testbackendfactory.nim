import os
import ../../asynctest

import pkg/chronos
import pkg/confutils/defs
import pkg/codex/conf
import pkg/taskpools
import pkg/codex/slots/proofs/backends
import pkg/codex/slots/proofs/backendfactory
import pkg/codex/slots/proofs/backendutils
import pkg/codex/utils/natutils

import ../helpers
import ../examples

type BackendUtilsMock = ref object of BackendUtils
  argR1csFile: string
  argWasmFile: string
  argZKeyFile: string

method initializeCircomBackend*(
    self: BackendUtilsMock,
    r1csFile: string,
    wasmFile: string,
    zKeyFile: string,
    taskpool: Taskpool,
): AnyBackend =
  self.argR1csFile = r1csFile
  self.argWasmFile = wasmFile
  self.argZKeyFile = zKeyFile
  # We return a backend with *something* that's not nil that we can check for.
  var
    key = VerifyingKey(icLen: 123)
    vkpPtr: ptr VerifyingKey = key.addr
  return CircomCompat(vkp: vkpPtr)

suite "Test BackendFactory":
  let
    utilsMock = BackendUtilsMock()
    circuitDir = "testecircuitdir"

  setup:
    createDir(circuitDir)

  teardown:
    removeDir(circuitDir)

  test "Should create backend from cli config":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        marketplaceAddress: EthAddress.example.some,
        circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
        circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
        circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
      )
      backend = config.initializeBackend(utilsMock, taskpool = nil).tryGet

    check:
      backend.vkp != nil
      utilsMock.argR1csFile == $config.circomR1cs
      utilsMock.argWasmFile == $config.circomWasm
      utilsMock.argZKeyFile == $config.circomZkey

  test "Should create backend from local files":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        marketplaceAddress: EthAddress.example.some,

        # Set the circuitDir such that the tests/circuits/fixtures/ files
        # will be picked up as local files:
        circuitDir: OutDir("tests/circuits/fixtures"),
      )
      backend = config.initializeBackend(utilsMock, taskpool = nil).tryGet

    check:
      backend.vkp != nil
      utilsMock.argR1csFile == config.circuitDir / "proof_main.r1cs"
      utilsMock.argWasmFile == config.circuitDir / "proof_main.wasm"
      utilsMock.argZKeyFile == config.circuitDir / "proof_main.zkey"

  test "Should suggest usage of downloader tool when files not available":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        marketplaceAddress: EthAddress.example.some,
        circuitDir: OutDir(circuitDir),
      )
      backendResult = config.initializeBackend(utilsMock, taskpool = nil)

    check:
      backendResult.isErr
