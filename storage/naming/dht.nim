## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/strutils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/questionable/results
import pkg/stew/arrayops

import ../clock
import ../discovery
import ../logutils
import ../utils/digest
import ./record

export record

logScope:
  topics = "storage naming"

const NameHashCodec* = multiCodec("sha2-256")

type
  NameRecordValidatorRef* = ref object of EntryValidator
    ## The libp2p KadDHT validator for name records. The DHT calls it on each
    ## name record it receives or reads, and drops those that don't pass the
    ## validation.
    clock*: Clock ## The current time, to refuse the expired name records

  NameRecordSelectorRef* = ref object of EntrySelector
    ## The libp2p KadDHT selector for name records. When the DHT has several
    ## name records for a name, it chooses the newest.

proc nameKey*(name: Name): seq[byte] =
  ## The DHT key of the name.
  let
    hash = MultiHash.init(NameHashCodec, name).expect(
        "A name is 32 bytes, the size of a SHA2-256 digest"
      )
    cid = Cid.init(CIDv1, multiCodec("storage-name"), hash).expect(
        "storage-name is a registered content id codec"
      )

  cid.data.buffer

proc parseNameKey*(key: seq[byte]): Result[Name, ref CatchableError] =
  ## The name of a DHT key, the reverse of `nameKey`.
  ## Checks:
  ## - CID: valid (`Cid.init`: digest of 32 bytes, nothing after the CID)
  ## - version: CIDv1
  ## - codec: storage-name
  ## - hash: SHA2-256
  let
    cid = Cid.init(key).valueOr:
      return failure("The key is not a CID: " & $error)
    hash = cid.mhash().valueOr:
      return failure("The CID of the key doesn't have a valid multihash: " & $error)

  if cid.version != CIDv1 or cid.mcodec != multiCodec("storage-name"):
    return failure("The CID of the key is not a CIDv1 of a name")

  if hash.mcodec != NameHashCodec:
    return failure("The multihash of the key is not SHA2-256")

  ok(Name.initCopyFrom(hash.digestBytes))

method isValid*(
    self: NameRecordValidatorRef, key: RecordKey, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  ## The DHT validator of the name records: checks the key with `parseNameKey`,
  ## then the name record with `validate`.

  # The key:
  # - CID: valid (`Cid.init`: digest of 32 bytes, nothing after the CID)
  # - version: CIDv1
  # - codec: storage-name
  # - hash: SHA2-256
  let name = parseNameKey(key.toBytes()).valueOr:
    trace "Refused a name record", error = error.msg

    return false

  # The name record:
  # - signature: valid, domain logos-name-record
  # - payload type: 0xCD05
  # - fields: CBOR types
  # - label: 1 to 256 bytes, UTF-8
  # - cid: CIDv1, 128 bytes at most
  # - version: 1
  # - expiration: not before now
  # - name: SHA2-256(public key, label), equal to the name of the key
  let validated = validate(name, record.value.toBytes(), self.clock.now())

  if validated.isErr:
    trace "Refused a name record", error = validated.error.msg

    return false

  true

method select*(
    self: NameRecordSelectorRef, key: RecordKey, records: seq[EntryRecord]
): LPResult[int] {.raises: [], gcsafe.} =
  ## Returns the index of the newest name record. Name records that don't decode
  ## are skipped.
  ##
  ## When name records have the same seqnum and the same expiration, the first
  ## one in the list is selected.
  ##
  ## When the DHT stores a name record, `records` is a list of two items,
  ## [received, stored]. If the received name record has the same seqnum as the
  ## stored one and doesn't expire earlier, the received one is selected, so
  ## that the DHT replaces its copy and restarts its retention window (24 hours
  ## by default, see [DefaultRecordExpirationInterval]). This window is not the
  ## expiration of the name record.
  ##
  ## When name records have the same seqnum and another CID, the last one in the
  ## list is selected. When the DHT stores a name record, the stored one stays.
  ##
  ## When the DHT reads a name, `records` holds the name records of other peers
  ## and the node's own copy.
  var
    newestIndex = -1
    newest: NameRecord

  for i, entry in records:
    let signed = decodeNameRecord(entry.value.toBytes()).valueOr:
      continue

    # A conflict is detected when 2 records have the same seqnum with
    # a different CID.
    let conflicts =
      newestIndex >= 0 and signed.data.seqnum == newest.seqnum and
      signed.data.cid != newest.cid

    # Here there are 3 cases:
    #  1. newestIndex = -1: this is the first iteration, so we set
    #     newestIndex to the first item, 0.
    #  2. A conflict is detected (same seqnum, another CID): newestIndex is
    #     updated to the current item, so the last one in the list wins. For a
    #     put, the list is [received, stored], so the stored record stays and
    #     the conflicting one is refused.
    #  3. The record `isNewer`: a higher seqnum, or the same seqnum and a
    #     later expiration.
    if newestIndex < 0 or conflicts or signed.data.isNewer(newest):
      newestIndex = i
      newest = signed.data

  if newestIndex < 0:
    return err("None of the name records to choose from is valid")

  ok(newestIndex)

proc isNoNameRecordError*(error: ref CatchableError): bool =
  error.msg.endsWith(NoValidRecords)

proc resolve*(
    discovery: Discovery, name: Name
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Reads the name record of the name in the DHT and returns its CID. It doesn't
  ## return a CID when the DHT doesn't have a name record for the name.
  ##
  ## The DHT validator has already checked the name record, so it is only
  ## decoded here.
  # `getValue` (libp2p/protocols/kademlia/get.nim):
  # - `isValid` on the stored name record and each reply
  # - `select` on the valid ones
  let bytes = (await discovery.getValue(nameKey(name))).valueOr:
    if error.isNoNameRecordError:
      return ok(Opt.none(Cid))

    return err(error)

  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  ok(Opt.some(signed.data.cid))

proc resolve*(
    discovery: Discovery, publicKey: PublicKey, label: string
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Resolves the name of the public key and the label.
  let nameBytes = name(publicKey, label).valueOr:
    return err(error)

  await discovery.resolve(nameBytes)

proc refresh*(
    discovery: Discovery, name: Name, bytes: seq[byte]
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Advertises a signed name record of the name in the DHT. The name record
  ## can be signed by another key than the node's key, and the node doesn't
  ## keep it in its metadata store. It fails when the name record is not valid,
  ## when the node holds a newer one, or when no peer stores it.
  # `putValue` (libp2p/protocols/kademlia/put.nim):
  # - `isValid` on the name record
  # - `select` on [name record, stored name record]
  # - each peer that receives it runs `isValid` and `select` too
  let advertised = await discovery.putValue(nameKey(name), bytes)

  if advertised.isErr:
    warn "Cannot advertise the name record", error = advertised.error.msg

    return err(advertised.error)

  ok()
