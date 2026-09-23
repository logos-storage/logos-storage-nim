## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/multicodec
import pkg/stew/endians2
import pkg/results

import ../../blocktype
import ../../merkletree
import ../../logutils
import ../../errors
import ./message
import ./constants

export message, results, errors

logScope:
  topics = "storage wantblocks"

const
  SizeRequestId = sizeof(uint64)
  SizeCidLen = sizeof(uint16)
  SizeRangeCount = sizeof(uint32)
  SizeRange = sizeof(uint64) + sizeof(uint64) # start + count
  SizeBlockCount = sizeof(uint32)
  SizeBlockIndex = sizeof(uint64)
  SizeDataLen = sizeof(uint32)
  SizeProofLen = sizeof(uint16)
  SizeNodeLen = sizeof(uint16)
  SizeMcodec = sizeof(uint64)
  SizeNleaves = sizeof(uint64)
  SizePathCount = sizeof(uint32)
  SizeProofHeader = SizeMcodec + SizeBlockIndex + SizeNleaves + SizePathCount
  SizeMetaLen = sizeof(uint32)
  MaxMerkleProofDepth = 64

type
  MessageType* = enum
    mtProtobuf = 0x00 # Protobuf control messages (want lists, presence)
    mtWantBlocksRequest = 0x01 # WantBlocks request
    mtWantBlocksResponse = 0x02 # WantBlocks response

  WantBlocksRequest* = object
    requestId*: uint64
    treeCid*: Cid
    ranges*: seq[IndexRange]

  SharedBlocksBuffer* = ref object
    data*: seq[byte]

  BlockEntry* = object
    index*: uint64
    cid*: Cid
    dataOffset*: int
    dataLen*: int
    proof*: StorageMerkleProof

  WantBlocksResponse* = object
    requestId*: uint64 # echoed request ID
    treeCid*: Cid
    blocks*: seq[BlockEntry]
    sharedBuffer*: SharedBlocksBuffer

  BlockDeliveryView* = object
    cid*: Cid
    address*: BlockAddress
    proof*: Option[StorageMerkleProof]
    sharedBuf*: SharedBlocksBuffer
    dataOffset*: int
    dataLen*: int

  BlockMetadata =
    tuple[index: uint64, cid: Cid, dataLen: uint32, proof: Option[StorageMerkleProof]]

proc frameProtobufMessage*(data: openArray[byte]): seq[byte] =
  let frameLen = (1 + data.len).uint32
  var buf = newSeqUninit[byte](4 + frameLen.int)
  let frameLenLE = frameLen.toLE
  copyMem(addr buf[0], unsafeAddr frameLenLE, 4)
  buf[4] = mtProtobuf.byte
  if data.len > 0:
    copyMem(addr buf[5], unsafeAddr data[0], data.len)
  buf

proc decodeProofBinary*(data: openArray[byte]): WantBlocksResult[StorageMerkleProof] =
  if data.len < SizeProofHeader:
    return err(wantBlocksError(ProofTooShort, "Proof data too short"))

  var offset = 0

  let
    mcodecVal = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
    mcodec = MultiCodec.codec(mcodecVal.int)

  if mcodec == InvalidMultiCodec:
    return err(wantBlocksError(InvalidCodec, "Invalid MultiCodec: " & $mcodecVal))
  offset += 8

  let index = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian).int
  offset += 8

  let nleaves = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian).int
  offset += 8

  let pathCount =
    uint32.fromBytes(data.toOpenArray(offset, offset + 3), littleEndian).int
  offset += 4

  if pathCount > MaxMerkleProofDepth:
    return err(
      wantBlocksError(ProofPathTooLarge, "Proof path count too large: " & $pathCount)
    )

  var nodes = newSeq[seq[byte]](pathCount)
  for i in 0 ..< pathCount:
    if offset + SizeNodeLen > data.len:
      return err(wantBlocksError(ProofTruncated, "Proof truncated at node " & $i))
    let nodeLen =
      uint16.fromBytes(data.toOpenArray(offset, offset + 1), littleEndian).int
    offset += 2
    if offset + nodeLen > data.len:
      return err(wantBlocksError(ProofTruncated, "Proof truncated at node data " & $i))
    if nodeLen == 0:
      nodes[i] = @[]
    else:
      nodes[i] = @(data.toOpenArray(offset, offset + nodeLen - 1))
    offset += nodeLen

  ok(
    ?StorageMerkleProof.init(mcodec, index, nleaves, nodes).mapErr(
      proc(e: auto): ref WantBlocksError =
        wantBlocksError(ProofCreationFailed, "Failed to create proof: " & e.msg)
    )
  )

