## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[tables, sets, monotimes, options]

import pkg/chronos
import pkg/libp2p
import pkg/metrics
import pkg/questionable

import ../../blocktype
import ../../logutils
import ../../stores/blockstore

import ./scheduler
import ./swarm
import ./downloadcontext

export scheduler, swarm, downloadcontext

logScope:
  topics = "storage activedownload"

declareGauge(
  storage_block_exchange_retrieval_time_us,
  "storage blockexchange block retrieval time us",
)

type
  RetriesExhaustedError* = object of StorageError
  DownloadTerminatedError* = object of StorageError
  BlockHandle* = Future[?!Block].Raising([CancelledError])
  BlockHandleOpaque* = Future[?!void].Raising([CancelledError])

  BlockReq* = object
    handle*: BlockHandle
    opaqueHandle*: BlockHandleOpaque
    blockRetries*: int
    startTime*: int64

  PendingBatch* = object
    start*: uint64
    count*: uint64
    localCount*: uint64 # blocks already local when batch was scheduled
    peerId*: PeerId
    sentAt*: Moment
    timeoutFuture*: Future[void] # timeout handler to cancel on completion
    requestFuture*: Future[void] # request future to cancel on timeout

  ActiveDownload* = ref object
    id*: uint64 # for request/response correlation - echoed in protocol
    ctx*: DownloadContext
    blocks*: Table[BlockAddress, BlockReq] # per-download block requests
    pendingBatches*: Table[uint64, PendingBatch] # batch start -> pending info
    exhaustedBlocks*: HashSet[BlockAddress]
      # blocks that exhausted retries - failed permanently
    maxBlockRetries*: int
    retryInterval*: Duration
    cancelled*: bool
    isBackground*: bool
    fetchLocal*: bool
    completionFuture*: Future[?!void].Raising([CancelledError])

