## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos

import ../../units
import ../../storagetypes

const
  # if it hangs longer than this, skip peer and continue
  DefaultWantHaveSendTimeout* = 30.seconds

  # message size limits for protobuf control messages
  MaxMessageSize*: uint32 = 16.MiBs.uint32

  TargetBatchBytes*: uint32 = 1024 * 128
  MinBatchSize*: uint32 = 1

  # caps the number of entries decoded from a single WantList/blockPresences
  # repeated field, independent of MaxMessageSize, to bound per-message CPU/disk work
  MaxWantListEntries*: int = 1024
  MaxBlockPresenceEntries*: int = 1024

  MaxMetadataSize*: uint32 = 4 * 1024 * 1024
  MaxWantBlocksResponseBytes*: uint32 = 4 + MaxMetadataSize + TargetBatchBytes
  MaxBlocksPerBatch*: uint32 = TargetBatchBytes div MinBlockSize.uint32

  # the worst case which is alternating missing blocks (0,2,4...) creates max ranges
  # each range costs 16 bytes (start:u64 + count:u64)
  MaxWantBlocksRequestBytes*: uint32 = (MaxBlocksPerBatch div 2) * 16 + 1024

static:
  doAssert MinBatchSize >= 1, "MinBatchSize must be positive"

  doAssert MaxBlocksPerBatch == TargetBatchBytes div MinBlockSize.uint32,
    "MaxBlocksPerBatch must equal TargetBatchBytes / MinBlockSize"

  doAssert MaxWantBlocksResponseBytes == 4 + MaxMetadataSize + TargetBatchBytes,
    "MaxWantBlocksResponseBytes must equal 4 + MaxMetadataSize + TargetBatchBytes"

  # should fit worst case sparse batch - max ranges
  const
    worstCaseRanges = MaxBlocksPerBatch div 2
    worstCaseRangeBytes = worstCaseRanges * 16
    fixedOverhead = 64'u32 # request id + cidLen + cid + rangeCount
  doAssert MaxWantBlocksRequestBytes >= worstCaseRangeBytes + fixedOverhead,
    "MaxWantBlocksRequestBytes too small for worst case sparse batch"
