import std/sequtils

import pkg/unittest2
import pkg/results
import pkg/storage/merkletree
import pkg/storage/storagetypes

## All Expected_* consts are the minprotobuf encoding of the merkle tree and
## proof, the format of the proofs stored in the repo store.
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY any of the Expected_* consts. If tests are failing after
## touching coders.nim, the protobuf library or anything else in the encode
## path, the format has diverged from the proofs already stored on disk.

const Expected_tree = @[
  0x08'u8, 0x12'u8, 0x10'u8, 0x02'u8, 0x1A'u8, 0x22'u8, 0x0A'u8, 0x20'u8, 0x00'u8,
  0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8,
  0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8,
  0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8,
  0x1C'u8, 0x1D'u8, 0x1E'u8, 0x1F'u8, 0x1A'u8, 0x22'u8, 0x0A'u8, 0x20'u8, 0x20'u8,
  0x21'u8, 0x22'u8, 0x23'u8, 0x24'u8, 0x25'u8, 0x26'u8, 0x27'u8, 0x28'u8, 0x29'u8,
  0x2A'u8, 0x2B'u8, 0x2C'u8, 0x2D'u8, 0x2E'u8, 0x2F'u8, 0x30'u8, 0x31'u8, 0x32'u8,
  0x33'u8, 0x34'u8, 0x35'u8, 0x36'u8, 0x37'u8, 0x38'u8, 0x39'u8, 0x3A'u8, 0x3B'u8,
  0x3C'u8, 0x3D'u8, 0x3E'u8, 0x3F'u8, 0x1A'u8, 0x22'u8, 0x0A'u8, 0x20'u8, 0x06'u8,
  0x3F'u8, 0x0E'u8, 0x4E'u8, 0x60'u8, 0x60'u8, 0xA8'u8, 0x7E'u8, 0x91'u8, 0x41'u8,
  0xD2'u8, 0xB0'u8, 0x80'u8, 0x08'u8, 0x5D'u8, 0x37'u8, 0x31'u8, 0x0E'u8, 0x0C'u8,
  0xCD'u8, 0xC3'u8, 0x3C'u8, 0x98'u8, 0x23'u8, 0x9C'u8, 0xC1'u8, 0xDA'u8, 0x89'u8,
  0xA9'u8, 0xDB'u8, 0xEA'u8, 0xAE'u8,
]

const Expected_proofZeroIndex = @[
  0x08'u8, 0x12'u8, 0x10'u8, 0x00'u8, 0x18'u8, 0x02'u8, 0x22'u8, 0x22'u8, 0x0A'u8,
  0x20'u8, 0x20'u8, 0x21'u8, 0x22'u8, 0x23'u8, 0x24'u8, 0x25'u8, 0x26'u8, 0x27'u8,
  0x28'u8, 0x29'u8, 0x2A'u8, 0x2B'u8, 0x2C'u8, 0x2D'u8, 0x2E'u8, 0x2F'u8, 0x30'u8,
  0x31'u8, 0x32'u8, 0x33'u8, 0x34'u8, 0x35'u8, 0x36'u8, 0x37'u8, 0x38'u8, 0x39'u8,
  0x3A'u8, 0x3B'u8, 0x3C'u8, 0x3D'u8, 0x3E'u8, 0x3F'u8,
]

const Expected_proofMultiByteVarints = @[
  0x08'u8, 0x12'u8, 0x10'u8, 0xAB'u8, 0x02'u8, 0x18'u8, 0xAC'u8, 0x02'u8, 0x22'u8,
  0x22'u8, 0x0A'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0x1F'u8, 0x22'u8,
  0x22'u8, 0x0A'u8, 0x20'u8, 0x20'u8, 0x21'u8, 0x22'u8, 0x23'u8, 0x24'u8, 0x25'u8,
  0x26'u8, 0x27'u8, 0x28'u8, 0x29'u8, 0x2A'u8, 0x2B'u8, 0x2C'u8, 0x2D'u8, 0x2E'u8,
  0x2F'u8, 0x30'u8, 0x31'u8, 0x32'u8, 0x33'u8, 0x34'u8, 0x35'u8, 0x36'u8, 0x37'u8,
  0x38'u8, 0x39'u8, 0x3A'u8, 0x3B'u8, 0x3C'u8, 0x3D'u8, 0x3E'u8, 0x3F'u8,
]

let
  leaf0: ByteHash = toSeq(0'u8 .. 31'u8)
  leaf1: ByteHash = toSeq(32'u8 .. 63'u8)

suite "Merkle tree wire-format contract":
  test "Should encode a tree":
    let tree = StorageMerkleTree.init(Sha256HashCodec, [leaf0, leaf1]).get()
    check tree.encode() == Expected_tree

  test "Should encode a proof with a zero index":
    let proof = StorageMerkleProof.init(Sha256HashCodec, 0, 2, [leaf1]).get()
    check proof.encode() == Expected_proofZeroIndex

  test "Should encode a proof with multi-byte varints":
    let proof = StorageMerkleProof.init(Sha256HashCodec, 299, 300, [leaf0, leaf1]).get()
    check proof.encode() == Expected_proofMultiByteVarints

  test "Should round-trip the tree fixture (decode + re-encode)":
    let decoded = StorageMerkleTree.decode(Expected_tree)
    check decoded.isOk
    check decoded.get.encode() == Expected_tree

  test "Should round-trip every proof fixture (decode + re-encode)":
    let fixtures = [
      ("proofZeroIndex", Expected_proofZeroIndex),
      ("proofMultiByteVarints", Expected_proofMultiByteVarints),
    ]
    for (name, expected) in fixtures:
      checkpoint("fixture: " & name)
      let decoded = StorageMerkleProof.decode(expected)
      check decoded.isOk
      check decoded.get.encode() == expected

  test "Should skip an unknown field and decode to the canonical proof":
    let decoded = StorageMerkleProof.decode(Expected_proofZeroIndex & @[0x50'u8, 0x01])
    check decoded.isOk
    check decoded.get.encode() == Expected_proofZeroIndex

# ============================================================================
# For reference: minprotobuf encoders that produced the Expected_* bytes above.
# Kept as documentation of the format derivation.
# ============================================================================

when false:
  import pkg/libp2p/protobuf/minprotobuf

  proc legacyEncode(tree: StorageMerkleTree): seq[byte] =
    var pb = initProtoBuffer()
    pb.write(1, tree.mcodec.uint64)
    pb.write(2, tree.leavesCount.uint64)
    for node in tree.nodes:
      var nodesPb = initProtoBuffer()
      nodesPb.write(1, node)
      nodesPb.finish()
      pb.write(3, nodesPb)
    pb.finish
    pb.buffer

  proc legacyEncode(proof: StorageMerkleProof): seq[byte] =
    var pb = initProtoBuffer()
    pb.write(1, proof.mcodec.uint64)
    pb.write(2, proof.index.uint64)
    pb.write(3, proof.nleaves.uint64)
    for node in proof.path:
      var nodesPb = initProtoBuffer()
      nodesPb.write(1, node)
      nodesPb.finish()
      pb.write(4, nodesPb)
    pb.finish
    pb.buffer
