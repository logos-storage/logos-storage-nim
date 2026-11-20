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
import ../utils/digest
import ./record

export record

const
  NameHashCodec* = multiCodec("sha2-256")
  NoNameRecordError = "No valid records found"

type
  NameRecordValidator* = ref object of EntryValidator
    ## The libp2p KadDHT validator for name records. The DHT calls it on each
    ## name record it receives or reads, and drops those that don't pass the
    ## validation.
    clock*: Clock

  NameRecordSelector* = ref object of EntrySelector
    ## The libp2p KadDHT selector for name records. When the DHT has several
    ## name records for a name, it chooses the newest.

proc nameKey*(name: Name): Key =
  ## The name key of the protocol spec: the name CID, used as key in the DHT.
  let
    hash = MultiHash.init(NameHashCodec, name).expect(
        "A name is 32 bytes, the size of a SHA2-256 digest"
      )
    cid = Cid.init(CIDv1, multiCodec("storage-name"), hash).expect(
        "storage-name is a registered content id codec"
      )

  cid.data.buffer

proc nameFromNameKey(key: Key): Result[Name, ref CatchableError] =
  ## Refuses a key with another CID version, codec or hash function than
  ## `nameKey`.
  let
    cid = Cid.init(key).valueOr:
      return failure("The key is not a CID: " & $error)
    hash = cid.mhash().valueOr:
      return failure("The CID of the key has no valid multihash: " & $error)

  if cid.version != CIDv1 or cid.mcodec != multiCodec("storage-name"):
    return failure("The CID of the key is not a CIDv1 of a name")

  if hash.mcodec != NameHashCodec:
    return failure("The multihash of the key is not SHA2-256")

  ok(Name.initCopyFrom(hash.digestBytes))

method isValid*(
    self: NameRecordValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  let name = nameFromNameKey(key).valueOr:
    return false

  validate(name, record.value, self.clock.now()).isOk

method select*(
    self: NameRecordSelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.raises: [], gcsafe.} =
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
  ## When the DHT reads a name, `records` is a list of items from other peers.
  var
    newestIndex = -1
    newest: NameRecord

  for i, entry in records:
    let signed = decodeNameRecord(entry.value).valueOr:
      continue

    if newestIndex < 0 or signed.data.isNewer(newest):
      newestIndex = i
      newest = signed.data

  if newestIndex < 0:
    return err("No valid name record to choose from")

  ok(newestIndex)

proc resolve*(
    discovery: Discovery, name: Name
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Reads the name record of the name in the DHT and returns its CID. Returns no
  ## CID when the DHT has no name record for the name.
  ##
  ## The DHT validator has already checked the name record, so it is only
  ## decoded here: see [NameRecordValidator] and `getValue` in
  ## libp2p/protocols/kademlia/get.nim.
  let bytes = (await discovery.getValue(nameKey(name))).valueOr:
    if error.msg.endsWith(NoNameRecordError):
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
    discovery: Discovery, name: Name
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Advertises the name record of the name in the DHT again, without changing
  ## it. It doesn't need the private key of the publisher.
  ##
  ## The DHT validator has already checked the name record, so an expired or
  ## invalid one is never advertised: see [NameRecordValidator] and `getValue` in
  ## libp2p/protocols/kademlia/get.nim.
  let key = nameKey(name)

  let bytes = (await discovery.getValue(key)).valueOr:
    return err(error)

  await discovery.putValue(key, bytes)
