## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/[sugar, atomics, sequtils]

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/libp2p/[multicodec, cid, multihash]
import pkg/libp2p/protobuf/minprotobuf
import pkg/taskpools

import ../logutils
import ../manifest
import ../merkletree
import ../stores
import ../clock
import ../blocktype as bt
import ../utils
import ../utils/asynciter
import ../indexingstrategy
import ../errors
import ../utils/arrayutils
import ../utils/uniqueptr

import pkg/stew/byteutils

import ./backend

export backend

logScope:
  topics = "codex erasure"

type
  ## Encode a manifest into one that is erasure protected.
  ##
  ## The new manifest has K `blocks` that are encoded into
  ## additional M `parity` blocks. The resulting dataset
  ## is padded with empty blocks if it doesn't have a square
  ## shape.
  ##
  ## NOTE: The padding blocks could be excluded
  ## from transmission, but they aren't for now.
  ##
  ## The resulting dataset is logically divided into rows
  ## where a row is made up of B blocks. There are then,
  ## K + M = N rows in total, each of length B blocks. Rows
  ## are assumed to be of the same number of (B) blocks.
  ##
  ## The encoding is systematic and the rows can be
  ## read sequentially by any node without decoding.
  ##
  ## Decoding is possible with any K rows or partial K
  ## columns (with up to M blocks missing per column),
  ## or any combination there of.
  ##
  EncoderProvider* =
    proc(size, blocks, parity: int): EncoderBackend {.raises: [Defect], noSideEffect.}

  DecoderProvider* =
    proc(size, blocks, parity: int): DecoderBackend {.raises: [Defect], noSideEffect.}

  Erasure* = object
    taskPool: Taskpool
    encoderProvider*: EncoderProvider
    decoderProvider*: DecoderProvider
    store*: BlockStore

  ErasureRef* = ref Erasure

  EncodingParams = object
    ecK: Natural
    ecM: Natural
    rounded: Natural
    steps: Natural
    blocksCount: Natural
    strategy: StrategyType

  ErasureError* = object of CodexError
  InsufficientBlocksError* = object of ErasureError
    # Minimum size, in bytes, that the dataset must have had
    # for the encoding request to have succeeded with the parameters
    # provided.
    minSize*: NBytes

  EncodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: seq[seq[byte]]
    parity: UniquePtr[seq[seq[byte]]]
    blockSize, parityLen: int
    signal: ThreadSignalPtr

  DecodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: seq[seq[byte]]
    parity: seq[seq[byte]]
    recovered: UniquePtr[seq[seq[byte]]]
    blockSize, recoveredLen: int
    signal: ThreadSignalPtr

func indexToPos(steps, idx, step: int): int {.inline.} =
  ## Convert an index to a position in the encoded
  ##  dataset
  ## `idx`  - the index to convert
  ## `step` - the current step
  ## `pos`  - the position in the encoded dataset
  ##

  (idx - step) div steps

proc getPendingBlocks(
    self: ErasureRef, manifest: Manifest, indices: seq[int]
): AsyncIter[(?!bt.Block, int)] =
  ## Get pending blocks iterator
  ##
  var pendingBlocks: seq[Future[(?!bt.Block, int)]] = @[]

  proc attachIndex(
      fut: Future[?!bt.Block], i: int
  ): Future[(?!bt.Block, int)] {.async.} =
    ## avoids closure capture issues
    return (await fut, i)

  for blockIndex in indices:
    # request blocks from the store
    let fut = self.store.getBlock(BlockAddress.init(manifest.treeCid, blockIndex))
    pendingBlocks.add(attachIndex(fut, blockIndex))

  proc isFinished(): bool =
    pendingBlocks.len == 0

  proc genNext(): Future[(?!bt.Block, int)] {.async.} =
    let completedFut = await one(pendingBlocks)
    if (let i = pendingBlocks.find(completedFut); i >= 0):
      pendingBlocks.del(i)
      return await completedFut
    else:
      let (_, index) = await completedFut
      raise newException(
        CatchableError,
        "Future for block id not found, tree cid: " & $manifest.treeCid & ", index: " &
          $index,
      )

  AsyncIter[(?!bt.Block, int)].new(genNext, isFinished)