proc calcRequestSize*(req: WantBlocksRequest): int {.inline.} =
  let cidBytes = req.treeCid.data.buffer
  SizeRequestId + SizeCidLen + cidBytes.len + SizeRangeCount +
    (req.ranges.len * SizeRange)

proc encodeRequestInto*(
    req: WantBlocksRequest, buf: var openArray[byte], startOffset: int
): int =
  var offset = startOffset

  let reqIdLE = req.requestId.toLE
  copyMem(addr buf[offset], unsafeAddr reqIdLE, 8)
  offset += 8

  let
    cidBytes = req.treeCid.data.buffer
    cidLenLE = cidBytes.len.uint16.toLE
  copyMem(addr buf[offset], unsafeAddr cidLenLE, 2)
  offset += 2

  if cidBytes.len > 0:
    copyMem(addr buf[offset], unsafeAddr cidBytes[0], cidBytes.len)
    offset += cidBytes.len

  let rangeCountLE = req.ranges.len.uint32.toLE
  copyMem(addr buf[offset], unsafeAddr rangeCountLE, 4)
  offset += 4

  for r in req.ranges:
    let startLE = r.start.toLE
    copyMem(addr buf[offset], unsafeAddr startLE, 8)
    offset += 8
    let countLE = r.count.toLE
    copyMem(addr buf[offset], unsafeAddr countLE, 8)
    offset += 8

  return offset - startOffset

proc decodeRequest*(data: openArray[byte]): WantBlocksResult[WantBlocksRequest] =
  if data.len < SizeRequestId + SizeCidLen + SizeRangeCount:
    return err(wantBlocksError(RequestTooShort, "Request too short"))

  var offset = 0

  let requestId = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
  offset += 8

  let cidLen = uint16.fromBytes(data.toOpenArray(offset, offset + 1), littleEndian).int
  offset += 2

  if cidLen == 0:
    return err(wantBlocksError(InvalidCid, "CID length is zero"))

  if offset + cidLen + SizeRangeCount > data.len:
    return err(wantBlocksError(RequestTruncated, "Request truncated (CID)"))

  let treeCid = ?Cid.init(data.toOpenArray(offset, offset + cidLen - 1)).mapErr(
    proc(e: auto): ref WantBlocksError =
      wantBlocksError(InvalidCid, "Invalid CID: " & $e)
  )
  offset += cidLen

  let rangeCount =
    uint32.fromBytes(data.toOpenArray(offset, offset + 3), littleEndian).int
  offset += 4

  if offset + (rangeCount * SizeRange) > data.len:
    return err(wantBlocksError(RequestTruncated, "Request truncated (ranges)"))

  var ranges = newSeqOfCap[IndexRange](rangeCount)
  for _ in 0 ..< rangeCount:
    let start = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
    offset += 8
    let count = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
    offset += 8
    ranges.add(IndexRange(start: start, count: count))

  ok(WantBlocksRequest(requestId: requestId, treeCid: treeCid, ranges: ranges))

proc calcProofBinarySize*(proof: StorageMerkleProof): int {.inline.} =
  result = SizeProofHeader
  for node in proof.path:
    result += SizeNodeLen + node.len

