import std/sequtils
import std/strutils

import pkg/cbor_serialization
import pkg/cbor_serialization/value_ops
import pkg/libp2p
import pkg/libp2p/protobuf/minprotobuf
import pkg/nimcrypto/sha2
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

  test "the name is the SHA2-256 of the public key bytes followed by the label bytes":
    let
      labelBytes = @(label.toOpenArrayByte(0, label.high))
      expected = sha256.digest(publicKey.getBytes().tryGet() & labelBytes).data

    check name(publicKey, label).tryGet() == expected

  proc createName(publicKey: PublicKey, label: string): Name =
    let labelBytes = @(label.toOpenArrayByte(0, label.high))

    sha256.digest(publicKey.getBytes().tryGet() & labelBytes).data

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
    check 'a'.repeat(MinLabelLength).len == 1
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

    check cidV0.version == CIDv0
    check newRecord(label).sign(privateKey).isOk
    check record.sign(privateKey).isErr

  # 4 bytes of the CID are the version, the codec, the hash code and the
  # digest length.
  proc cidWithLength(length: int): Cid =
    let hash = MultiHash.digest("identity", newSeq[byte](length - 4)).tryGet()

    Cid.init(CIDv1, multiCodec("raw"), hash).tryGet()

  test "sign accepts a name record whose cid is 128 bytes":
    let cid = cidWithLength(128)

    check cid.data.buffer.len == 128
    check Cid.init(cid.data.buffer).tryGet() == cid
    check newRecord(label, cid).sign(privateKey).isOk

  test "sign refuses a name record whose cid is longer than 128 bytes":
    let cid = cidWithLength(129)

    check cid.data.buffer.len == 129
    check Cid.init(cid.data.buffer).tryGet() == cid
    check newRecord(label, cid).sign(privateKey).isErr

  test "sign refuses a label that is not valid UTF-8":
    for invalidLabel in invalidUtf8Labels:
      check newRecord(invalidLabel).sign(privateKey).isErr

  test "validate refuses a name record with an empty label":
    let
      record = newRecord("")
      now = record.expiration - 3600
      bytes = SignedNameRecord.init(privateKey, record).tryGet().encode()

    check createName(publicKey, label) == name(publicKey, label).tryGet()
    check validate(createName(publicKey, ""), bytes, now).isErr

  test "validate refuses a name record with a label that is not valid UTF-8":
    check createName(publicKey, label) == name(publicKey, label).tryGet()

    for invalidLabel in invalidUtf8Labels:
      let
        record = newRecord(invalidLabel)
        now = record.expiration - 3600
        bytes = SignedNameRecord.init(privateKey, record).tryGet().encode()

      check validate(createName(publicKey, invalidLabel), bytes, now).isErr

  test "the name of a signed name record matches its signing key and label":
    let
      bytes = newRecord(label).sign(privateKey).tryGet().encode()
      decoded = decodeNameRecord(bytes).tryGet()

    check decoded.name().tryGet() == name(publicKey, label).tryGet()

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

  test "refuses a name record whose payload is protobuf":
    let record = newRecord(label)

    var pb = initProtoBuffer()
    pb.write(1, record.version.uint64)
    pb.write(2, record.label)
    pb.write(3, record.cid.data.buffer)
    pb.write(4, record.seqnum)
    pb.write(5, record.expiration.uint64)
    pb.finish()

    let bytes = signPayload(pb.buffer)

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

  test "refuses a name record whose cid is not a valid CID":
    let fields = cborFields(newRecord(label))

    fields["cid"] =
      CborValueRef(kind: CborValueKind.Bytes, bytesVal: @[0xFF'u8, 0xFF, 0xFF])

    let bytes = signPayload(Cbor.encode(fields))

    check decodeNameRecord(bytes).isErr

  test "refuses a name record whose cid is longer than 128 bytes":
    let
      cid = cidWithLength(129)
      validRecord = newRecord(label, cidWithLength(128))
      validBytes = signPayload(Cbor.encode(cborFields(validRecord)))
      longBytes = signPayload(Cbor.encode(cborFields(newRecord(label, cid))))

    check cid.data.buffer.len == 129
    check decodeNameRecord(validBytes).isOk
    check decodeNameRecord(longBytes).isErr

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