proc prepareEncodingData(
    self: ErasureRef,
    manifest: Manifest,
    params: EncodingParams,
    step: Natural,
    data: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!Natural] {.async.} =
  ## Prepare data for encoding
  ##

  let
    strategy = params.strategy.init(
      firstIndex = 0, lastIndex = params.rounded - 1, iterations = params.steps
    )
    indices = toSeq(strategy.getIndices(step))
    pendingBlocksIter =
      self.getPendingBlocks(manifest, indices.filterIt(it < manifest.blocksCount))

  var resolved = 0
  for fut in pendingBlocksIter:
    let (blkOrErr, idx) = await fut
    without blk =? blkOrErr, err:
      warn "Failed retrieving a block", treeCid = manifest.treeCid, idx, msg = err.msg
      return failure(err)

    let pos = indexToPos(params.steps, idx, step)
    shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
    cids[idx] = blk.cid

    resolved.inc()

  for idx in indices.filterIt(it >= manifest.blocksCount):
    let pos = indexToPos(params.steps, idx, step)
    trace "Padding with empty block", idx
    shallowCopy(data[pos], emptyBlock)
    without emptyBlockCid =? emptyCid(manifest.version, manifest.hcodec, manifest.codec),
      err:
      return failure(err)
    cids[idx] = emptyBlockCid

  success(resolved.Natural)

proc prepareDecodingData(
    self: ErasureRef,
    encoded: Manifest,
    step: Natural,
    data: ref seq[seq[byte]],
    parityData: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!(Natural, Natural)] {.async.} =
  ## Prepare data for decoding
  ## `encoded`    - the encoded manifest
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `cids`       - cids of prepared data
  ## `emptyBlock` - the empty block to be used for padding
  ##

  let
    strategy = encoded.protectedStrategy.init(
      firstIndex = 0, lastIndex = encoded.blocksCount - 1, iterations = encoded.steps
    )
    indices = toSeq(strategy.getIndices(step))
    pendingBlocksIter = self.getPendingBlocks(encoded, indices)

  var
    dataPieces = 0
    parityPieces = 0
    resolved = 0
  for fut in pendingBlocksIter:
    # Continue to receive blocks until we have just enough for decoding
    # or no more blocks can arrive
    if resolved >= encoded.ecK:
      break

    let (blkOrErr, idx) = await fut
    without blk =? blkOrErr, err:
      trace "Failed retrieving a block", idx, treeCid = encoded.treeCid, msg = err.msg
      continue

    let pos = indexToPos(encoded.steps, idx, step)

    logScope:
      cid = blk.cid
      idx = idx
      pos = pos
      step = step
      empty = blk.isEmpty

    cids[idx] = blk.cid
    if idx >= encoded.rounded:
      trace "Retrieved parity block"
      shallowCopy(
        parityData[pos - encoded.ecK], if blk.isEmpty: emptyBlock else: blk.data
      )
      parityPieces.inc
    else:
      trace "Retrieved data block"
      shallowCopy(data[pos], if blk.isEmpty: emptyBlock else: blk.data)
      dataPieces.inc

    resolved.inc

  return success (dataPieces.Natural, parityPieces.Natural)

proc init*(
    _: type EncodingParams,
    manifest: Manifest,
    ecK: Natural,
    ecM: Natural,
    strategy: StrategyType,
): ?!EncodingParams =
  if ecK > manifest.blocksCount:
    let exc = (ref InsufficientBlocksError)(
      msg:
        "Unable to encode manifest, not enough blocks, ecK = " & $ecK &
        ", blocksCount = " & $manifest.blocksCount,
      minSize: ecK.NBytes * manifest.blockSize,
    )
    return failure(exc)

  let
    rounded = roundUp(manifest.blocksCount, ecK)
    steps = divUp(rounded, ecK)
    blocksCount = rounded + (steps * ecM)

  success EncodingParams(
    ecK: ecK,
    ecM: ecM,
    rounded: rounded,
    steps: steps,
    blocksCount: blocksCount,
    strategy: strategy,
  )