proc calcResponseMetadataSize*(treeCid: Cid, blocks: seq[BlockDelivery]): int =
  let treeCidBytes = treeCid.data.buffer
  result = SizeRequestId + SizeCidLen + treeCidBytes.len + SizeBlockCount

  for bd in blocks:
    let blockCidBytes = bd.blk.cid.data.buffer
    result +=
      SizeBlockIndex + SizeCidLen + blockCidBytes.len + SizeDataLen + SizeProofLen
    if bd.proof.isSome:
      result += calcProofBinarySize(bd.proof.get)

proc encodeProofBinaryInto*(
    proof: StorageMerkleProof, buf: var openArray[byte], startOffset: int
): int =
  var offset = startOffset

  let mcodecLE = proof.mcodec.uint64.toLE
  copyMem(addr buf[offset], unsafeAddr mcodecLE, 8)
  offset += 8

  let indexLE = proof.index.uint64.toLE
  copyMem(addr buf[offset], unsafeAddr indexLE, 8)
  offset += 8

  let nleavesLE = proof.nleaves.uint64.toLE
  copyMem(addr buf[offset], unsafeAddr nleavesLE, 8)
  offset += 8

  let pathCountLE = proof.path.len.uint32.toLE
  copyMem(addr buf[offset], unsafeAddr pathCountLE, 4)
  offset += 4

  for node in proof.path:
    let nodeLenLE = node.len.uint16.toLE
    copyMem(addr buf[offset], unsafeAddr nodeLenLE, 2)
    offset += 2
    if node.len > 0:
      copyMem(addr buf[offset], unsafeAddr node[0], node.len)
      offset += node.len

  return offset - startOffset

proc encodeResponseMetadataInto*(
    requestId: uint64,
    treeCid: Cid,
    blocks: seq[BlockDelivery],
    buf: var openArray[byte],
    startOffset: int,
): int =
  var offset = startOffset

  let reqIdLE = requestId.toLE
  copyMem(addr buf[offset], unsafeAddr reqIdLE, 8)
  offset += 8

  let
    treeCidBytes = treeCid.data.buffer
    treeCidLenLE = treeCidBytes.len.uint16.toLE
  copyMem(addr buf[offset], unsafeAddr treeCidLenLE, 2)
  offset += 2

  if treeCidBytes.len > 0:
    copyMem(addr buf[offset], unsafeAddr treeCidBytes[0], treeCidBytes.len)
    offset += treeCidBytes.len

  let blockCountLE = blocks.len.uint32.toLE
  copyMem(addr buf[offset], unsafeAddr blockCountLE, 4)
  offset += 4

  for bd in blocks:
    let
      index = uint64(bd.address.index)
      indexLE = index.toLE
    copyMem(addr buf[offset], unsafeAddr indexLE, 8)
    offset += 8

    let
      blockCidBytes = bd.blk.cid.data.buffer
      blockCidLenLE = blockCidBytes.len.uint16.toLE
    copyMem(addr buf[offset], unsafeAddr blockCidLenLE, 2)
    offset += 2

    if blockCidBytes.len > 0:
      copyMem(addr buf[offset], unsafeAddr blockCidBytes[0], blockCidBytes.len)
      offset += blockCidBytes.len

    let dataLenLE = bd.blk.data[].len.uint32.toLE
    copyMem(addr buf[offset], unsafeAddr dataLenLE, 4)
    offset += 4

    if bd.proof.isSome:
      let
        proofSize = calcProofBinarySize(bd.proof.get)
        proofLenLE = proofSize.uint16.toLE
      copyMem(addr buf[offset], unsafeAddr proofLenLE, 2)
      offset += 2
      offset += encodeProofBinaryInto(bd.proof.get, buf, offset)
    else:
      let zeroLE = 0'u16.toLE
      copyMem(addr buf[offset], unsafeAddr zeroLE, 2)
      offset += 2

  return offset - startOffset

