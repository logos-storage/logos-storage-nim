## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[algorithm, deques, sets, tables, options, random, bitops, math]

type
  BlockBatch* = tuple[start: uint64, count: uint64]

  SelectionPolicy* = enum
    spSequential
    spRandomWindow

  SequentialWindowCursor = object
    advanceThreshold: float

  RandomWindowCursor = object
    totalWindows: uint64
    halfBits: uint8
    roundKeys: array[4, uint64]
    nextIdx: uint64

  WindowCursor = object
    windowStart: uint64
    windowSize: uint64
    totalBlocks: uint64
    case policy: SelectionPolicy
    of spSequential:
      sequential: SequentialWindowCursor
    of spRandomWindow:
      random: RandomWindowCursor

  Scheduler* = ref object
    totalBlocks: uint64
    batchSize: uint64
    nextBatchStart: uint64
    requeued: Deque[BlockBatch]
    completedWatermark: uint64
    completedOutOfOrder: HashSet[uint64]
    inFlight: Table[uint64, uint64] # batch start -> block count
    batchRemaining: Table[uint64, uint64] # parent batch start -> remaining blocks
    windowCursor: WindowCursor

proc canAdvance(
    p: SequentialWindowCursor, windowStart, windowSize, totalBlocks: uint64
): bool =
  windowStart + windowSize < totalBlocks

proc needsAdvance(
    p: SequentialWindowCursor, windowStart, windowSize, totalBlocks, watermark: uint64
): bool =
  if not p.canAdvance(windowStart, windowSize, totalBlocks):
    return false
  let thresholdPos = windowStart + (windowSize.float * p.advanceThreshold).uint64
  watermark >= thresholdPos

proc advance(
    p: SequentialWindowCursor, windowStart, windowSize, totalBlocks: uint64
): (bool, uint64) =
  if not p.canAdvance(windowStart, windowSize, totalBlocks):
    return (false, 0)
  (true, min(windowStart + windowSize, totalBlocks))