proc leopardEncodeTask(tp: Taskpool, task: ptr EncodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
  let encoder = task[].erasure.encoderProvider(
    task[].blockSize, task[].blocks.len, task[].parityLen
  )
  defer:
    encoder.release()
    discard task[].signal.fireSync()

  var parity = newSeqWith(task[].parityLen, newSeq[byte](task[].blockSize))
  if (let res = encoder.encode(task[].blocks, parity); res.isErr):
    warn "Error from leopard encoder backend!", error = $res.error

    task[].success.store(false)
  else:
    var paritySeq = newSeq[seq[byte]](task[].parityLen)
    for i in 0 ..< task[].parityLen:
      var innerSeq = isolate(parity[i])
      paritySeq[i] = extract(innerSeq)

    task[].parity = newUniquePtr(paritySeq)
    task[].success.store(true)

proc asyncEncode*(
    self: ErasureRef, blockSize, parityLen: int, blocks: seq[seq[byte]]
): Future[?!seq[seq[byte]]] {.async: (raises: [CancelledError]).} =
  var threadPtr = ?ThreadSignalPtr.new().mapFailure()

  defer:
    if threadPtr != nil:
      ?threadPtr.close().mapFailure()
      threadPtr = nil

  ## Create an ecode task with block data
  var task = EncodeTask(
    erasure: cast[ptr Erasure](self),
    blockSize: blockSize,
    parityLen: parityLen,
    blocks: blocks,
    signal: threadPtr,
  )

  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardEncodeTask(self.taskPool, addr task)
  let threadFut = threadPtr.wait()

  if err =? catch(await threadFut.join()).errorOption:
    ?catch(await noCancel threadFut)
    if err of CancelledError:
      raise (ref CancelledError) err

    return failure(err)

  if not task.success.load():
    return failure("Leopard encoding task failed")

  success extractValue(task.parity)

proc encodeData(
    self: ErasureRef, manifest: Manifest, params: EncodingParams
): Future[?!Manifest] {.async.} =
  ## Encode blocks pointed to by the protected manifest
  ##
  ## `manifest` - the manifest to encode
  ##
  logScope:
    steps = params.steps
    rounded_blocks = params.rounded
    blocks_count = params.blocksCount
    ecK = params.ecK
    ecM = params.ecM

  var
    cids = seq[Cid].new()
    emptyBlock = newSeq[byte](manifest.blockSize.int)

  cids[].setLen(params.blocksCount)

  try:
    for step in 0 ..< params.steps:
      # TODO: Don't allocate a new seq every time, allocate once and zero out
      var data = seq[seq[byte]].new() # number of blocks to encode

      data[].setLen(params.ecK)

      without resolved =?
        (await self.prepareEncodingData(manifest, params, step, data, cids, emptyBlock)),
        err:
        trace "Unable to prepare data", error = err.msg
        return failure(err)

      trace "Erasure coding data", data = data[].len

      var parity: seq[seq[byte]]
      try:
        parity = ?(await self.asyncEncode(manifest.blockSize.int, params.ecM, data[]))
      except CancelledError as exc:
        raise exc

      var idx = params.rounded + step
      for j in 0 ..< params.ecM:
        without blk =? bt.Block.new(parity[j]), error:
          trace "Unable to create parity block", err = error.msg
          return failure(error)

        trace "Adding parity block", cid = blk.cid, idx
        cids[idx] = blk.cid
        if error =? (await self.store.putBlock(blk)).errorOption:
          warn "Unable to store block!", cid = blk.cid, msg = error.msg
          return failure("Unable to store block!")
        idx.inc(params.steps)

    without tree =? CodexTree.init(cids[]), err:
      return failure(err)

    without treeCid =? tree.rootCid, err:
      return failure(err)

    if err =? (await self.store.putAllProofs(tree)).errorOption:
      return failure(err)

    let encodedManifest = Manifest.new(
      manifest = manifest,
      treeCid = treeCid,
      datasetSize = (manifest.blockSize.int * params.blocksCount).NBytes,
      ecK = params.ecK,
      ecM = params.ecM,
      strategy = params.strategy,
    )

    trace "Encoded data successfully", treeCid, blocksCount = params.blocksCount
    success encodedManifest
  except CancelledError as exc:
    trace "Erasure coding encoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding encoding error", exc = exc.msg
    return failure(exc)

proc encode*(
    self: ErasureRef,
    manifest: Manifest,
    blocks: Natural,
    parity: Natural,
    strategy = SteppedStrategy,
): Future[?!Manifest] {.async.} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ##

  without params =? EncodingParams.init(manifest, blocks.int, parity.int, strategy), err:
    return failure(err)

  without encodedManifest =? await self.encodeData(manifest, params), err:
    return failure(err)

  return success encodedManifest

proc leopardDecodeTask(tp: Taskpool, task: ptr DecodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
  let decoder = task[].erasure.decoderProvider(
    task[].blockSize, task[].blocks.len, task[].parity.len
  )
  defer:
    decoder.release()
    discard task[].signal.fireSync()

  var recovered = newSeqWith(task[].blocks.len, newSeq[byte](task[].blockSize))

  if (let res = decoder.decode(task[].blocks, task[].parity, recovered); res.isErr):
    warn "Error from leopard decoder backend!", error = $res.error
    task[].success.store(false)
  else:
    var recoveredSeq = newSeq[seq[byte]](task[].blocks.len)
    for i in 0 ..< task[].blocks.len:
      var innerSeq = isolate(recovered[i])
      recoveredSeq[i] = extract(innerSeq)

    task[].recovered = newUniquePtr(recoveredSeq)
    task[].success.store(true)

proc asyncDecode*(
    self: ErasureRef, blockSize: int, blocks, parity: seq[seq[byte]]
): Future[?!seq[seq[byte]]] {.async: (raises: [CancelledError]).} =
  var threadPtr = ?ThreadSignalPtr.new().mapFailure()

  defer:
    if threadPtr != nil:
      ?threadPtr.close().mapFailure()
      threadPtr = nil

  ## Create an decode task with block data
  var task = DecodeTask(
    erasure: cast[ptr Erasure](self),
    blockSize: blockSize,
    blocks: blocks,
    parity: parity,
    signal: threadPtr,
  )

  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardDecodeTask(self.taskPool, addr task)
  let threadFut = threadPtr.wait()

  if err =? catch(await threadFut.join()).errorOption:
    ?catch(await noCancel threadFut)
    if err of CancelledError:
      raise (ref CancelledError) err

    return failure(err)

  if not task.success.load():
    return failure("Leopard decoding task failed")

  success extractValue(task.recovered)

proc decodeInternal(
    self: ErasureRef, encoded: Manifest
): Future[?!(ref seq[Cid], seq[Natural])] {.async.} =
  logScope:
    steps = encoded.steps
    rounded_blocks = encoded.rounded
    new_manifest = encoded.blocksCount

  var
    cids = seq[Cid].new()
    recoveredIndices = newSeq[Natural]()
    decoder = self.decoderProvider(encoded.blockSize.int, encoded.ecK, encoded.ecM)
    emptyBlock = newSeq[byte](encoded.blockSize.int)

  cids[].setLen(encoded.blocksCount)
  try:
    for step in 0 ..< encoded.steps:
      var
        data = seq[seq[byte]].new()
        parityData = seq[seq[byte]].new()

      data[].setLen(encoded.ecK) # set len to K
      parityData[].setLen(encoded.ecM) # set len to M

      without (dataPieces, _) =? (
        await self.prepareDecodingData(
          encoded, step, data, parityData, cids, emptyBlock
        )
      ), err:
        trace "Unable to prepare data", error = err.msg
        return failure(err)

      if dataPieces >= encoded.ecK:
        trace "Retrieved all the required data blocks"
        continue
      var recovered: seq[seq[byte]]
      trace "Erasure decoding data"
      try:
        recovered =
          ?(await self.asyncDecode(encoded.blockSize.int, data[], parityData[]))
      except CancelledError as exc:
        raise exc

      for i in 0 ..< encoded.ecK:
        let idx = i * encoded.steps + step
        if data[i].len <= 0 and not cids[idx].isEmpty:
          without blk =? bt.Block.new(recovered[i]), error:
            trace "Unable to create block!", exc = error.msg
            return failure(error)

          trace "Recovered block", cid = blk.cid, index = i
          if error =? (await self.store.putBlock(blk)).errorOption:
            warn "Unable to store block!", cid = blk.cid, msg = error.msg
            return failure("Unable to store block!")

          self.store.completeBlock(BlockAddress.init(encoded.treeCid, idx), blk)

          cids[idx] = blk.cid
          recoveredIndices.add(idx)
  except CancelledError as exc:
    trace "Erasure coding decoding cancelled"
    raise exc # cancellation needs to be propagated
  except CatchableError as exc:
    trace "Erasure coding decoding error", exc = exc.msg
    return failure(exc)
  finally:
    decoder.release()

  return (cids, recoveredIndices).success

proc decode*(self: ErasureRef, encoded: Manifest): Future[?!Manifest] {.async.} =
  ## Decode a protected manifest into it's original
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##

  without (cids, recoveredIndices) =? (await self.decodeInternal(encoded)), err:
    return failure(err)

  without tree =? CodexTree.init(cids[0 ..< encoded.originalBlocksCount]), err:
    return failure(err)

  without treeCid =? tree.rootCid, err:
    return failure(err)

  if treeCid != encoded.originalTreeCid:
    return failure(
      "Original tree root differs from the tree root computed out of recovered data"
    )

  let idxIter =
    Iter[Natural].new(recoveredIndices).filter((i: Natural) => i < tree.leavesCount)

  if err =? (await self.store.putSomeProofs(tree, idxIter)).errorOption:
    return failure(err)

  let decoded = Manifest.new(encoded)

  return decoded.success

proc repair*(self: ErasureRef, encoded: Manifest): Future[?!void] {.async.} =
  ## Repair a protected manifest by reconstructing the full dataset
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be repaired
  ##

  without (cids, _) =? (await self.decodeInternal(encoded)), err:
    return failure(err)

  without tree =? CodexTree.init(cids[0 ..< encoded.originalBlocksCount]), err:
    return failure(err)

  without treeCid =? tree.rootCid, err:
    return failure(err)

  if treeCid != encoded.originalTreeCid:
    return failure(
      "Original tree root differs from the tree root computed out of recovered data"
    )

  if err =? (await self.store.putAllProofs(tree)).errorOption:
    return failure(err)

  without repaired =? (
    await self.encode(
      Manifest.new(encoded), encoded.ecK, encoded.ecM, encoded.protectedStrategy
    )
  ), err:
    return failure(err)

  if repaired.treeCid != encoded.treeCid:
    return failure(
      "Original tree root differs from the repaired tree root encoded out of recovered data"
    )

  return success()

proc start*(self: Erasure) {.async.} =
  return

proc stop*(self: Erasure) {.async.} =
  return

proc new*(
    _: type ErasureRef,
    store: BlockStore,
    encoderProvider: EncoderProvider,
    decoderProvider: DecoderProvider,
    taskPool: Taskpool,
): ErasureRef =
  ## Create a new ErasureRef instance for encoding and decoding manifests
  ##
  ErasureRef(
    store: store,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider,
    taskPool: taskPool,
  )
