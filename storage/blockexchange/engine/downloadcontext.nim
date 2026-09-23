## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[options, random, sets]

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/peerid

import ./scheduler
import ./swarm
import ../peers/peercontext
import ../../manifest
import ../../storagetypes
import ../../downloadtransport
export downloadtransport
import ../../blocktype
import ../protocol/constants
import ../protocol/message
import ../utils

export scheduler, peercontext, manifest

const
  PresenceWindowBytes*: uint64 = 1024 * 1024 * 1024
  PresenceWindowBlocks*: uint64 = PresenceWindowBytes div DefaultBlockSize.uint64
  MaxPresenceWindowBlocks*: uint64 = PresenceWindowBytes div MinBlockSize
  MaxRangeIterationsPerMessage*: uint64 =
    PresenceWindowBytes div DefaultBlockSize.uint64
  PresenceWindowThreshold*: float = 0.75
  PresenceBroadcastIntervalMin*: Duration = 5.seconds
  PresenceBroadcastIntervalMax*: Duration = 10.seconds
  PresenceBroadcastBlockThreshold*: uint64 = PresenceWindowBlocks div 2

static:
  const
    worstCaseRanges = MaxPresenceWindowBlocks div 2
    worstCasePresenceBytes = worstCaseRanges * 16 + 1024 # +1KB safe overhead
  doAssert worstCasePresenceBytes < MaxMessageSize,
    "Presence window too large for MaxMessageSize with minimum block size. " &
      "Worst case: " & $worstCasePresenceBytes & " bytes, limit: " & $MaxMessageSize &
      " bytes"

type
  DownloadProgress* = object
    blocksCompleted*: uint64
    totalBlocks*: uint64
    bytesTransferred*: uint64

  DownloadDesc* = object
    transport*: DownloadTransport
    md*: ManifestDescriptor
    startIndex*: uint64
    count*: uint64
    selectionPolicy*: SelectionPolicy
    isBackground*: bool
    fetchLocal*: bool

  BroadcastAvailabilityTracker = object
    case policy: SelectionPolicy
    of spSequential:
      lastBroadcastedWatermark: uint64
      broadcastedOutOfOrder: HashSet[uint64]
      pendingOOOSnapshot: HashSet[uint64]
      lastBroadcastTime: Moment
      broadcastInterval: Duration
    of spRandomWindow:
      pendingRanges: seq[IndexRange]

  DownloadContext* = ref object
    transport*: DownloadTransport
    providerPeers*: HashSet[PeerId]
    md*: ManifestDescriptor
    totalBlocks*: uint64
    received*: uint64
    blocksReturned*: uint64
    bytesReceived*: uint64
    scheduler*: Scheduler
    swarm*: Swarm
    availabilityTracker: BroadcastAvailabilityTracker

proc computeWindowSize*(blockSize: uint32): uint64 =
  result = PresenceWindowBytes div blockSize.uint64
  if result == 0:
    result = 1

proc randomBroadcastInterval(): Duration =
  rand(
    PresenceBroadcastIntervalMin.milliseconds.int ..
      PresenceBroadcastIntervalMax.milliseconds.int
  ).milliseconds

proc hasNewOutOfOrder(t: BroadcastAvailabilityTracker, scheduler: Scheduler): bool =
  for batchStart in scheduler.completedOutOfOrderItems:
    if batchStart notin t.broadcastedOutOfOrder:
      return true
  false

proc shouldBroadcast(t: BroadcastAvailabilityTracker, scheduler: Scheduler): bool =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.len > 0
  of spSequential:
    let
      newBlocks = scheduler.completedWatermark() - t.lastBroadcastedWatermark
      hasNewOOO = t.hasNewOutOfOrder(scheduler)
    if newBlocks == 0 and not hasNewOOO:
      return false
    let timeSinceLast = Moment.now() - t.lastBroadcastTime
    newBlocks >= PresenceBroadcastBlockThreshold or timeSinceLast >= t.broadcastInterval or
      hasNewOOO

proc getRanges(
    t: var BroadcastAvailabilityTracker, scheduler: Scheduler
): seq[IndexRange] =
  case t.policy
  of spRandomWindow:
    t.pendingRanges
  of spSequential:
    let watermark = scheduler.completedWatermark()
    var ranges: seq[IndexRange] = @[]
    if watermark > t.lastBroadcastedWatermark:
      ranges.add(
        IndexRange(
          start: t.lastBroadcastedWatermark,
          count: watermark - t.lastBroadcastedWatermark,
        )
      )
    t.pendingOOOSnapshot.clear()
    for batchStart in scheduler.completedOutOfOrderItems:
      if batchStart notin t.broadcastedOutOfOrder:
        ranges.add(IndexRange(start: batchStart, count: scheduler.batchSizeCount))
        t.pendingOOOSnapshot.incl(batchStart)
    ranges

proc markBroadcasted(t: var BroadcastAvailabilityTracker, scheduler: Scheduler) =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.setLen(0)
  of spSequential:
    let watermark = scheduler.completedWatermark()
    for batchStart in t.pendingOOOSnapshot:
      t.broadcastedOutOfOrder.incl(batchStart)
    var toRemove: seq[uint64] = @[]
    for batchStart in t.broadcastedOutOfOrder:
      if batchStart < watermark:
        toRemove.add(batchStart)
    for batchStart in toRemove:
      t.broadcastedOutOfOrder.excl(batchStart)
    t.lastBroadcastedWatermark = watermark
    t.lastBroadcastTime = Moment.now()
    t.broadcastInterval = randomBroadcastInterval()

