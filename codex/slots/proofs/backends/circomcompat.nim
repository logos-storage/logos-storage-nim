## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sugar, atomics, locks]

import pkg/chronos
import pkg/taskpools
import pkg/chronos/threadsync
import pkg/questionable/results
import pkg/circomcompat

import ../../types
import ../../../stores
import ../../../contracts

import ./converters

export circomcompat, converters
export taskpools

type
  CircomCompat* = object
    slotDepth: int # max depth of the slot tree
    datasetDepth: int # max depth of dataset  tree
    blkDepth: int # depth of the block merkle tree (pow2 for now)
    cellElms: int # number of field elements per cell
    numSamples: int # number of samples per slot
    r1csPath: string # path to the r1cs file
    wasmPath: string # path to the wasm file
    zkeyPath: string # path to the zkey file
    backendCfg: ptr CircomBn254Cfg
    vkp*: ptr CircomKey
    taskpool: Taskpool
    lock: ptr Lock

  NormalizedProofInputs*[H] {.borrow: `.`.} = distinct ProofInputs[H]

  ProveTask = object
    circom: ptr CircomCompat
    ctx: ptr CircomCompatCtx
    proof: ptr Proof
    success: Atomic[bool]
    signal: ThreadSignalPtr

  VerifyTask = object
    proof: ptr CircomProof
    vkp: ptr CircomKey
    inputs: ptr CircomInputs
    success: VerifyResult
    signal: ThreadSignalPtr

func normalizeInput*[H](
    self: CircomCompat, input: ProofInputs[H]
): NormalizedProofInputs[H] =
  ## Parameters in CIRCOM circuits are statically sized and must be properly
  ## padded before they can be passed onto the circuit. This function takes
  ## variable length parameters and performs that padding.
  ##
  ## The output from this function can be JSON-serialized and used as direct
  ## inputs to the CIRCOM circuit for testing and debugging when one wishes
  ## to bypass the Rust FFI.

  let normSamples = collect:
    for sample in input.samples:
      var merklePaths = sample.merklePaths
      merklePaths.setLen(self.slotDepth)
      Sample[H](cellData: sample.cellData, merklePaths: merklePaths)

  var normSlotProof = input.slotProof
  normSlotProof.setLen(self.datasetDepth)

  NormalizedProofInputs[H] ProofInputs[H](
    entropy: input.entropy,
    datasetRoot: input.datasetRoot,
    slotIndex: input.slotIndex,
    slotRoot: input.slotRoot,
    nCellsPerSlot: input.nCellsPerSlot,
    nSlotsPerDataSet: input.nSlotsPerDataSet,
    slotProof: normSlotProof,
    samples: normSamples,
  )

proc release*(self: CircomCompat) =
  ## Release the ctx
  ##

  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.release_cfg()

  if not isNil(self.vkp):
    self.vkp.unsafeAddr.release_key()

  if not isNil(self.lock):
    deinitLock(self.lock[]) # Cleanup the lock
    dealloc(self.lock) # Free the memory

proc circomProveTask(task: ptr ProveTask) {.gcsafe.} =
  withLock task[].circom.lock[]:
    defer:
      discard task[].signal.fireSync()

    var proofPtr: ptr Proof = nil
    try:
      if (
        let res = task.circom.backendCfg.prove_circuit(task.ctx, proofPtr.addr)
        res != ERR_OK
      ) or proofPtr == nil:
        task.success.store(false)
        return

      copyProof(task.proof, proofPtr[])
      task.success.store(true)
    finally:
      if proofPtr != nil:
        proofPtr.addr.release_proof()