proc waitForComplete*(
    download: ActiveDownload
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await download.completionFuture

proc signalCompletionIfDone(download: ActiveDownload, error: ref StorageError = nil) =
  if download.completionFuture.finished:
    return
  if error != nil:
    download.completionFuture.complete(void.failure(error))
    let termErr = (ref DownloadTerminatedError)(msg: "Download terminated")
    for _, blockReq in download.blocks:
      if not blockReq.handle.finished:
        blockReq.handle.complete(Block.failure(termErr))
        blockReq.opaqueHandle.complete(Result[void, ref CatchableError].err(termErr))
  elif download.ctx.isComplete:
    download.completionFuture.complete(success())

proc treeCid*(download: ActiveDownload): Cid =
  download.ctx.md.manifest.treeCid

proc manifestCid*(download: ActiveDownload): Cid =
  download.ctx.md.manifestCid

proc makeBlockAddress*(download: ActiveDownload, index: uint64): BlockAddress =
  BlockAddress(treeCid: download.treeCid, index: index)

proc getOrCreateBlockReq(download: ActiveDownload, address: BlockAddress): BlockReq =
  download.blocks.withValue(address, blkReq):
    return blkReq[]
  do:
    let blkReq = BlockReq(
      handle: BlockHandle.init("ActiveDownload.getWantHandle"),
      opaqueHandle: BlockHandleOpaque.init("ActiveDownload.getWantHandleOpaque"),
      blockRetries: download.maxBlockRetries,
      startTime: getMonoTime().ticks,
    )
    download.blocks[address] = blkReq

    let handle = blkReq.handle

    proc cleanUpBlock(data: pointer) {.raises: [].} =
      download.blocks.del(address)

    handle.addCallback(cleanUpBlock)
    handle.cancelCallback = proc(data: pointer) {.raises: [].} =
      if not handle.finished:
        handle.removeCallback(cleanUpBlock)
      cleanUpBlock(nil)

    return blkReq

proc getWantHandle*(
    download: ActiveDownload, address: BlockAddress
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  let blkReq = download.getOrCreateBlockReq(address)
  if download.completionFuture.finished and not blkReq.handle.finished:
    let err = (ref DownloadTerminatedError)(msg: "Download terminated")
    blkReq.handle.complete(Block.failure(err))
    blkReq.opaqueHandle.complete(Result[void, ref CatchableError].err(err))
  blkReq.handle

proc getWantHandleOpaque*(
    download: ActiveDownload, address: BlockAddress
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  download.getOrCreateBlockReq(address).opaqueHandle

proc completeWantHandle*(
    download: ActiveDownload, address: BlockAddress, blk: Option[Block] = none(Block)
): bool {.raises: [].} =
  download.blocks.withValue(address, blockReq):
    proc recordRetrievalTime(startTime: int64) =
      let
        stopTime = getMonoTime().ticks
        retrievalDurationUs = (stopTime - startTime) div 1000
      storage_block_exchange_retrieval_time_us.set(retrievalDurationUs)

    if blk.isSome:
      if not blockReq[].handle.finished:
        blockReq[].handle.complete(success(blk.get))
        blockReq[].opaqueHandle.complete(success())
        recordRetrievalTime(blockReq[].startTime)
        return true
      else:
        trace "Want handle already completed", address
        return false
    else:
      if not blockReq[].opaqueHandle.finished:
        blockReq[].opaqueHandle.complete(success())
        recordRetrievalTime(blockReq[].startTime)
        return true
      else:
        return false
  do:
    trace "No pending want handle found", address
    return false

proc failWantHandle(
    download: ActiveDownload, address: BlockAddress, error: ref StorageError
) {.raises: [].} =
  download.blocks.withValue(address, blockReq):
    if not blockReq[].handle.finished:
      blockReq[].handle.complete(Block.failure(error))
      blockReq[].opaqueHandle.complete(Result[void, ref CatchableError].err(error))

func retries*(download: ActiveDownload, address: BlockAddress): int =
  download.blocks.withValue(address, pending):
    result = pending[].blockRetries
  do:
    result = 0

func decRetries*(download: ActiveDownload, address: BlockAddress) =
  download.blocks.withValue(address, pending):
    pending[].blockRetries -= 1

func retriesExhausted*(download: ActiveDownload, address: BlockAddress): bool =
  download.blocks.withValue(address, pending):
    result = pending[].blockRetries <= 0

proc decrementBlockRetries*(
    download: ActiveDownload, addresses: seq[BlockAddress]
): seq[BlockAddress] =
  result = @[]
  for address in addresses:
    download.blocks.withValue(address, req):
      req[].blockRetries -= 1
      if req[].blockRetries <= 0:
        result.add(address)

proc failExhaustedBlocks*(download: ActiveDownload, addresses: seq[BlockAddress]) =
  if addresses.len == 0:
    return

  for address in addresses:
    download.exhaustedBlocks.incl(address)
    download.ctx.received += 1

  let error = (ref RetriesExhaustedError)(
    msg: "Block retries exhausted after " & $download.maxBlockRetries & " attempts"
  )
  for address in addresses:
    download.failWantHandle(address, error)
    download.blocks.del(address)

  download.signalCompletionIfDone(error)

proc failLocalMissing*(download: ActiveDownload, address: BlockAddress) =
  let error = (ref BlockNotFoundError)(msg: "Block not found locally: " & $address)
  download.failWantHandle(address, error)
  download.signalCompletionIfDone(error)

proc isBlockExhausted*(download: ActiveDownload, address: BlockAddress): bool =
  address in download.exhaustedBlocks

proc getBlockAddressesForRange*(
    download: ActiveDownload, start: uint64, count: uint64
): seq[BlockAddress] =
  result = @[]
  for i in start ..< start + count:
    let address = download.makeBlockAddress(i)
    if address in download.blocks:
      result.add(address)

func contains*(download: ActiveDownload, address: BlockAddress): bool =
  address in download.blocks

proc markBlockReturned*(download: ActiveDownload) =
  download.ctx.markBlockReturned()

proc markBatchInFlight*(
    download: ActiveDownload,
    start: uint64,
    count: uint64,
    localCount: uint64,
    peerId: PeerId,
    timeoutFuture: Future[void] = nil,
) =
  download.pendingBatches[start] = PendingBatch(
    start: start,
    count: count,
    localCount: localCount,
    peerId: peerId,
    sentAt: Moment.now(),
    timeoutFuture: timeoutFuture,
  )

proc setBatchTimeoutFuture*(
    download: ActiveDownload, start: uint64, timeoutFuture: Future[void]
) =
  download.pendingBatches.withValue(start, pending):
    pending[].timeoutFuture = timeoutFuture

proc setBatchRequestFuture*(
    download: ActiveDownload, start: uint64, requestFuture: Future[void]
) =
  download.pendingBatches.withValue(start, pending):
    pending[].requestFuture = requestFuture

proc completeBatchLocal*(download: ActiveDownload, start: uint64, count: uint64) =
  download.ctx.scheduler.markComplete(start)
  download.ctx.markBatchReceived(start, count, 0)
  download.signalCompletionIfDone()

proc completeBatch*(
    download: ActiveDownload,
    start: uint64,
    blocksDeliveryCount: uint64,
    totalBytes: uint64,
) =
  var localCount: uint64 = 0
  download.pendingBatches.withValue(start, pending):
    localCount = pending[].localCount
    if not pending[].timeoutFuture.isNil and not pending[].timeoutFuture.finished:
      pending[].timeoutFuture.cancelSoon()
  download.pendingBatches.del(start)

  download.ctx.scheduler.markComplete(start)

  download.ctx.markBatchReceived(start, localCount + blocksDeliveryCount, totalBytes)

  download.signalCompletionIfDone()

proc requeueBatch*(
    download: ActiveDownload, start: uint64, count: uint64, front: bool = false
) =
  download.pendingBatches.withValue(start, pending):
    if not pending[].timeoutFuture.isNil and not pending[].timeoutFuture.finished:
      pending[].timeoutFuture.cancelSoon()
  download.pendingBatches.del(start)

  if front:
    download.ctx.scheduler.requeueFront(start, count)
  else:
    download.ctx.scheduler.requeueBack(start, count)

proc partialCompleteBatch*(
    download: ActiveDownload,
    originalStart: uint64,
    originalCount: uint64,
    receivedBlocksCount: uint64,
    missingRanges: seq[tuple[start: uint64, count: uint64]],
    totalBytes: uint64,
) =
  var localCount: uint64 = 0
  download.pendingBatches.withValue(originalStart, pending):
    localCount = pending[].localCount
    if not pending[].timeoutFuture.isNil and not pending[].timeoutFuture.finished:
      pending[].timeoutFuture.cancelSoon()
  download.pendingBatches.del(originalStart)

  var missingBatches: seq[BlockBatch] = @[]
  for r in missingRanges:
    missingBatches.add((start: r.start, count: r.count))

  download.ctx.scheduler.partialComplete(originalStart, missingBatches)

  download.ctx.markBatchReceived(
    originalStart, localCount + receivedBlocksCount, totalBytes
  )

  download.signalCompletionIfDone()

proc isDownloadComplete*(download: ActiveDownload): bool =
  download.ctx.isComplete()

proc hasWorkRemaining*(download: ActiveDownload): bool =
  not download.ctx.scheduler.isEmpty()

proc pendingBatchCount*(download: ActiveDownload): int =
  download.pendingBatches.len

proc handlePeerFailure*(download: ActiveDownload, peerId: PeerId) =
  var toRequeue: seq[tuple[start: uint64, count: uint64]] = @[]
  for start, batch in download.pendingBatches:
    if batch.peerId == peerId:
      toRequeue.add((start, batch.count))

  for (start, count) in toRequeue:
    download.requeueBatch(start, count, front = true)

  trace "Requeued batches from failed peer", peer = peerId, batches = toRequeue.len

proc getSwarm(download: ActiveDownload): Swarm =
  download.ctx.swarm

proc updatePeerAvailability*(
    download: ActiveDownload, peerId: PeerId, availability: BlockAvailability
) =
  if download.ctx.swarm.getPeer(peerId).isNone:
    discard download.ctx.swarm.addPeer(peerId, availability)
  else:
    download.ctx.swarm.updatePeerAvailability(peerId, availability)

proc addPeerIfAbsent*(
    download: ActiveDownload, peerId: PeerId, availability: BlockAvailability
): bool =
  let existingPeer = download.ctx.swarm.getPeer(peerId)
  if existingPeer.isSome:
    # peer already tracked, skip if bakComplete
    return existingPeer.get().availability.kind != bakComplete

  return download.ctx.swarm.addPeer(peerId, availability)

proc handleBatchRetry*(
    download: ActiveDownload, start: uint64, count: uint64, waitTime: Duration
) {.async: (raises: [CancelledError]).} =
  let
    addresses = download.getBlockAddressesForRange(start, count)
    exhausted = download.decrementBlockRetries(addresses)
  if exhausted.len > 0:
    warn "Block retries exhausted",
      treeCid = download.treeCid, exhaustedCount = exhausted.len
    download.failExhaustedBlocks(exhausted)

  download.requeueBatch(start, count, front = false)
  await sleepAsync(waitTime)