proc addPendingRange(
    t: var BroadcastAvailabilityTracker, range: tuple[start: uint64, count: uint64]
) =
  case t.policy
  of spRandomWindow:
    t.pendingRanges.add(IndexRange(start: range.start, count: range.count))
  of spSequential:
    discard

proc currentPresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  ctx.scheduler.currentPresenceWindow()

proc needsNextPresenceWindow*(ctx: DownloadContext): bool =
  ctx.scheduler.needsNextPresenceWindow()

proc advancePresenceWindow*(ctx: DownloadContext): tuple[start: uint64, count: uint64] =
  ctx.availabilityTracker.addPendingRange(ctx.scheduler.currentPresenceWindow())
  discard ctx.scheduler.advancePresenceWindow()
  ctx.scheduler.currentPresenceWindow()

proc blockSize*(ctx: DownloadContext): uint32 =
  ctx.md.manifest.blockSize.uint32

proc new*(
    T: type DownloadContext, desc: DownloadDesc, missingBlocks: seq[uint64] = @[]
): DownloadContext =
  doAssert desc.md != nil, "ManifestDescriptor must be provided"
  let blockSize = desc.md.manifest.blockSize.uint32
  doAssert blockSize > 0, "blockSize must be known at download creation"

  let
    totalBlocks = desc.startIndex + desc.count
    batchSize = computeBatchSize(blockSize)
    windowSize = computeWindowSize(blockSize)

  result = DownloadContext(
    transport: desc.transport,
    md: desc.md,
    totalBlocks: totalBlocks,
    scheduler: Scheduler.new(),
    swarm: Swarm.new(),
  )

  case desc.selectionPolicy
  of spSequential:
    result.availabilityTracker = BroadcastAvailabilityTracker(
      policy: spSequential,
      lastBroadcastedWatermark: 0,
      broadcastedOutOfOrder: initHashSet[uint64](),
      pendingOOOSnapshot: initHashSet[uint64](),
      lastBroadcastTime: Moment.now(),
      broadcastInterval: randomBroadcastInterval(),
    )

    if missingBlocks.len > 0:
      result.scheduler.initFromIndices(
        missingBlocks, batchSize.uint64, windowSize, PresenceWindowThreshold
      )
    elif desc.count > batchSize.uint64:
      if desc.startIndex == 0:
        result.scheduler.init(
          desc.count, batchSize.uint64, windowSize, PresenceWindowThreshold
        )
      else:
        result.scheduler.initRange(
          desc.startIndex, desc.count, batchSize.uint64, windowSize,
          PresenceWindowThreshold,
        )
    else:
      var indices: seq[uint64] = @[]
      for i in desc.startIndex ..< desc.startIndex + desc.count:
        indices.add(i)
      result.scheduler.initFromIndices(
        indices, batchSize.uint64, windowSize, PresenceWindowThreshold
      )
  of spRandomWindow:
    result.availabilityTracker = BroadcastAvailabilityTracker(policy: spRandomWindow)
    result.scheduler.initRandomWindows(totalBlocks, batchSize.uint64, windowSize)

proc isComplete*(ctx: DownloadContext): bool =
  ctx.blocksReturned >= ctx.totalBlocks or ctx.received >= ctx.totalBlocks

proc markBlockReturned*(ctx: DownloadContext) =
  # mark that a block was returned to the consumer by the iterator
  ctx.blocksReturned += 1

proc markBatchReceived*(
    ctx: DownloadContext, start: uint64, count: uint64, totalBytes: uint64
) =
  ctx.received += count
  ctx.bytesReceived += totalBytes

proc trimPresenceBeforeWatermark*(ctx: DownloadContext) =
  let watermark = ctx.scheduler.completedWatermark()

  for peerId in ctx.swarm.connectedPeers():
    let peerOpt = ctx.swarm.getPeer(peerId)
    if peerOpt.isSome:
      let peer = peerOpt.get()
      # only trim range-based availability
      if peer.availability.kind == bakRanges:
        var newRanges: seq[IndexRange] = @[]
        for r in peer.availability.ranges:
          let rangeEnd = r.start + r.count
          if rangeEnd > watermark:
            # keep ranges not entirely below watermark
            newRanges.add(r)
        peer.availability = BlockAvailability.fromRanges(newRanges)

proc shouldBroadcastAvailability*(ctx: DownloadContext): bool =
  ctx.availabilityTracker.shouldBroadcast(ctx.scheduler)

proc getAvailabilityBroadcast*(ctx: DownloadContext): seq[IndexRange] =
  ctx.availabilityTracker.getRanges(ctx.scheduler)

proc markAvailabilityBroadcasted*(ctx: DownloadContext) =
  ctx.availabilityTracker.markBroadcasted(ctx.scheduler)

proc batchBytes*(ctx: DownloadContext): uint64 =
  ctx.scheduler.batchSizeCount.uint64 * ctx.blockSize.uint64

proc batchTimeout*(
    ctx: DownloadContext, peer: PeerContext, batchCount: uint64
): Duration =
  peer.batchTimeout(batchCount * ctx.blockSize.uint64)

proc progress*(ctx: DownloadContext): DownloadProgress =
  DownloadProgress(
    blocksCompleted: ctx.received,
    totalBlocks: ctx.totalBlocks,
    bytesTransferred: ctx.bytesReceived,
  )

proc remainingBlocks(ctx: DownloadContext): uint64 =
  if ctx.totalBlocks > ctx.received:
    ctx.totalBlocks - ctx.received
  else:
    0