proc decodeResponseMetadata(
    data: openArray[byte]
): WantBlocksResult[(uint64, Cid, seq[BlockMetadata])] =
  if data.len < SizeRequestId + SizeCidLen + SizeBlockCount:
    return err(wantBlocksError(MetadataTooShort, "Metadata too short"))

  var offset = 0
  let requestId = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
  offset += 8

  let cidLen = uint16.fromBytes(data.toOpenArray(offset, offset + 1), littleEndian).int
  offset += 2

  if cidLen == 0:
    return err(wantBlocksError(InvalidCid, "Tree CID length is zero"))

  if offset + cidLen + SizeBlockCount > data.len:
    return err(wantBlocksError(MetadataTruncated, "Metadata truncated at CID"))

  let treeCid = ?Cid.init(data.toOpenArray(offset, offset + cidLen - 1)).mapErr(
    proc(e: auto): ref WantBlocksError =
      wantBlocksError(InvalidCid, "Invalid CID: " & $e)
  )
  offset += cidLen

  let blockCount = uint32.fromBytes(data.toOpenArray(offset, offset + 3), littleEndian)
  offset += 4

  if blockCount > MaxBlocksPerBatch:
    return err(
      wantBlocksError(
        TooManyBlocks,
        "Block count " & $blockCount & " exceeds maximum " & $MaxBlocksPerBatch,
      )
    )

  var blocksMeta = newSeq[BlockMetadata](blockCount.int)
  for i in 0 ..< blockCount:
    if offset + SizeBlockIndex > data.len:
      return
        err(wantBlocksError(MetadataTruncated, "Metadata truncated at block " & $i))

    let index = uint64.fromBytes(data.toOpenArray(offset, offset + 7), littleEndian)
    offset += 8

    if offset + SizeCidLen > data.len:
      return err(
        wantBlocksError(MetadataTruncated, "Metadata truncated at block cidLen " & $i)
      )
    let blockCidLen =
      uint16.fromBytes(data.toOpenArray(offset, offset + 1), littleEndian).int
    offset += 2
    if blockCidLen == 0:
      return err(wantBlocksError(InvalidCid, "Block CID length is zero at block " & $i))
    if offset + blockCidLen > data.len:
      return
        err(wantBlocksError(MetadataTruncated, "Metadata truncated at block CID " & $i))
    let blockCid = ?Cid.init(data.toOpenArray(offset, offset + blockCidLen - 1)).mapErr(
      proc(e: auto): ref WantBlocksError =
        wantBlocksError(InvalidCid, "Invalid block CID at " & $i & ": " & $e)
    )
    offset += blockCidLen

    if offset + SizeDataLen > data.len:
      return
        err(wantBlocksError(MetadataTruncated, "Metadata truncated at dataLen " & $i))
    let dataLen = uint32.fromBytes(data.toOpenArray(offset, offset + 3), littleEndian)
    offset += 4

    if dataLen > MaxBlockSize.uint32:
      return err(
        wantBlocksError(
          DataSizeMismatch,
          "Block dataLen exceeds MaxBlockSize at " & $i & ": " & $dataLen,
        )
      )

    if offset + SizeProofLen > data.len:
      return
        err(wantBlocksError(MetadataTruncated, "Metadata truncated at proofLen " & $i))
    let proofLen =
      uint16.fromBytes(data.toOpenArray(offset, offset + 1), littleEndian).int
    offset += 2

    var proof: Option[StorageMerkleProof] = none(StorageMerkleProof)
    if proofLen > 0:
      if offset + proofLen > data.len:
        return
          err(wantBlocksError(MetadataTruncated, "Metadata truncated at proof " & $i))
      let proofResult =
        decodeProofBinary(data.toOpenArray(offset, offset + proofLen - 1))
      if proofResult.isErr:
        return err(
          wantBlocksError(
            ProofDecodeFailed,
            "Failed to decode proof at block " & $i & ": " & proofResult.error.msg,
          )
        )
      proof = some(proofResult.get)
      offset += proofLen

    blocksMeta[i] = (index: index, cid: blockCid, dataLen: dataLen, proof: proof)

  ok((requestId, treeCid, blocksMeta))

