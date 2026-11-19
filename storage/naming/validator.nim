## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/libp2p/multihash
import pkg/questionable/results
import pkg/stew/arrayops

import ../clock
import ../utils/digest
import ./record

const NameHashCodec* = multiCodec("sha2-256")

type
  NameRecordValidator* = ref object of EntryValidator
    ## The libp2p KadDHT validator for name records. The DHT calls it on each
    ## name record it receives or reads, and drops those that don't pass the
    ## validation.
    clock*: Clock

  NameRecordSelector* = ref object of EntrySelector
    ## The libp2p KadDHT selector for name records. When the DHT has several
    ## name records for a name, it chooses the newest.

proc nameFromNameKey*(key: Key): Result[Name, ref CatchableError] =
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
