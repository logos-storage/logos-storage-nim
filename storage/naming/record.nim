## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p
import pkg/libp2p/signed_envelope
import pkg/libp2p/vbuffer
import pkg/nimcrypto/sha2
import pkg/protobuf_serialization
import pkg/questionable
import pkg/questionable/results

import ../utils/protobuf/cid
import ../utils/protobuf/serializer

export signed_envelope

const
  MaxLabelLength* = 64
  NameRecordVersion* = 1'u32
  MaxExpirationDelay* = 48 * 60 * 60
  NameRecordCodec = multiCodec("storage-name-record")
  NameRecordDomain = "logos-storage-name-record"

type
  Name* = array[32, byte]

  NameRecord* {.proto2.} = object
    version* {.fieldNumber: 1, required, pint.}: uint32
    label* {.fieldNumber: 2, required.}: string
    cid* {.fieldNumber: 3, required, ext.}: Cid
    sequenceNumber* {.fieldNumber: 4, required, pint.}: uint64
    expiration* {.fieldNumber: 5, required, pint.}: int64

  SignedNameRecord* = SignedPayload[NameRecord]

Protobuf.serializerForResult([NameRecord])

proc payloadDomain*(T: typedesc[NameRecord]): string =
  ## The signature domain of a name record, needed so that a signature made
  ## for other data can't be reused as a name record signature
  NameRecordDomain

proc payloadType*(T: typedesc[NameRecord]): seq[byte] =
  ## The payload type of a name record, needed to tell that the envelope
  ## payload is a protobuf-encoded name record
  var buffer = initVBuffer()
  buffer.writeVarint(uint64(int(NameRecordCodec)))
  buffer.finish()

  buffer.buffer

proc checkLabel(label: string): Result[void, ref CatchableError] =
  if label.len > MaxLabelLength:
    return failure("Label is longer than " & $MaxLabelLength & " bytes")

  ok()

proc name*(publicKey: PublicKey, label: string): Result[Name, ref CatchableError] =
  ## The name is the SHA2-256 hash of the public key and the label. Both are
  ## prefixed with their length, so two different pairs never give the same name.
  let labelCheck = checkLabel(label)

  if labelCheck.isErr:
    return err(labelCheck.error)

  let keyBytes = publicKey.getBytes().valueOr:
    return failure("Invalid public key: " & $error)

  var buffer = initVBuffer()
  buffer.writeSeq(keyBytes)
  buffer.writeSeq(label)
  buffer.finish()

  ok(sha256.digest(buffer.buffer).data)

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

proc encode*(signed: SignedNameRecord): Result[seq[byte], ref CatchableError] =
  ok(signed.envelope.encode())

proc decodeNameRecord*(bytes: seq[byte]): Result[SignedNameRecord, ref CatchableError] =
  ## Decodes a signed name record and checks its signature. Fails if the bytes
  ## are not a name record or if the signature is not valid.
  let signed = SignedNameRecord.decode(bytes).valueOr:
    return failure("Cannot decode the name record: " & $error)

  ok(signed)

proc validate*(
    name: Name, bytes: seq[byte], now: int64
): Result[SignedNameRecord, ref CatchableError] =
  ## Decodes the bytes stored under `name` in the DHT and checks every rule of
  ## a valid name record. `now` is in Unix seconds.
  let signed = decodeNameRecord(bytes).valueOr:
    return failure(error.msg)

  if signed.data.version != NameRecordVersion:
    return failure("Unknown name record version: " & $signed.data.version)

  if signed.data.expiration <= now:
    return failure("The name record has expired")

  if signed.data.expiration > now + MaxExpirationDelay:
    return failure("The name record expires too far in the future")

  let recordName = signed.name().valueOr:
    return failure(error.msg)

  if recordName != name:
    return failure("The name is not the hash of the public key and the label")

  ok(signed)
