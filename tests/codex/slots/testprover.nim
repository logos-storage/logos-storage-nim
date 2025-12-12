import ../../asynctest

import pkg/chronos
import pkg/libp2p/cid

import pkg/codex/merkletree
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/slots
import pkg/codex/stores
import pkg/codex/conf
import pkg/confutils/defs
import pkg/poseidon2/io
import pkg/codex/utils/poseidon2digest
import pkg/codex/nat
import pkg/codex/utils/natutils
import ./helpers
import ../helpers

suite "Test Prover":
  let
    samples = 5
    blockSize = DefaultBlockSize
    cellSize = DefaultCellSize
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()
    challenge = 1234567.toF.toBytes.toArray32

  var
    store: BlockStore
    prover: Prover
    backend: AnyBackend
    taskpool: Taskpool

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
        circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
        circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
        numProofSamples: samples,
      )
    taskpool = Taskpool.new()
    backend = config.initializeBackend(taskpool = taskpool).tryGet()

    store = RepoStore.new(repoDs, metaDs)
    prover = Prover.new(store, backend, config.numProofSamples)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()
    taskpool.shutdown()

  test "Should sample and prove a slot":
    let (_, _, verifiable) = await createVerifiableManifest(
      store,
      8, # number of blocks in the original dataset (before EC)
      5, # ecK
      3, # ecM
      blockSize,
      cellSize,
    )

    let (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true

  test "Should generate valid proofs when slots consist of single blocks":
    # To get single-block slots, we just need to set the number of blocks in
    # the original dataset to be the same as ecK. The total number of blocks
    # after generating random data for parity will be ecK + ecM, which will
    # match the number of slots.
    let (_, _, verifiable) = await createVerifiableManifest(
      store,
      2, # number of blocks in the original dataset (before EC)
      2, # ecK
      1, # ecM
      blockSize,
      cellSize,
    )

    let (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    check:
      (await prover.verify(proof, inputs)).tryGet == true

  test "Should concurrently prove/verify":
    const iterations = 5

    var proveTasks = newSeq[Future[?!(AnyProofInputs, AnyProof)]]()
    var verifyTasks = newSeq[Future[?!bool]]()

    for i in 0 ..< iterations:
      # create multiple prove tasks
      let (_, _, verifiable) = await createVerifiableManifest(
        store,
        8, # number of blocks in the original dataset (before EC)
        5, # ecK
        3, # ecM
        blockSize,
        cellSize,
      )

      proveTasks.add(prover.prove(1, verifiable, challenge))

    let proveResults = await allFinished(proveTasks)
    # 
    for i in 0 ..< proveResults.len:
      var (inputs, proofs) = proveTasks[i].read().tryGet()
      verifyTasks.add(prover.verify(proofs, inputs))

    let verifyResults = await allFinished(verifyTasks)

    for i in 0 ..< verifyResults.len:
      check:
        verifyResults[i].read().tryGet() == true

  test "Should complete prove/verify task when cancelled":
    let (_, _, verifiable) = await createVerifiableManifest(
      store,
      8, # number of blocks in the original dataset (before EC)
      5, # ecK
      3, # ecM
      blockSize,
      cellSize,
    )

    let (inputs, proof) = (await prover.prove(1, verifiable, challenge)).tryGet

    var cancelledProof = ProofPtr.new()
    defer:
      destroyProof(cancelledProof)

    # call asyncProve and cancel the task
    let proveFut = backend.asyncProve(backend.normalizeInput(inputs), cancelledProof)
    proveFut.cancel()

    try:
      discard await proveFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      # validate the cancelledProof
      check:
        (await prover.verify(cancelledProof[], inputs)).tryGet == true

    var verifyRes = VerifyResult.new()
    defer:
      destroyVerifyResult(verifyRes)

    # call asyncVerify and cancel the task
    let verifyFut = backend.asyncVerify(proof, inputs, verifyRes)
    verifyFut.cancel()

    try:
      discard await verifyFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      # validate the verifyResponse 
      check verifyRes[] == true
