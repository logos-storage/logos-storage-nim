import std/sequtils
import std/strutils

import pkg/libp2p
import pkg/questionable/results

import pkg/unittest2

import ../checktest
import ./examples
import ../../storage/naming/record

checksuite "Name record":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    label = "catalog-release"

  proc newRecord(label: string): NameRecord =
    NameRecord(
      version: 1,
      label: label,
      cid: Cid.example,
      sequenceNumber: 1794304800'u64,
      expiration: 1794477600'i64,
    )

  test "a decoded record has the same fields and public key as the original":
    let
      record = newRecord(label)
      signed = record.sign(privateKey).tryGet()
      bytes = signed.encode().tryGet()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.data.version == record.version
    check decoded.data.label == record.label
    check decoded.data.cid == record.cid
    check decoded.data.sequenceNumber == record.sequenceNumber
    check decoded.data.expiration == record.expiration
    check decoded.envelope.publicKey == publicKey

  test "refuses bytes that are not a name record":
    let
      randomBytes = newSeqWith(100, 0xAB'u8)
      noBytes = newSeq[byte]()

    check decodeNameRecord(randomBytes).isErr
    check decodeNameRecord(noBytes).isErr

  test "gives the same name for the same key and label":
    check name(publicKey, label).tryGet() == name(publicKey, label).tryGet()

  test "gives different names for different labels":
    check name(publicKey, "alpha").tryGet() != name(publicKey, "beta").tryGet()

  test "gives different names for different keys":
    let otherKey = PrivateKey.example.getPublicKey().tryGet()

    check name(publicKey, label).tryGet() != name(otherKey, label).tryGet()

  test "refuses a label longer than the maximum":
    check name(publicKey, 'a'.repeat(MaxLabelLength + 1)).isErr
    check name(publicKey, 'a'.repeat(MaxLabelLength)).isOk

  test "the name of a signed record matches its signing key and label":
    let
      bytes = newRecord(label).sign(privateKey).tryGet().encode().tryGet()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.name().tryGet() == name(publicKey, label).tryGet()
