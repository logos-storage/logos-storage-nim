## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/algorithm

import pkg/libp2p/cid

import ./protocol/message

type
  BlockRange* = object
    treeCid*: Cid
    ranges*: seq[IndexRange]

  BlockAvailabilityKind* = enum
    bakUnknown
    bakComplete
    bakRanges
    bakBitmap

  BlockAvailability* = object
    case kind*: BlockAvailabilityKind
    of bakUnknown:
      discard
    of bakComplete:
      discard
    of bakRanges:
      ranges*: seq[IndexRange]
    of bakBitmap:
      bitmap*: seq[byte]
      totalBlocks*: uint64

proc unknown*(_: type BlockAvailability): BlockAvailability =
  BlockAvailability(kind: bakUnknown)

proc complete*(_: type BlockAvailability): BlockAvailability =
  BlockAvailability(kind: bakComplete)

proc fromRanges*(
    _: type BlockAvailability, ranges: seq[IndexRange]
): BlockAvailability =
  if ranges.len == 0:
    return BlockAvailability.unknown()

  BlockAvailability(kind: bakRanges, ranges: ranges)

proc fromBitmap*(
    _: type BlockAvailability, bitmap: seq[byte], totalBlocks: uint64
): BlockAvailability =
  BlockAvailability(kind: bakBitmap, bitmap: bitmap, totalBlocks: totalBlocks)

proc hasBlock*(avail: BlockAvailability, index: uint64): bool =
  case avail.kind
  of bakUnknown:
    false
  of bakComplete:
    true
  of bakRanges:
    for r in avail.ranges:
      if r.count > high(uint64) - r.start:
        continue
      if index >= r.start and index < r.start + r.count:
        return true
    false
  of bakBitmap:
    if index >= avail.totalBlocks:
      return false
    let
      byteIdx = index div 8
      bitIdx = index mod 8
    if byteIdx.int >= avail.bitmap.len:
      return false
    (avail.bitmap[byteIdx] and (1'u8 shl bitIdx)) != 0

proc hasRange*(avail: BlockAvailability, start: uint64, count: uint64): bool =
  if count > high(uint64) - start:
    return false

  case avail.kind
  of bakUnknown:
    false
  of bakComplete:
    true
  of bakRanges:
    let reqEnd = start + count
    for r in avail.ranges:
      if r.count > high(uint64) - r.start:
        continue
      let rangeEnd = r.start + r.count
      if start >= r.start and reqEnd <= rangeEnd:
        return true
    false
  of bakBitmap:
    for i in start ..< start + count:
      if not avail.hasBlock(i):
        return false
    true

proc hasAnyInRange*(avail: BlockAvailability, start: uint64, count: uint64): bool =
  if count > high(uint64) - start:
    return false

  case avail.kind
  of bakUnknown:
    false
  of bakComplete:
    true
  of bakRanges:
    let reqEnd = start + count
    for r in avail.ranges:
      if r.count > high(uint64) - r.start:
        continue
      let rangeEnd = r.start + r.count
      # check if they overlap
      if start < rangeEnd and r.start < reqEnd:
        return true
    false
  of bakBitmap:
    for i in start ..< start + count:
      if avail.hasBlock(i):
        return true
    false

proc mergeRanges(ranges: seq[IndexRange]): seq[IndexRange] =
  if ranges.len == 0:
    return @[]

  var sorted = ranges
  sorted.sort(
    proc(a, b: IndexRange): int =
      if a.start < b.start:
        -1
      elif a.start > b.start:
        1
      else:
        0
  )

  result = @[]
  var current = sorted[0]
  if current.count > high(uint64) - current.start:
    return @[]

  for i in 1 ..< sorted.len:
    let next = sorted[i]
    if next.count > high(uint64) - next.start:
      continue #cnanakos: warn??
    let currentEnd = current.start + current.count
    if next.start <= currentEnd:
      let nextEnd = next.start + next.count
      if nextEnd > currentEnd:
        current.count = nextEnd - current.start
    else:
      result.add(current)
      current = next

  result.add(current)

proc merge*(current: BlockAvailability, other: BlockAvailability): BlockAvailability =
  ## merge by keeping the union of all known blocks
  if current.kind == bakComplete or other.kind == bakComplete:
    return BlockAvailability.complete()

  if current.kind == bakUnknown:
    return other

  if other.kind == bakUnknown:
    return current

  proc bitmapToRanges(avail: BlockAvailability): seq[IndexRange] =
    result = @[]
    var
      inRange = false
      rangeStart: uint64 = 0
    for i in 0'u64 ..< avail.totalBlocks:
      let hasIt = avail.hasBlock(i)
      if hasIt and not inRange:
        rangeStart = i
        inRange = true
      elif not hasIt and inRange:
        result.add(IndexRange(start: rangeStart, count: i - rangeStart))
        inRange = false
    if inRange:
      result.add(IndexRange(start: rangeStart, count: avail.totalBlocks - rangeStart))

  let currentRanges =
    if current.kind == bakRanges:
      current.ranges
    else:
      bitmapToRanges(current)
  let otherRanges =
    if other.kind == bakRanges:
      other.ranges
    else:
      bitmapToRanges(other)

  return BlockAvailability.fromRanges(mergeRanges(currentRanges & otherRanges))