proc writeWantBlocksResponse*(
    conn: Connection, requestId: uint64, treeCid: Cid, blocks: seq[BlockDelivery]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let metaSize = calcResponseMetadataSize(treeCid, blocks)
  if metaSize > MaxMetadataSize.int:
    warn "Metadata exceeds limit, skipping response",
      metaSize = metaSize, limit = MaxMetadataSize, blockCount = blocks.len
    return

  var totalDataSize: uint64 = 0
  for bd in blocks:
    totalDataSize += bd.blk.data[].len.uint64

  let contentSize = SizeMetaLen.uint64 + metaSize.uint64 + totalDataSize
  if contentSize > MaxWantBlocksResponseBytes:
    warn "Response exceeds size limit, skipping",
      contentSize = contentSize,
      limit = MaxWantBlocksResponseBytes,
      blockCount = blocks.len
    return

  let
    frameLen = 1 + contentSize.int
    totalSize = 4 + frameLen

  var
    buf = newSeqUninit[byte](totalSize)
    offset = 0

  let frameLenLE = frameLen.uint32.toLE
  copyMem(addr buf[offset], unsafeAddr frameLenLE, 4)
  offset += 4

  buf[offset] = mtWantBlocksResponse.byte
  offset += 1

  let metaSizeLE = metaSize.uint32.toLE
  copyMem(addr buf[offset], unsafeAddr metaSizeLE, 4)
  offset += 4

  offset += encodeResponseMetadataInto(requestId, treeCid, blocks, buf, offset)

  for bd in blocks:
    if bd.blk.data[].len > 0:
      copyMem(addr buf[offset], unsafeAddr bd.blk.data[][0], bd.blk.data[].len)
      offset += bd.blk.data[].len

  trace "Sending WantBlocks response",
    peer = conn.peerId,
    treeCid = treeCid,
    blockCount = blocks.len,
    totalDataSize = totalDataSize
  await conn.write(buf)
  trace "WantBlocks response sent",
    peer = conn.peerId,
    treeCid = treeCid,
    blockCount = blocks.len,
    totalDataSize = totalDataSize

proc writeWantBlocksRequest*(
    conn: Connection, req: WantBlocksRequest
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let
    reqSize = calcRequestSize(req)
    totalSize = 4 + 1 + reqSize
  var buf = newSeqUninit[byte](totalSize)

  let frameLenLE = (1 + reqSize).uint32.toLE
  copyMem(addr buf[0], unsafeAddr frameLenLE, 4)

  buf[4] = mtWantBlocksRequest.byte
  discard encodeRequestInto(req, buf, 5)
  await conn.write(buf)

proc readWantBlocksResponse*(
    conn: Connection, dataLen: int
): Future[WantBlocksResult[WantBlocksResponse]] {.async: (raises: [CancelledError]).} =
  try:
    let totalLen = dataLen.uint32

    if totalLen > MaxWantBlocksResponseBytes:
      return err(wantBlocksError(ResponseTooLarge, "Response too large: " & $totalLen))

    var lenBuf: array[4, byte]
    await conn.readExactly(addr lenBuf[0], 4)
    let metaLen = uint32.fromBytes(lenBuf, littleEndian)

    if metaLen > MaxMetadataSize:
      return err(wantBlocksError(MetadataTooLarge, "Metadata too large: " & $metaLen))

    var metaBuf = newSeqUninit[byte](metaLen.int)
    if metaLen > 0:
      await conn.readExactly(addr metaBuf[0], metaLen.int)

    let (requestId, treeCid, blocksMeta) = ?decodeResponseMetadata(metaBuf)

    var totalDataSize: uint64 = 0
    for bm in blocksMeta:
      totalDataSize += bm.dataLen.uint64

    if totalLen < SizeMetaLen.uint32 + metaLen:
      return err(
        wantBlocksError(
          DataSizeMismatch,
          "Invalid lengths: totalLen=" & $totalLen & " metaLen=" & $metaLen,
        )
      )

    let dataLen = totalLen - SizeMetaLen.uint32 - metaLen
    if dataLen.uint64 != totalDataSize:
      return err(
        wantBlocksError(
          DataSizeMismatch,
          "Data size mismatch: expected " & $totalDataSize & ", got " & $dataLen,
        )
      )

    var sharedBuf = SharedBlocksBuffer(data: newSeqUninit[byte](totalDataSize.int))

    if totalDataSize > 0:
      await conn.readExactly(addr sharedBuf.data[0], totalDataSize.int)

    var response: WantBlocksResponse
    response.requestId = requestId
    response.treeCid = treeCid
    response.sharedBuffer = sharedBuf
    response.blocks = newSeq[BlockEntry](blocksMeta.len)

    var offset = 0
    for i, bm in blocksMeta:
      let blockDataLen = bm.dataLen.int

      var proof: StorageMerkleProof
      if bm.proof.isSome:
        proof = bm.proof.get
      response.blocks[i] = BlockEntry(
        index: bm.index,
        cid: bm.cid,
        dataOffset: offset,
        dataLen: blockDataLen,
        proof: proof,
      )
      offset += blockDataLen

    return ok(response)
  except LPStreamError as e:
    return err(wantBlocksError(RequestFailed, e.msg))

proc readWantBlocksRequest*(
    conn: Connection, dataLen: int
): Future[WantBlocksResult[WantBlocksRequest]] {.async: (raises: [CancelledError]).} =
  try:
    if dataLen.uint32 > MaxWantBlocksRequestBytes:
      return err(wantBlocksError(RequestTooLarge, "Request too large: " & $dataLen))

    var reqBuf = newSeqUninit[byte](dataLen)
    if dataLen > 0:
      await conn.readExactly(addr reqBuf[0], dataLen)

    return decodeRequest(reqBuf)
  except LPStreamError as e:
    return err(wantBlocksError(RequestFailed, e.msg))

proc toBlockDeliveryView*(
    entry: BlockEntry, treeCid: Cid, sharedBuf: SharedBlocksBuffer
): WantBlocksResult[BlockDeliveryView] =
  if entry.dataOffset < 0 or entry.dataLen < 0:
    return err(
      wantBlocksError(
        DataSizeMismatch,
        "Invalid offset or length: offset=" & $entry.dataOffset & " len=" &
          $entry.dataLen,
      )
    )

  if entry.dataOffset + entry.dataLen > sharedBuf.data.len:
    return err(
      wantBlocksError(
        DataSizeMismatch,
        "Block data exceeds buffer: offset=" & $entry.dataOffset & " len=" &
          $entry.dataLen & " bufLen=" & $sharedBuf.data.len,
      )
    )

  ok(
    BlockDeliveryView(
      cid: entry.cid,
      address: BlockAddress(treeCid: treeCid, index: entry.index),
      proof: some(entry.proof),
      sharedBuf: sharedBuf,
      dataOffset: entry.dataOffset,
      dataLen: entry.dataLen,
    )
  )

proc toBlockDelivery*(view: BlockDeliveryView): BlockDelivery =
  var data = newSeqUninit[byte](view.dataLen)
  if view.dataLen > 0:
    copyMem(addr data[0], unsafeAddr view.sharedBuf.data[view.dataOffset], view.dataLen)

  var dataRef: ref seq[byte]
  new(dataRef)
  dataRef[] = move(data)

  BlockDelivery(
    blk: Block(cid: view.cid, data: dataRef), address: view.address, proof: view.proof
  )
