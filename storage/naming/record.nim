## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

from pkg/toml_serialization/private/utf8_validate import validateUTF8

import pkg/cbor_serialization
import pkg/cbor_serialization/value_ops
import pkg/libp2p
import pkg/libp2p/signed_envelope
import pkg/libp2p/vbuffer
import pkg/nimcrypto/sha2
import pkg/questionable
import pkg/questionable/results

export signed_envelope

const
  MinLabelLength* = 1
  MaxLabelLength* = 256
  NameRecordVersion* = 1'u32
  MaxExpirationDelay* = 48 * 60 * 60
  NameRecordCodec = multiCodec("storage-name")
  NameRecordDomain = "logos-storage-name-record"
  IntegerKinds = {CborValueKind.Unsigned, CborValueKind.Negative}

type
  Name* = array[32, byte]

  NameRecord* = object
    version*: uint32
    label*: string
    cid*: Cid
    seqnum*: uint64
    expiration*: int64

  SignedNameRecord* = SignedPayload[NameRecord]

proc payloadDomain*(T: typedesc[NameRecord]): string =
  ## The signature domain of a name record, needed so that a signature made
  ## for other data can't be reused as a name record signature
  NameRecordDomain

proc payloadType*(T: typedesc[NameRecord]): seq[byte] =
  ## The payload type of a name record, needed to tell that the envelope
  ## payload is a CBOR-encoded name record
  var buffer = initVBuffer()
  buffer.writeVarint(uint64(int(NameRecordCodec)))
  buffer.finish()

  buffer.buffer

proc writeValue(
    w: var CborWriter[DefaultFlavor], record: NameRecord
) {.raises: [IOError].} =
  ## The expiration is an integer under tag 1, the `time` of the protocol:
  ## https://www.rfc-editor.org/rfc/rfc8949#section-3.4.2
  w.beginObject(5)
  w.writeField("version", record.version)
  w.writeField("label", record.label)
  w.writeField("cid", record.cid.data.buffer)
  w.writeField("seqnum", record.seqnum)
  w.writeField("expiration", CborTag[int64](tag: 1, val: record.expiration))
  w.endObject(stopCode = false)

proc encode*(record: NameRecord): seq[byte] =
  Cbor.encode(record)

proc readField(
    fields: CborValueRef, key: string, kinds: set[CborValueKind]
): Result[CborValueRef, ref CatchableError] =
  let value = fields.getOrDefault(key)

  if value.isNil:
    return failure("The name record has no `" & key & "` field")

  if value.kind notin kinds:
    return failure("The `" & key & "` field of the name record has the wrong type")

  ok(value)

proc readInteger[T: SomeInteger](
    fields: CborValueRef, key: string
): Result[T, ref CatchableError] =
  let value = fields.readField(key, IntegerKinds).valueOr:
    return err(error)

  let number = value.numVal.toInt(T).valueOr:
    return failure("The `" & key & "` field of the name record is out of range")

  ok(number)

proc readTime(fields: CborValueRef, key: string): Result[int64, ref CatchableError] =
  let value = fields.readField(key, {CborValueKind.Tag}).valueOr:
    return err(error)

  if value.tagVal.tag != 1 or value.tagVal.val.kind notin IntegerKinds:
    return failure(
      "The `" & key & "` field of the name record is not an integer under tag 1"
    )

  let number = value.tagVal.val.numVal.toInt(int64).valueOr:
    return failure("The `" & key & "` field of the name record is out of range")

  ok(number)

proc decode*(
    T: typedesc[NameRecord], bytes: seq[byte]
): Result[NameRecord, ref CatchableError] =
  ## Decodes the CBOR map of a name record. Fails if a field is missing, has
  ## the wrong type or is out of range.
  var fields: CborValueRef

  try:
    fields = Cbor.decode(bytes, CborValueRef)
  except SerializationError as exc:
    return failure("The name record is not valid CBOR: " & exc.msg)

  let
    version = readInteger[uint32](fields, "version").valueOr:
      return err(error)
    label = fields.readField("label", {CborValueKind.String}).valueOr:
      return err(error)
    cidBytes = fields.readField("cid", {CborValueKind.Bytes}).valueOr:
      return err(error)
    seqnum = readInteger[uint64](fields, "seqnum").valueOr:
      return err(error)
    expiration = readTime(fields, "expiration").valueOr:
      return err(error)
    cid = Cid.init(cidBytes.bytesVal).valueOr:
      return failure("The `cid` field of the name record is not a valid CID: " & $error)

  ok(
    NameRecord(
      version: version,
      label: label.strVal,
      cid: cid,
      seqnum: seqnum,
      expiration: expiration,
    )
  )

proc checkLabel(label: string): Result[void, ref CatchableError] =
  if label.len < MinLabelLength:
    return failure("Label is shorter than " & $MinLabelLength & " byte")

  if label.len > MaxLabelLength:
    return failure("Label is longer than " & $MaxLabelLength & " bytes")

  if not validateUTF8(label):
    return failure("Label is not valid UTF-8")

  ok()

proc name*(publicKey: PublicKey, label: string): Result[Name, ref CatchableError] =
  ## The name is the SHA2-256 hash of the public key bytes
  ## followed by the label.
  ## Two different pairs never give the same name.
  let labelCheck = checkLabel(label)

  if labelCheck.isErr:
    return err(labelCheck.error)

  let keyBytes = publicKey.getBytes().valueOr:
    return failure("Invalid public key: " & $error)

  var hash: sha256
  hash.init()
  hash.update(keyBytes)
  hash.update(label)

  ok(hash.finish().data)

proc name*(signed: SignedNameRecord): Result[Name, ref CatchableError] =
  name(signed.envelope.publicKey, signed.data.label)

proc sign*(
    record: NameRecord, privateKey: PrivateKey
): Result[SignedNameRecord, ref CatchableError] =
  let labelCheck = checkLabel(record.label)

  if labelCheck.isErr:
    return err(labelCheck.error)

  let signed = SignedNameRecord.init(privateKey, record).valueOr:
    return failure("Cannot sign the name record: " & $error)

  ok(signed)

proc decodeNameRecord*(bytes: seq[byte]): Result[SignedNameRecord, ref CatchableError] =
  ## Decodes a signed name record and checks its signature. Fails if the bytes
  ## are not a name record or if the signature is not valid.
  let signed = SignedNameRecord.decode(bytes).valueOr:
    return failure("Cannot decode the name record: " & $error)

  ok(signed)

proc validate*(
    expected: Name, bytes: seq[byte], now: int64
): Result[SignedNameRecord, ref CatchableError] =
  ## Decodes the bytes stored under the `expected` name in the DHT and checks
  ## every rule of a valid name record. `now` is in Unix seconds.
  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  if signed.data.version != NameRecordVersion:
    return failure("Unknown name record version: " & $signed.data.version)

  if signed.data.expiration <= now:
    return failure("The name record has expired")

  if signed.data.expiration > now + MaxExpirationDelay:
    return failure("The name record expires too far in the future")

  let recordName = signed.name().valueOr:
    return err(error)

  if recordName != expected:
    return failure("The name is not the hash of the public key and the label")

  ok(signed)

proc isNewer*(a, b: NameRecord): bool =
  ## `a` is newer than `b` when its seqnum is higher, or when both have the same
  ## seqnum and `a` expires later.
  if a.seqnum != b.seqnum:
    return a.seqnum > b.seqnum

  a.expiration > b.expiration
