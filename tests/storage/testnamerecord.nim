import std/sequtils
import std/strutils

import pkg/cbor_serialization
import pkg/cbor_serialization/value_ops
import pkg/libp2p
import pkg/libp2p/protobuf/minprotobuf
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

  test "a decoded name record has the same fields and public key as the original":
    let
      record = newRecord(label)
      signed = record.sign(privateKey).tryGet()
      bytes = signed.encode()
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

  test "the name of a signed name record matches its signing key and label":
    let
      bytes = newRecord(label).sign(privateKey).tryGet().encode()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.name().tryGet() == name(publicKey, label).tryGet()

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
    fields["seq"] = unsignedValue(record.sequenceNumber)
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
    check payload["seq"].numVal.integer == record.sequenceNumber
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
    check decoded.data.sequenceNumber == record.sequenceNumber
    check decoded.data.expiration == record.expiration

  test "refuses a name record whose payload is protobuf":
    let record = newRecord(label)

    var pb = initProtoBuffer()
    pb.write(1, record.version.uint64)
    pb.write(2, record.label)
    pb.write(3, record.cid.data.buffer)
    pb.write(4, record.sequenceNumber)
    pb.write(5, record.expiration.uint64)
    pb.finish()

    let bytes = signPayload(pb.buffer)

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose CBOR payload misses a field":
    for key in ["version", "label", "cid", "seq", "expiration"]:
      let fields = cborFields(newRecord(label))

      fields.delete(key)

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose CBOR payload has a field of the wrong type":
    let wrongText = CborValueRef(kind: CborValueKind.String, strVal: "1")

    for key in ["version", "label", "cid", "seq", "expiration"]:
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
      ("seq", negativeOne),
      ("expiration", taggedValue(1, unsignedValue(uint64.high))),
    ]:
      let fields = cborFields(newRecord(label))

      fields[key] = value

      let bytes = signPayload(Cbor.encode(fields))

      check decodeNameRecord(bytes).isErr

  test "refuses a name record whose cid is not a valid CID":
    let fields = cborFields(newRecord(label))

    fields["cid"] =
      CborValueRef(kind: CborValueKind.Bytes, bytesVal: @[0xFF'u8, 0xFF, 0xFF])

    let bytes = signPayload(Cbor.encode(fields))

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