proc permuteWindowIndex(p: RandomWindowCursor, x: uint64): uint64 =
  func fmix64(x: uint64, seed: uint64): uint64 =
    var h = x xor seed
    h = h xor (h shr 33)
    h = h * 0xff51afd7ed558ccd'u64
    h = h xor (h shr 33)
    h = h * 0xc4ceb9fe1a85ec53'u64
    h = h xor (h shr 33)
    h

  let mask = (1'u64 shl p.halfBits) - 1
  var
    left = (x shr p.halfBits) and mask
    right = x and mask
  for i in 0 .. 3:
    let
      f = fmix64(right, p.roundKeys[i]) and mask
      newLeft = right
      newRight = left xor f
    left = newLeft
    right = newRight
  (left shl p.halfBits) or right

proc pickNext(p: var RandomWindowCursor): uint64 =
  if p.totalWindows <= 1:
    p.nextIdx += 1
    return 0
  var x = p.nextIdx
  while true:
    let permuted = p.permuteWindowIndex(x)
    x = permuted
    if permuted < p.totalWindows:
      p.nextIdx += 1
      return permuted

proc isDone(p: RandomWindowCursor): bool =
  p.nextIdx >= p.totalWindows

proc advance(p: var RandomWindowCursor, windowSize: uint64): (bool, uint64) =
  if p.isDone:
    return (false, 0)
  let windowIdx = p.pickNext()
  (true, windowIdx * windowSize)

proc currentWindow(p: WindowCursor): tuple[start: uint64, count: uint64] =
  (start: p.windowStart, count: min(p.windowSize, p.totalBlocks - p.windowStart))

proc isDone(p: WindowCursor): bool =
  case p.policy
  of spSequential:
    not p.sequential.canAdvance(p.windowStart, p.windowSize, p.totalBlocks)
  of spRandomWindow:
    p.random.isDone

proc canAdvance(p: WindowCursor): bool =
  not p.isDone

proc needsAdvance(p: WindowCursor, watermark: uint64): bool =
  case p.policy
  of spSequential:
    p.sequential.needsAdvance(p.windowStart, p.windowSize, p.totalBlocks, watermark)
  of spRandomWindow:
    false

proc advance(p: var WindowCursor): bool =
  let (ok, newStart) =
    case p.policy
    of spSequential:
      p.sequential.advance(p.windowStart, p.windowSize, p.totalBlocks)
    of spRandomWindow:
      p.random.advance(p.windowSize)
  if ok:
    p.windowStart = newStart
  ok

proc initSequentialWindowCursor(
    totalBlocks: uint64, windowSize: uint64, advanceThreshold: float
): WindowCursor =
  WindowCursor(
    policy: spSequential,
    windowStart: 0,
    windowSize: windowSize,
    totalBlocks: totalBlocks,
    sequential: SequentialWindowCursor(advanceThreshold: advanceThreshold),
  )

proc initRandomWindowCursor(totalBlocks: uint64, windowSize: uint64): WindowCursor =
  if totalBlocks == 0 or windowSize == 0:
    return WindowCursor(policy: spRandomWindow)

  var rng = initRand()
  let
    totalWindows = ceilDiv(totalBlocks, windowSize)
    seed = cast[uint64](rng.next())

  var
    rngKeys = initRand(cast[int64](seed))
    random = RandomWindowCursor(totalWindows: totalWindows)
  if totalWindows <= 1:
    random.halfBits = 1
  else:
    let bits = fastLog2(int(totalWindows - 1)) + 1
    random.halfBits = max(1'u8, uint8((bits + 1) div 2))
  for i in 0 .. 3:
    random.roundKeys[i] = rngKeys.next().uint64

  let windowIdx = random.pickNext()
  result = WindowCursor(
    policy: spRandomWindow,
    windowSize: windowSize,
    totalBlocks: totalBlocks,
    random: random,
  )
  result.windowStart = windowIdx * result.windowSize

proc new*(T: type Scheduler): Scheduler =
  Scheduler(
    totalBlocks: 0,
    batchSize: 0,
    nextBatchStart: 0,
    requeued: initDeque[BlockBatch](),
    completedWatermark: 0,
    completedOutOfOrder: initHashSet[uint64](),
    inFlight: initTable[uint64, uint64](),
    batchRemaining: initTable[uint64, uint64](),
    windowCursor: WindowCursor(policy: spSequential),
  )

proc resetState(self: Scheduler, batchSize: uint64) =
  self.batchSize = batchSize
  self.nextBatchStart = 0
  self.completedWatermark = 0
  self.requeued.clear()
  self.completedOutOfOrder.clear()
  self.inFlight.clear()
  self.batchRemaining.clear()

proc add*(self: Scheduler, start: uint64, count: uint64) =
  self.requeued.addLast((start: start, count: count))
  let batchEnd = start + count
  if batchEnd > self.totalBlocks:
    self.totalBlocks = batchEnd
  if self.batchSize == 0:
    self.batchSize = count

proc init*(
    self: Scheduler,
    totalBlocks: uint64,
    batchSize: uint64,
    windowSize: uint64,
    advanceThreshold: float,
) =
  self.totalBlocks = totalBlocks
  self.resetState(batchSize)
  self.windowCursor =
    initSequentialWindowCursor(totalBlocks, windowSize, advanceThreshold)

proc initRange*(
    self: Scheduler,
    startIndex: uint64,
    count: uint64,
    batchSize: uint64,
    windowSize: uint64,
    advanceThreshold: float,
) =
  self.totalBlocks = startIndex + count
  self.resetState(batchSize)
  self.nextBatchStart = startIndex
  self.completedWatermark = startIndex
  self.windowCursor =
    initSequentialWindowCursor(self.totalBlocks, windowSize, advanceThreshold)

proc initFromIndices*(
    self: Scheduler,
    indices: seq[uint64],
    batchSize: uint64,
    windowSize: uint64,
    advanceThreshold: float,
) =
  let sortedIndices = indices.sorted()
  self.totalBlocks = 0
  self.resetState(batchSize)

  var
    batchStart: uint64 = 0
    batchCount: uint64 = 0
    inBatch = false

  for blockIdx in sortedIndices:
    if not inBatch:
      batchStart = blockIdx
      batchCount = 1
      inBatch = true
    elif blockIdx == batchStart + batchCount:
      batchCount += 1
    else:
      self.add(batchStart, batchCount)
      batchStart = blockIdx
      batchCount = 1

    if batchCount >= batchSize:
      self.add(batchStart, batchCount)
      inBatch = false
      batchCount = 0

  if inBatch and batchCount > 0:
    self.add(batchStart, batchCount)

  self.windowCursor =
    initSequentialWindowCursor(self.totalBlocks, windowSize, advanceThreshold)

proc initRandomWindows*(
    self: Scheduler, totalBlocks: uint64, batchSize: uint64, windowSize: uint64
) =
  self.totalBlocks = totalBlocks
  self.resetState(batchSize)
  self.windowCursor = initRandomWindowCursor(totalBlocks, windowSize)
  self.nextBatchStart = self.windowCursor.currentWindow().start

proc currentPresenceWindow*(self: Scheduler): tuple[start: uint64, count: uint64] =
  self.windowCursor.currentWindow()

proc neededRange*(self: Scheduler): tuple[start: uint64, count: uint64] =
  let (windowStart, windowCount) = self.windowCursor.currentWindow()
  case self.windowCursor.policy
  of spSequential:
    let
      neededEnd =
        min(windowStart + windowCount + self.windowCursor.windowSize, self.totalBlocks)
      start = min(self.completedWatermark, neededEnd)
    (start, neededEnd - start)
  of spRandomWindow:
    (windowStart, windowCount)

proc generateNextBatchInternal(self: Scheduler): Option[BlockBatch] {.inline.} =
  ## does NOT add to inFlight - we must do that
  let (windowStart, windowCount) = self.windowCursor.currentWindow()
  while self.nextBatchStart < windowStart + windowCount:
    let
      start = self.nextBatchStart
      count = min(self.batchSize, windowStart + windowCount - start)
    self.nextBatchStart = start + count

    if start < self.completedWatermark:
      continue
    if start in self.inFlight:
      continue
    if start in self.completedOutOfOrder:
      continue

    return some((start: start, count: count))

  return none(BlockBatch)

proc take*(self: Scheduler): Option[BlockBatch] =
  while self.requeued.len > 0:
    let batch = self.requeued.popFirst()
    if batch.start < self.completedWatermark:
      continue
    if batch.start in self.completedOutOfOrder:
      continue
    self.inFlight[batch.start] = batch.count
    return some(batch)

  let batchOpt = self.generateNextBatchInternal()
  if batchOpt.isSome:
    let batch = batchOpt.get()
    self.inFlight[batch.start] = batch.count
  return batchOpt

proc requeueBack*(self: Scheduler, start: uint64, count: uint64) {.inline.} =
  ## requeue batch at back (peer didn't have it, try later).
  self.inFlight.del(start)
  if start < self.completedWatermark:
    return
  if start in self.completedOutOfOrder:
    return
  self.requeued.addLast((start: start, count: count))

proc requeueFront*(self: Scheduler, start: uint64, count: uint64) {.inline.} =
  ## requeue batch at front (failed/timed out, retry soon).
  self.inFlight.del(start)
  if start < self.completedWatermark:
    return
  if start in self.completedOutOfOrder:
    return
  self.requeued.addFirst((start: start, count: count))

proc advanceWatermark(self: Scheduler, batchStart: uint64) =
  if batchStart == self.completedWatermark:
    self.completedWatermark = batchStart + self.batchSize
    while self.completedWatermark in self.completedOutOfOrder:
      self.completedOutOfOrder.excl(self.completedWatermark)
      self.completedWatermark += self.batchSize
  elif batchStart > self.completedWatermark:
    self.completedOutOfOrder.incl(batchStart)

proc findPartialParent(self: Scheduler, start: uint64): Option[uint64] =
  for parent, remaining in self.batchRemaining:
    if start >= parent and start < parent + self.batchSize:
      return some parent
  return none(uint64)

proc onBatchCompleted(self: Scheduler, batchStart: uint64) =
  case self.windowCursor.policy
  of spSequential:
    self.advanceWatermark(batchStart)
  of spRandomWindow:
    discard

proc markComplete*(self: Scheduler, start: uint64) =
  let count = self.inFlight.getOrDefault(start, 0'u64)
  self.inFlight.del(start)

  let parent = self.findPartialParent(start)
  if parent.isSome:
    self.batchRemaining.withValue(parent.get, remaining):
      remaining[] -= count
      if remaining[] <= 0:
        self.batchRemaining.del(parent.get)
        self.onBatchCompleted(parent.get)
    return

  self.onBatchCompleted(start)

proc partialComplete*(
    self: Scheduler, originalStart: uint64, missingRanges: seq[BlockBatch]
) =
  let originalCount = self.inFlight.getOrDefault(originalStart, self.batchSize)
  self.inFlight.del(originalStart)

  var totalMissing: uint64 = 0
  for batch in missingRanges:
    totalMissing += batch.count

  let parent = self.findPartialParent(originalStart)
  if parent.isSome:
    let delivered = originalCount - totalMissing
    self.batchRemaining.withValue(parent.get, remaining):
      remaining[] -= delivered
  else:
    self.batchRemaining[originalStart] = totalMissing

  for i in countdown(missingRanges.len - 1, 0):
    let batch = missingRanges[i]
    self.requeued.addFirst(batch)

proc isEmpty*(self: Scheduler): bool =
  case self.windowCursor.policy
  of spSequential:
    self.completedWatermark >= self.totalBlocks and self.requeued.len == 0 and
      self.inFlight.len == 0
  of spRandomWindow:
    let (start, count) = self.windowCursor.currentWindow()
    self.windowCursor.isDone and self.nextBatchStart >= start + count and
      self.requeued.len == 0 and self.inFlight.len == 0

proc needsNextPresenceWindow*(self: Scheduler): bool =
  case self.windowCursor.policy
  of spSequential:
    let (windowStart, windowCount) = self.windowCursor.currentWindow()
    self.nextBatchStart >= windowStart + windowCount and
      self.windowCursor.needsAdvance(self.completedWatermark)
  of spRandomWindow:
    let (start, count) = self.windowCursor.currentWindow()
    not self.windowCursor.isDone and self.nextBatchStart >= start + count and
      self.requeued.len == 0 and self.inFlight.len == 0

proc advancePresenceWindow*(self: Scheduler): bool =
  if not self.windowCursor.advance():
    return false
  self.nextBatchStart = self.windowCursor.currentWindow().start
  true

proc completedWatermark*(self: Scheduler): uint64 =
  self.completedWatermark

proc hasWork*(self: Scheduler): bool {.inline.} =
  if self.requeued.len > 0:
    return true
  let (start, count) = self.windowCursor.currentWindow()
  if self.nextBatchStart < start + count:
    return true
  self.windowCursor.canAdvance()

proc requeuedCount*(self: Scheduler): int {.inline.} =
  self.requeued.len

proc pending*(self: Scheduler): seq[BlockBatch] =
  var res = newSeqUninit[BlockBatch](self.requeued.len)
  for i, batch in self.requeued:
    res[i] = batch
  return res

proc clear*(self: Scheduler) =
  self.totalBlocks = 0
  self.resetState(0)
  self.windowCursor = WindowCursor(policy: spSequential)

proc totalBlockCount*(self: Scheduler): uint64 =
  self.totalBlocks

proc batchSizeCount*(self: Scheduler): uint64 =
  self.batchSize

iterator completedOutOfOrderItems*(self: Scheduler): uint64 =
  for batchStart in self.completedOutOfOrder:
    yield batchStart

proc batchEnd*(batch: BlockBatch): uint64 =
  batch.start + batch.count

proc contains*(batch: BlockBatch, blockIndex: uint64): bool =
  blockIndex >= batch.start and blockIndex < batch.batchEnd

proc merge*(a, b: BlockBatch): Option[BlockBatch] =
  if a.batchEnd < b.start or b.batchEnd < a.start:
    return none(BlockBatch)

  let
    newStart = min(a.start, b.start)
    newEnd = max(a.batchEnd, b.batchEnd)
  some((start: newStart, count: newEnd - newStart))
