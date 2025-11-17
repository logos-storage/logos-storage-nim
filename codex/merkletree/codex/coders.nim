## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/serde/json

import ../../units
import ../../errors

import ./codex

const MaxMerkleTreeSize = 100.MiBs.uint
const MaxMerkleProofSize = 1.MiBs.uint

proc encode*(self: CodexTree): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, self.mcodec.uint64)
  pb.write(2, self.leavesCount.uint64)
  for node in self.nodes:
    var nodesPb = initProtoBuffer()
    nodesPb.write(1, node)
    nodesPb.finish()
    pb.write(3, nodesPb)

  pb.finish
  pb.buffer

proc decode*(_: type CodexTree, data: seq[byte]): ?!CodexTree =
  var pb = initProtoBuffer(data)
  var mcodecCode: uint64
  var leavesCount: uint64
  discard ?pb.getField(1, mcodecCode).mapFailure
  discard ?pb.getField(2, leavesCount).mapFailure

  let mcodec = MultiCodec.codec(mcodecCode.int)
  if mcodec == InvalidMultiCodec:
    return failure("Invalid MultiCodec code " & $mcodecCode)

  var
    nodesBuff: seq[seq[byte]]
    nodes: seq[ByteHash]

  if ?pb.getRepeatedField(3, nodesBuff).mapFailure:
    for nodeBuff in nodesBuff:
      var node: ByteHash
      discard ?initProtoBuffer(nodeBuff).getField(1, node).mapFailure
      nodes.add node

  CodexTree.fromNodes(mcodec, nodes, leavesCount.int)

proc encode*(self: CodexProof): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, self.mcodec.uint64)
  pb.write(2, self.index.uint64)
  pb.write(3, self.nleaves.uint64)

  for node in self.path:
    var nodesPb = initProtoBuffer()
    nodesPb.write(1, node)
    nodesPb.finish()
    pb.write(4, nodesPb)

  pb.finish
  pb.buffer

proc decode*(_: type CodexProof, data: seq[byte]): ?!CodexProof =
  var pb = initProtoBuffer(data)
  var mcodecCode: uint64
  var index: uint64
  var nleaves: uint64
  discard ?pb.getField(1, mcodecCode).mapFailure

  let mcodec = MultiCodec.codec(mcodecCode.int)
  if mcodec == InvalidMultiCodec:
    return failure("Invalid MultiCodec code " & $mcodecCode)

  discard ?pb.getField(2, index).mapFailure
  discard ?pb.getField(3, nleaves).mapFailure

  var
    nodesBuff: seq[seq[byte]]
    nodes: seq[ByteHash]

  if ?pb.getRepeatedField(4, nodesBuff).mapFailure:
    for nodeBuff in nodesBuff:
      var node: ByteHash
      let nodePb = initProtoBuffer(nodeBuff)
      discard ?nodePb.getField(1, node).mapFailure
      nodes.add node

  CodexProof.init(mcodec, index.int, nleaves.int, nodes)

proc fromJson*(_: type CodexProof, json: JsonNode): ?!CodexProof =
  expectJsonKind(Cid, JString, json)
  var bytes: seq[byte]
  try:
    bytes = hexToSeqByte(json.str)
  except ValueError as err:
    return failure(err)

  CodexProof.decode(bytes)

func `%`*(proof: CodexProof): JsonNode =
  %byteutils.toHex(proof.encode())
