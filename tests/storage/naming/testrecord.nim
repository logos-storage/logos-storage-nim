import std/sequtils
import std/strutils

import pkg/cbor_serialization
import pkg/cbor_serialization/value_ops
import pkg/libp2p
import pkg/nimcrypto/sha2
import pkg/protobuf_serialization
import pkg/questionable/results

import pkg/unittest2

import ../../checktest
import ../examples
import ../../../storage/naming/record

type ProtobufNameRecord {.proto2.} = object
  version {.fieldNumber: 1, required, pint.}: uint64
  label {.fieldNumber: 2, required.}: string
  cid {.fieldNumber: 3, required.}: seq[byte]
  seqnum {.fieldNumber: 4, required, pint.}: uint64
  expiration {.fieldNumber: 5, required, pint.}: uint64

checksuite "Name record":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    label = "catalog-release"

  proc newRecord(label: string, cid = Cid.example): NameRecord =
    NameRecord(
      version: 1,
      label: label,
      cid: cid,
      seqnum: 1794304800'u64,
      expiration: 1794477600'i64,
    )

  test "a decoded name record has the same fields and public key as the original":
    let
      record = newRecord(label)
      signed = record.sign(privateKey).tryGet()
      bytes = signed.encode()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.data.version == record.version
    check decoded.data.label == record.label
    check decoded.data.cid == record.cid
    check decoded.data.seqnum == record.seqnum
    check decoded.data.expiration == record.expiration
    check decoded.envelope.publicKey == publicKey

  test "the name is the SHA2-256 of the public key bytes followed by the label bytes":
    let
      labelBytes = @(label.toOpenArrayByte(0, label.high))
      expected = sha256.digest(publicKey.getBytes().tryGet() & labelBytes).data

    check name(publicKey, label).tryGet() == expected

  let invalidUtf8Labels = [
    "\xff", # invalid byte
    "caf\xc3", # truncated sequence
    "\xE0\x80\x80", # overlong 3-byte form
    "\xED\xA0\x80", # UTF-16 surrogate
    "\xF4\x90\x80\x80", # above U+10FFFF
    "\xF0\x80\x80\x80", # overlong 4-byte form
    "\xF5\x80\x80\x80", # lead byte F5..F7
  ]

  test "accepts a label of 1 byte and a label of 256 bytes":
    check name(publicKey, 'a'.repeat(MinLabelLength)).isOk
    check name(publicKey, 'a'.repeat(256)).isOk

  test "refuses an empty label and a label of 257 bytes":
    check name(publicKey, "").isErr
    check name(publicKey, 'a'.repeat(257)).isErr

  test "refuses a label that is not valid UTF-8":
    for invalidLabel in invalidUtf8Labels:
      check name(publicKey, invalidLabel).isErr

  test "sign refuses an empty label and a label of 257 bytes":
    check newRecord("").sign(privateKey).isErr
    check newRecord('a'.repeat(257)).sign(privateKey).isErr

  test "sign refuses a name record whose cid is a CIDv0":
    let
      cidV0 = Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n").tryGet()
      record = NameRecord(
        version: 1,
        label: label,
        cid: cidV0,
        seqnum: 1794304800'u64,
        expiration: 1794477600'i64,
      )

    check newRecord(label).sign(privateKey).isOk
    check record.sign(privateKey).isErr

  # 4 bytes of the CID are the version, the codec, the hash code and the
  # digest length.
  proc cidWithLength(length: int): Cid =
    let hash = MultiHash.digest("identity", newSeq[byte](length - 4)).tryGet()

    Cid.init(CIDv1, multiCodec("raw"), hash).tryGet()

  test "sign accepts a name record whose cid is 128 bytes":
    check newRecord(label, cidWithLength(128)).sign(privateKey).isOk

  test "sign refuses a name record whose cid is longer than 128 bytes":
    check newRecord(label, cidWithLength(129)).sign(privateKey).isErr

  test "sign refuses a label that is not valid UTF-8":
    for invalidLabel in invalidUtf8Labels:
      check newRecord(invalidLabel).sign(privateKey).isErr

  test "the name of a signed name record matches its signing key and label":
    let
      bytes = newRecord(label).sign(privateKey).tryGet().encode()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.name() == name(publicKey, label).tryGet()

  test "the signed envelope of a name record has the payload type 0xCD05":
    let signed = newRecord(label).sign(privateKey).tryGet()

    check signed.envelope.payloadType == @[0x85'u8, 0x9A, 0x03]

  proc unsignedValue(value: uint64): CborValueRef =
    CborValueRef(
      kind: CborValueKind.Unsigned,
      numVal: CborNumber(sign: CborSign.None, integer: value),
    )

  proc taggedValue(tag: uint64, value: CborValueRef): CborValueRef =
    CborValueRef(
      kind: CborValueKind.Tag, tagVal: CborTag[CborValueRef](tag: tag, val: value)
    )

  proc cborFields(record: NameRecord): CborValueRef =
    let fields = CborValueRef(kind: CborValueKind.Object)

    fields["version"] = unsignedValue(record.version.uint64)
    fields["label"] = CborValueRef(kind: CborValueKind.String, strVal: record.label)
    fields["cid"] =
      CborValueRef(kind: CborValueKind.Bytes, bytesVal: record.cid.data.buffer)
    fields["seqnum"] = unsignedValue(record.seqnum)
    fields["expiration"] = taggedValue(1, unsignedValue(record.expiration.uint64))

    fields

  proc signPayload(payload: seq[byte]): seq[byte] =
    Envelope
      .init(privateKey, NameRecord.payloadType(), payload, NameRecord.payloadDomain())
      .tryGet()
      .encode()

  test "the name record is encoded as a CBOR map":
    let
      record = newRecord(label)
      signed = record.sign(privateKey).tryGet()
      payload = Cbor.decode(signed.envelope.payload, CborValueRef)

    check payload.kind == CborValueKind.Object
    check payload.len == 5
    check payload["version"].numVal.integer == record.version.uint64
    check payload["label"].strVal == record.label
    check payload["cid"].bytesVal == record.cid.data.buffer
    check payload["seqnum"].numVal.integer == record.seqnum
    check payload["expiration"].kind == CborValueKind.Tag
    check payload["expiration"].tagVal.tag == 1'u64
    check payload["expiration"].tagVal.val.kind == CborValueKind.Unsigned
    check payload["expiration"].tagVal.val.numVal.integer == record.expiration.uint64

  test "accepts a name record whose payload is well-formed CBOR":
    let
      record = newRecord(label)
      payload = Cbor.encode(cborFields(record))
      bytes = signPayload(payload)
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.data.version == record.version
    check decoded.data.label == record.label
    check decoded.data.cid == record.cid
    check decoded.data.seqnum == record.seqnum
    check decoded.data.expiration == record.expiration

  test "refuses a name record whose signature is not valid":
    let
      payload = Cbor.encode(cborFields(newRecord(label)))
      otherDomainBytes = Envelope
        .init(privateKey, NameRecord.payloadType(), payload, "another-domain")
        .tryGet()
        .encode()

    check decodeNameRecord(signPayload(payload)).isOk
    check decodeNameRecord(otherDomainBytes).isErr

  test "the name record is signed under the domain logos-name-record":
    let
      payload = Cbor.encode(cborFields(newRecord(label)))
      specBytes = Envelope
        .init(privateKey, NameRecord.payloadType(), payload, "logos-name-record")
        .tryGet()
        .encode()
      signedBytes = newRecord(label).sign(privateKey).tryGet().encode()

    check decodeNameRecord(specBytes).isOk
    check Envelope.decode(signedBytes, "logos-name-record").isOk

  test "refuses a name record whose payload is not CBOR":
    let bytes = signPayload(@[0xFF'u8, 0xFF, 0xFF])

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose payload is protobuf":
    let
      record = newRecord(label)
      payload = encode(
        Protobuf,
        ProtobufNameRecord(
          version: record.version.uint64,
          label: record.label,
          cid: record.cid.data.buffer,
          seqnum: record.seqnum,
          expiration: record.expiration.uint64,
        ),
      )
      bytes = signPayload(payload)

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose CBOR payload misses a field":
    for key in ["version", "label", "cid", "seqnum", "expiration"]:
      let fields = cborFields(newRecord(label))

      fields.delete(key)

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose CBOR payload has a field of the wrong type":
    let wrongText = CborValueRef(kind: CborValueKind.String, strVal: "1")

    for key in ["version", "label", "cid", "seqnum", "expiration"]:
      let fields = cborFields(newRecord(label))

      fields[key] =
        if key == "label":
          unsignedValue(1)
        else:
          wrongText

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose integer field is out of range":
    let negativeOne = CborValueRef(
      kind: CborValueKind.Negative, numVal: CborNumber(sign: CborSign.Neg, integer: 0)
    )

    for (key, value) in [
      ("version", unsignedValue(uint32.high.uint64 + 1)),
      ("seqnum", negativeOne),
      ("expiration", taggedValue(1, unsignedValue(uint64.high))),
    ]:
      let fields = cborFields(newRecord(label))

      fields[key] = value

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose expiration is negative":
    let
      negativeOne = CborValueRef(
        kind: CborValueKind.Negative, numVal: CborNumber(sign: CborSign.Neg, integer: 0)
      )
      fields = cborFields(newRecord(label))

    fields["expiration"] = taggedValue(1, negativeOne)

    let bytes = signPayload(Cbor.encode(fields))

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose cid is not a valid CID":
    let fields = cborFields(newRecord(label))

    fields["cid"] =
      CborValueRef(kind: CborValueKind.Bytes, bytesVal: @[0xFF'u8, 0xFF, 0xFF])

    let bytes = signPayload(Cbor.encode(fields))

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose cid is a CIDv0":
    let
      cidV0 = Cid.init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n").tryGet()
      validBytes = signPayload(Cbor.encode(cborFields(newRecord(label))))
      v0Bytes = signPayload(Cbor.encode(cborFields(newRecord(label, cidV0))))

    check decodeNameRecord(validBytes).isOk
    check decodeNameRecord(v0Bytes).isErr

  test "refuses a name record whose cid is longer than 128 bytes":
    let
      validRecord = newRecord(label, cidWithLength(128))
      validBytes = signPayload(Cbor.encode(cborFields(validRecord)))
      longRecord = newRecord(label, cidWithLength(129))
      longBytes = signPayload(Cbor.encode(cborFields(longRecord)))

    check decodeNameRecord(validBytes).isOk
    check decodeNameRecord(longBytes).isErr

  test "refuses a name record with an empty label or a label of 257 bytes":
    let
      emptyRecord = newRecord("")
      longRecord = newRecord('a'.repeat(257))

    check decodeNameRecord(signPayload(Cbor.encode(cborFields(emptyRecord)))).isErr
    check decodeNameRecord(signPayload(Cbor.encode(cborFields(longRecord)))).isErr

  test "refuses a name record with a label that is not valid UTF-8":
    for invalidLabel in invalidUtf8Labels:
      let bytes = signPayload(Cbor.encode(cborFields(newRecord(invalidLabel))))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose expiration is an integer without tag 1":
    let
      record = newRecord(label)
      fields = cborFields(record)

    fields["expiration"] = unsignedValue(record.expiration.uint64)

    let bytes = signPayload(Cbor.encode(fields))

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose expiration is an integer under another tag":
    let record = newRecord(label)

    for tag in [0'u64, 2'u64]:
      let fields = cborFields(record)

      fields["expiration"] = taggedValue(tag, unsignedValue(record.expiration.uint64))

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose expiration is tag 1 around a float or a text":
    let
      record = newRecord(label)
      floatValue =
        CborValueRef(kind: CborValueKind.Float, floatVal: record.expiration.float64)
      textValue = CborValueRef(kind: CborValueKind.String, strVal: $record.expiration)

    for value in [floatValue, textValue]:
      let fields = cborFields(record)

      fields["expiration"] = taggedValue(1, value)

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

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

  test "refuses bytes that are not a name record":
    let
      randomBytes = newSeqWith(100, 0xAB'u8)
      noBytes = newSeq[byte]()

    check validate(publisherName, randomBytes, now).isErr
    check validate(publisherName, noBytes, now).isErr

checksuite "Name record comparison":
  let
    # 10:00:00 UTC on 12 November 2026
    tenOClock = 1794477600'i64
    # 14:00:00 UTC on 12 November 2026
    twoOClock = 1794492000'i64

  proc newRecord(seqnum: uint64, expiration: int64): NameRecord =
    NameRecord(
      version: NameRecordVersion,
      label: "catalog",
      cid: Cid.example,
      seqnum: seqnum,
      expiration: expiration,
    )

  test "a higher seqnum is newer, even when it expires earlier":
    let
      higher = newRecord(43'u64, tenOClock)
      lower = newRecord(42'u64, twoOClock)

    check higher.isNewer(lower)
    check not lower.isNewer(higher)

  test "with the same seqnum, the name record that expires later is newer":
    let
      expiresLater = newRecord(42'u64, twoOClock)
      expiresEarlier = newRecord(42'u64, tenOClock)

    check expiresLater.isNewer(expiresEarlier)
    check not expiresEarlier.isNewer(expiresLater)

  test "a name record is not newer than one with the same seqnum and expiration":
    let
      first = newRecord(42'u64, tenOClock)
      second = newRecord(42'u64, tenOClock)

    check not first.isNewer(second)