proc asyncProve*[H](
    self: CircomCompat, input: NormalizedProofInputs[H], proof: ptr Proof
): Future[?!void] {.async.} =
  doAssert input.samples.len == self.numSamples, "Number of samples does not match"

  doAssert input.slotProof.len <= self.datasetDepth,
    "Slot proof is too deep - dataset has more slots than what we can handle?"

  doAssert input.samples.allIt(
    block:
      (
        it.merklePaths.len <= self.slotDepth + self.blkDepth and
        it.cellData.len == self.cellElms
      )
  ), "Merkle paths too deep or cells too big for circuit"

  # TODO: All parameters should match circom's static parametter
  var ctx: ptr CircomCompatCtx

  defer:
    if ctx != nil:
      ctx.addr.release_circom_compat()

  if init_circom_compat(self.backendCfg, addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCompat ctx")

  var
    entropy = input.entropy.toBytes
    dataSetRoot = input.datasetRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if ctx.push_input_u256_array("entropy".cstring, entropy[0].addr, entropy.len.uint32) !=
      ERR_OK:
    return failure("Failed to push entropy")

  if ctx.push_input_u256_array(
    "dataSetRoot".cstring, dataSetRoot[0].addr, dataSetRoot.len.uint32
  ) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.push_input_u256_array(
    "slotRoot".cstring, slotRoot[0].addr, slotRoot.len.uint32
  ) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.push_input_u32("nCellsPerSlot".cstring, input.nCellsPerSlot.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if ctx.push_input_u32("nSlotsPerDataSet".cstring, input.nSlotsPerDataSet.uint32) !=
      ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if ctx.push_input_u32("slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

  var slotProof = input.slotProof.mapIt(it.toBytes).concat

  doAssert(slotProof.len == self.datasetDepth)
  # arrays are always flattened
  if ctx.push_input_u256_array(
    "slotProof".cstring, slotProof[0].addr, uint (slotProof[0].len * slotProof.len)
  ) != ERR_OK:
    return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merklePaths.mapIt(@(it.toBytes)).concat
      data = s.cellData.mapIt(@(it.toBytes)).concat

    if ctx.push_input_u256_array(
      "merklePaths".cstring, merklePaths[0].addr, uint (merklePaths.len)
    ) != ERR_OK:
      return failure("Failed to push merkle paths")

    if ctx.push_input_u256_array("cellData".cstring, data[0].addr, data.len.uint) !=
        ERR_OK:
      return failure("Failed to push cell data")

  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  var task = ProveTask(circom: addr self, ctx: ctx, proof: proof, signal: threadPtr)

  let taskPtr = addr task

  doAssert task.circom.taskpool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  task.circom.taskpool.spawn circomProveTask(taskPtr)
  let threadFut = threadPtr.wait()

  if joinErr =? catch(await threadFut.join()).errorOption:
    if err =? catch(await noCancel threadFut).errorOption:
      return failure(err)
    if joinErr of CancelledError:
      raise joinErr
    else:
      return failure(joinErr)

  if not task.success.load():
    return failure("Failed to prove circuit")

  success()

proc prove*[H](
    self: CircomCompat, input: ProofInputs[H]
): Future[?!CircomProof] {.async, raises: [CancelledError].} =
  var proof = ProofPtr.new()
  defer:
    destroyProof(proof)

  try:
    if error =? (await self.asyncProve(self.normalizeInput(input), proof)).errorOption:
      return failure(error)
    return success(deepCopy(proof)[])
  except CancelledError as exc:
    raise exc

proc circomVerifyTask(task: ptr VerifyTask) {.gcsafe.} =
  defer:
    task[].inputs[].releaseCircomInputs()
    discard task[].signal.fireSync()

  let res = verify_circuit(task[].proof, task[].inputs, task[].vkp)
  if res == ERR_OK:
    task[].success[] = true
  elif res == ERR_FAILED_TO_VERIFY_PROOF:
    task[].success[] = false
  else:
    task[].success[] = false
    error "Failed to verify proof", errorCode = res

proc asyncVerify*[H](
    self: CircomCompat,
    proof: CircomProof,
    inputs: ProofInputs[H],
    success: VerifyResult,
): Future[?!void] {.async.} =
  var proofPtr = unsafeAddr proof
  var inputs = inputs.toCircomInputs()

  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  var task = VerifyTask(
    proof: proofPtr,
    vkp: self.vkp,
    inputs: addr inputs,
    success: success,
    signal: threadPtr,
  )

  let taskPtr = addr task

  doAssert self.taskpool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"

  self.taskpool.spawn circomVerifyTask(taskPtr)

  let threadFut = threadPtr.wait()

  if joinErr =? catch(await threadFut.join()).errorOption:
    if err =? catch(await noCancel threadFut).errorOption:
      return failure(err)
    if joinErr of CancelledError:
      raise joinErr
    else:
      return failure(joinErr)

  success()

proc verify*[H](
    self: CircomCompat, proof: CircomProof, inputs: ProofInputs[H]
): Future[?!bool] {.async, raises: [CancelledError].} =
  ## Verify a proof using a ctx
  ##
  var res = VerifyResult.new()
  defer:
    destroyVerifyResult(res)
  try:
    if error =? (await self.asyncVerify(proof, inputs, res)).errorOption:
      return failure(error)
    return success(res[])
  except CancelledError as exc:
    raise exc

proc init*(
    _: type CircomCompat,
    r1csPath: string,
    wasmPath: string,
    zkeyPath: string = "",
    slotDepth = DefaultMaxSlotDepth,
    datasetDepth = DefaultMaxDatasetDepth,
    blkDepth = DefaultBlockDepth,
    cellElms = DefaultCellElms,
    numSamples = DefaultSamplesNum,
    taskpool: Taskpool,
): CircomCompat =
  # Allocate and initialize the lock
  var lockPtr = create(Lock) # Allocate memory for the lock
  initLock(lockPtr[]) # Initialize the lock

  ## Create a new ctx
  var cfg: ptr CircomBn254Cfg
  var zkey = if zkeyPath.len > 0: zkeyPath.cstring else: nil

  if init_circom_config(r1csPath.cstring, wasmPath.cstring, zkey, cfg.addr) != ERR_OK or
      cfg == nil:
    if cfg != nil:
      cfg.addr.release_cfg()
    raiseAssert("failed to initialize circom compat config")

  var vkpPtr: ptr VerifyingKey = nil

  if cfg.get_verifying_key(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    if vkpPtr != nil:
      vkpPtr.addr.release_key()
    raiseAssert("Failed to get verifying key")

  CircomCompat(
    r1csPath: r1csPath,
    wasmPath: wasmPath,
    zkeyPath: zkeyPath,
    slotDepth: slotDepth,
    datasetDepth: datasetDepth,
    blkDepth: blkDepth,
    cellElms: cellElms,
    numSamples: numSamples,
    backendCfg: cfg,
    vkp: vkpPtr,
    taskpool: taskpool,
    lock: lockPtr,
  )
