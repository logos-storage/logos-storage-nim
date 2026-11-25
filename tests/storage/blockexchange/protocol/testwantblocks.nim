import std/sequtils

import pkg/unittest2
import pkg/libp2p/multicodec
import pkg/results
import pkg/stew/endians2
import pkg/storage/errors
import pkg/storage/merkletree
import pkg/storage/storagetypes
import pkg/storage/blockexchange/protocol/wantblocks

proc proofHeader(mcodec, index, nleaves: uint64): seq[byte] =
  @(mcodec.toBytes(littleEndian)) & @(index.toBytes(littleEndian)) &
    @(nleaves.toBytes(littleEndian)) & @(0'u32.toBytes(littleEndian))

suite "WantBlocks proof binary decoding":
  let leaf: ByteHash = toSeq(0'u8 .. 31'u8)

  test "Should decode an encoded proof":
    let proof = StorageMerkleProof.init(Sha256HashCodec, 1, 2, [leaf]).get()
    var buf = newSeq[byte](calcProofBinarySize(proof))
    check encodeProofBinaryInto(proof, buf, 0) == buf.len

    let decoded = decodeProofBinary(buf)
    check decoded.isOk
    check decoded.get.mcodec == proof.mcodec
    check decoded.get.index == proof.index
    check decoded.get.nleaves == proof.nleaves
    check decoded.get.path == proof.path

  test "Should reject a proof mcodec which is above int range":
    let decoded = decodeProofBinary(proofHeader(high(int).uint64 + 1, 0, 1))
    check decoded.isErr
    check decoded.error.kind == ProofDecodeFailed

  test "Should reject a proof index which is above int range":
    let decoded =
      decodeProofBinary(proofHeader(Sha256HashCodec.uint64, high(int).uint64 + 1, 1))
    check decoded.isErr
    check decoded.error.kind == ProofDecodeFailed

  test "Should reject a proof nleaves which is above int range":
    let decoded =
      decodeProofBinary(proofHeader(Sha256HashCodec.uint64, 0, high(int).uint64 + 1))
    check decoded.isErr
    check decoded.error.kind == ProofDecodeFailed

  test "Should not reject a proof at the int range boundary":
    let decoded = decodeProofBinary(
      proofHeader(Sha256HashCodec.uint64, high(int).uint64, high(int).uint64)
    )
    check decoded.isOk or decoded.error.kind != ProofDecodeFailed

  test "Should reject a proof shorter than the header":
    let decoded = decodeProofBinary(proofHeader(Sha256HashCodec.uint64, 0, 1)[0 ..^ 2])
    check decoded.isErr
    check decoded.error.kind == ProofTooShort
