## Logos Storage
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/sequtils

import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/protobuf_serialization
import pkg/results
import pkg/stew/byteutils
import pkg/serde/json

import ../units
import ./merkletree

const MaxMerkleTreeSize = 100.MiBs.uint
const MaxMerkleProofSize = 1.MiBs.uint

type
  MerkleNode {.proto2.} = object
    node {.fieldNumber: 1, required.}: seq[byte]

  MerkleTreeMessage {.proto2.} = object
    mcodec {.fieldNumber: 1, required, pint.}: uint64
    leavesCount {.fieldNumber: 2, required, pint.}: uint64
    nodes {.fieldNumber: 3.}: seq[MerkleNode]

  MerkleProofMessage {.proto2.} = object
    mcodec {.fieldNumber: 1, required, pint.}: uint64
    index {.fieldNumber: 2, required, pint.}: uint64
    nleaves {.fieldNumber: 3, required, pint.}: uint64
    path {.fieldNumber: 4.}: seq[MerkleNode]

proc decodeTreeMessage(
    data: seq[byte]
): MerkleTreeMessage {.raises: [SerializationError].} =
  decode(Protobuf, data, MerkleTreeMessage)

proc decodeProofMessage(
    data: seq[byte]
): MerkleProofMessage {.raises: [SerializationError].} =
  decode(Protobuf, data, MerkleProofMessage)

proc encode*(self: StorageMerkleTree): seq[byte] =
  var nodes: seq[MerkleNode]
  for node in self.nodes:
    nodes.add(MerkleNode(node: node))

  encode(
    Protobuf,
    MerkleTreeMessage(
      mcodec: self.mcodec.uint64, leavesCount: self.leavesCount.uint64, nodes: nodes
    ),
  )

proc decode*(
    _: type StorageMerkleTree, data: seq[byte]
): Result[StorageMerkleTree, ref CatchableError] =
  let message =
    try:
      decodeTreeMessage(data)
    except SerializationError as exc:
      return err(exc)

  let mcodec = MultiCodec.codec(message.mcodec.int)
  if mcodec == InvalidMultiCodec:
    return
      err(newException(CatchableError, "Invalid MultiCodec code " & $message.mcodec))

  StorageMerkleTree.fromNodes(
    mcodec, message.nodes.mapIt(it.node), message.leavesCount.int
  )

proc encode*(self: StorageMerkleProof): seq[byte] =
  encode(
    Protobuf,
    MerkleProofMessage(
      mcodec: self.mcodec.uint64,
      index: self.index.uint64,
      nleaves: self.nleaves.uint64,
      path: self.path.mapIt(MerkleNode(node: it)),
    ),
  )

proc decode*(
    _: type StorageMerkleProof, data: seq[byte]
): Result[StorageMerkleProof, ref CatchableError] =
  let message =
    try:
      decodeProofMessage(data)
    except SerializationError as exc:
      return err(exc)

  let mcodec = MultiCodec.codec(message.mcodec.int)
  if mcodec == InvalidMultiCodec:
    return
      err(newException(CatchableError, "Invalid MultiCodec code " & $message.mcodec))

  StorageMerkleProof.init(
    mcodec, message.index.int, message.nleaves.int, message.path.mapIt(it.node)
  )

proc fromJson*(
    _: type StorageMerkleProof, json: JsonNode
): Result[StorageMerkleProof, ref CatchableError] =
  expectJsonKind(Cid, JString, json)
  var bytes: seq[byte]
  try:
    bytes = hexToSeqByte(json.str)
  except ValueError as exc:
    return err(exc)

  StorageMerkleProof.decode(bytes)

func `%`*(proof: StorageMerkleProof): JsonNode =
  %byteutils.toHex(proof.encode())
