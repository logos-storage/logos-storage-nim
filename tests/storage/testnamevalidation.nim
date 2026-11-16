import std/sequtils
import std/strutils

import pkg/libp2p
import pkg/questionable/results
import pkg/stew/byteutils

import pkg/unittest2

import ../checktest
import ./examples
import ../../storage/naming/record

checksuite "Name record validation":
  let
    now = 1794304800'i64
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    label = "catalog-release"
    publisherName = name(publicKey, label).tryGet()

  proc newRecord(
      label: string,
      version = NameRecordVersion,
      expiration = now + 3600,
  ): NameRecord =
    NameRecord(
      version: version,
      label: label,
      cid: Cid.example,
      sequenceNumber: 1794304800'u64,
      expiration: expiration,
    )

  proc signedBytes(record: NameRecord, key = privateKey): seq[byte] =
    SignedNameRecord.init(key, record).tryGet().encode().tryGet()

  test "accepts a valid record and returns the decoded record":
    let
      record = newRecord(label)
      validated = validate(publisherName, signedBytes(record), now).tryGet()

    check validated.data.version == record.version
    check validated.data.label == record.label
    check validated.data.cid == record.cid
    check validated.data.sequenceNumber == record.sequenceNumber
    check validated.data.expiration == record.expiration
    check validated.envelope.publicKey == publicKey

  test "refuses a record whose signed content was changed":
    let
      record = newRecord(label)
      cidBytes = string.fromBytes(record.cid.data.buffer)
      otherCidBytes = string.fromBytes(Cid.example.data.buffer)
      bytes = signedBytes(record)
      modified = string.fromBytes(bytes).replace(cidBytes, otherCidBytes).toBytes

    check modified != bytes
    check validate(publisherName, bytes, now).isOk
    check validate(publisherName, modified, now).isErr

  test "refuses a record with an expiration equal to now":
    let bytes = signedBytes(newRecord(label, expiration = now))

    check validate(publisherName, bytes, now).isErr

  test "refuses a record with an expiration before now":
    let bytes = signedBytes(newRecord(label, expiration = now - 1))

    check validate(publisherName, bytes, now).isErr

  test "accepts a record that expires exactly at the maximum delay":
    let bytes = signedBytes(newRecord(label, expiration = now + MaxExpirationDelay))

    check validate(publisherName, bytes, now).isOk

  test "refuses a record that expires after the maximum delay":
    let bytes = signedBytes(newRecord(label, expiration = now + MaxExpirationDelay + 1))

    check validate(publisherName, bytes, now).isErr

  test "refuses a record with an unknown version":
    let bytes = signedBytes(newRecord(label, version = NameRecordVersion + 1))

    check validate(publisherName, bytes, now).isErr

  test "refuses a record with a label longer than the maximum":
    let
      longLabel = 'a'.repeat(MaxLabelLength + 1)
      limitName = name(publicKey, 'a'.repeat(MaxLabelLength)).tryGet()
      bytes = signedBytes(newRecord(longLabel))

    check validate(limitName, bytes, now).isErr

  test "refuses a record whose name does not match the label":
    let
      bytes = signedBytes(newRecord("alpha"))
      betaName = name(publicKey, "beta").tryGet()

    check validate(betaName, bytes, now).isErr

  test "refuses a record signed by another key":
    let
      attackerKey = PrivateKey.example
      catalogName = name(publicKey, "catalog").tryGet()
      bytes = signedBytes(newRecord("catalog"), attackerKey)

    check validate(catalogName, bytes, now).isErr

  test "refuses bytes that are not a name record":
    let
      randomBytes = newSeqWith(100, 0xAB'u8)
      noBytes = newSeq[byte]()

    check validate(publisherName, randomBytes, now).isErr
    check validate(publisherName, noBytes, now).isErr
