import std/strutils

import pkg/cbor_serialization
import pkg/cbor_serialization/value_ops
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
      label: string, version = NameRecordVersion, expiration = now + 3600
  ): NameRecord =
    NameRecord(
      version: version,
      label: label,
      cid: Cid.example,
      seqnum: 1794304800'u64,
      expiration: expiration,
    )

  proc signedBytes(record: NameRecord, key = privateKey): seq[byte] =
    SignedNameRecord.init(key, record).tryGet().encode()

  test "accepts a valid name record and returns the decoded name record":
    let
      record = newRecord(label)
      validated = validate(publisherName, signedBytes(record), now).tryGet()

    check validated.data.version == record.version
    check validated.data.label == record.label
    check validated.data.cid == record.cid
    check validated.data.seqnum == record.seqnum
    check validated.data.expiration == record.expiration
    check validated.envelope.publicKey == publicKey

  test "refuses a name record whose signed content was changed":
    let
      record = newRecord(label)
      cidBytes = string.fromBytes(record.cid.data.buffer)
      otherCidBytes = string.fromBytes(Cid.example.data.buffer)
      bytes = signedBytes(record)
      modified = string.fromBytes(bytes).replace(cidBytes, otherCidBytes).toBytes

    check modified != bytes
    check validate(publisherName, bytes, now).isOk
    check validate(publisherName, modified, now).isErr

  test "accepts a name record with an expiration equal to now":
    let bytes = signedBytes(newRecord(label, expiration = now))

    check validate(publisherName, bytes, now).isOk

  test "refuses a name record with an expiration before now":
    let bytes = signedBytes(newRecord(label, expiration = now - 1))

    check validate(publisherName, bytes, now).isErr

  test "refuses a name record with an unknown version":
    let bytes = signedBytes(newRecord(label, version = NameRecordVersion + 1))

    check validate(publisherName, bytes, now).isErr

  test "refuses a name record whose name does not match the label":
    let
      bytes = signedBytes(newRecord("alpha"))
      betaName = name(publicKey, "beta").tryGet()

    check validate(betaName, bytes, now).isErr

  test "refuses a name record signed by another key":
    let
      attackerKey = PrivateKey.example
      catalogName = name(publicKey, "catalog").tryGet()
      bytes = signedBytes(newRecord("catalog"), attackerKey)

    check validate(catalogName, bytes, now).isErr

  proc unsignedValue(value: uint64): CborValueRef =
    CborValueRef(
      kind: CborValueKind.Unsigned,
      numVal: CborNumber(sign: CborSign.None, integer: value),
    )

  proc handBuiltBytes(record: NameRecord): seq[byte] =
    let fields = CborValueRef(kind: CborValueKind.Object)

    fields["version"] = unsignedValue(record.version.uint64)
    fields["label"] = CborValueRef(kind: CborValueKind.String, strVal: record.label)
    fields["cid"] =
      CborValueRef(kind: CborValueKind.Bytes, bytesVal: record.cid.data.buffer)
    fields["seqnum"] = unsignedValue(record.seqnum)
    fields["expiration"] = CborValueRef(
      kind: CborValueKind.Tag,
      tagVal:
        CborTag[CborValueRef](tag: 1, val: unsignedValue(record.expiration.uint64)),
    )

    Envelope
      .init(
        privateKey,
        NameRecord.payloadType(),
        Cbor.encode(fields),
        NameRecord.payloadDomain(),
      )
      .tryGet()
      .encode()

  test "refuses a name record whose cid is a CIDv0":
    let
      cidV0 = Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n").tryGet()
      validRecord = newRecord(label)
      v0Record = NameRecord(
        version: validRecord.version,
        label: label,
        cid: cidV0,
        seqnum: validRecord.seqnum,
        expiration: validRecord.expiration,
      )

    check cidV0.version == CIDv0
    check validate(publisherName, handBuiltBytes(validRecord), now).isOk
    check validate(publisherName, handBuiltBytes(v0Record), now).isErr
