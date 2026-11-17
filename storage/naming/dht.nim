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
import pkg/results
import pkg/stew/arrayops

import ../clock
import ./record

type
  NameRecordValidator* = ref object of EntryValidator
    ## The libp2p KadDHT validator for name records. The DHT calls it on each
    ## name record it receives or reads, and drops the name records whose key is
    ## not a name or that don't pass the validation.
    clock*: Clock

  NameRecordSelector* = ref object of EntrySelector
    ## The libp2p KadDHT selector for name records. When the DHT has several
    ## name records for a name, it calls it to choose one: the newest, by
    ## `isNewer`.

method isValid*(
    self: NameRecordValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  if key.len != Name.len:
    return false

  let name = Name.initCopyFrom(key)

  validate(name, record.value, self.clock.now()).isOk

method select*(
    self: NameRecordSelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.raises: [], gcsafe.} =
  ## Returns the index of the newest name record. Name records that don't decode
  ## are skipped.
  ##
  ## When name records have the same sequence number and the same expiration,
  ## the first one in the list is selected.
  ##
  ## When the DHT stores a name record, `records` is a list of two items,
  ## [received, stored]. If the node receives a name record it already stores,
  ## the received one is selected, so that the name record is replaced and its
  ## 24-hour window restarts, see [DefaultRecordExpirationInterval].
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
