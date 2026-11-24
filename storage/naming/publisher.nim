## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/datastore
import pkg/libp2p
import pkg/questionable/results
import pkg/stew/byteutils

import ../clock
import ../discovery
import ../logutils
import ../namespaces
import ./dht
import ./record

export record

logScope:
  topics = "storage naming"

const
  # Seconds. A test build can shorten them, for example with
  # -d:storage_name_republish_interval=900
  RepublishInterval* {.intdefine: "storage_name_republish_interval".} = 4 * 60 * 60
  NameRecordLifetime* {.intdefine: "storage_name_record_lifetime".} = 8 * 60 * 60

type NamePublisherRef* = ref object
  ## Publishes the names of the node to the DHT. The node keeps the name records
  ## it publishes in its metadata store. It republishes them when it starts and
  ## every 4 hours, with a new expiration.
  discovery: Discovery
  metaDs: Datastore
  privateKey: PrivateKey
  clock: Clock
  loop: Future[void]

proc new*(
    T: type NamePublisherRef,
    discovery: Discovery,
    metaDs: Datastore,
    privateKey: PrivateKey,
    clock: Clock,
): NamePublisherRef =
  NamePublisherRef(
    discovery: discovery, metaDs: metaDs, privateKey: privateKey, clock: clock
  )

proc persistenceKeyFromName(name: Name): Key =
  ## The name is raw bytes, so it is written in hex to make a valid key.
  Key.init(StorageNamesNamespace & "/" & byteutils.toHex(name)).expect(
    "The namespace is constant and the name is written in hex"
  )

proc name(self: NamePublisherRef, label: string): Result[Name, ref CatchableError] =
  let publicKey = self.privateKey.getPublicKey().valueOr:
    return failure("Cannot get the public key: " & $error)

  name(publicKey, label)

proc getNameRecord(
    self: NamePublisherRef, key: Key
): Future[Result[Opt[SignedNameRecord], ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  let bytes = (await self.metaDs.get(key)).valueOr:
    if error of DatastoreKeyNotFound:
      return ok(Opt.none(SignedNameRecord))

    return failure("Cannot read the stored name record: " & error.msg)

  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  ok(Opt.some(signed))

proc getNameRecords(
    self: NamePublisherRef
): Future[Result[seq[SignedNameRecord], ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  ## Returns the stored name records. It logs and skips those that don't decode.
  let queryKey =
    Key.init(StorageNamesNamespace & "/*").expect("The query key is constant")

  let iter = (await self.metaDs.query(Query.init(queryKey))).valueOr:
    return failure("Cannot query the stored name records: " & error.msg)

  var records: seq[SignedNameRecord]

  while not iter.finished:
    let item = (await iter.next()).valueOr:
      warn "Cannot read a stored name record", error = error.msg
      break

    if item.key.isNone:
      continue

    let signed = decodeNameRecord(item.data).valueOr:
      warn "Cannot decode a stored name record", error = error.msg
      continue

    records.add(signed)

  let disposed = await iter.dispose()

  if disposed.isErr:
    warn "Cannot dispose the name records query", error = disposed.error.msg

  ok(records)

proc mintNameRecord(
    self: NamePublisherRef, label: string, cid: Cid, seqnum: uint64
): Result[SignedNameRecord, ref CatchableError] =
  ## Builds a name record that expires in `NameRecordLifetime` and signs it.
  let nameRecord = NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: cid,
    seqnum: seqnum,
    expiration: self.clock.now() + NameRecordLifetime,
  )

  sign(nameRecord, self.privateKey)

proc publish*(
    self: NamePublisherRef, label: string, cid: Cid, seqnum = Opt.none(uint64)
): Future[Result[SignedNameRecord, ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  ## Publishes a name record for the label. The seqnum is the current time
  ## unless it is given. It can't be lower than the stored one, and it can only
  ## be equal to it for the same CID. The name record is persisted, then
  ## advertised in the DHT. A failure to advertise is only logged.
  let
    nameBytes = self.name(label).valueOr:
      return err(error)
    persistenceKey = persistenceKeyFromName(nameBytes)
    nameKey = nameKey(nameBytes)
    sequence = seqnum.valueOr:
      self.clock.now().uint64

  let current = (await self.getNameRecord(persistenceKey)).valueOr:
    return err(error)

  if current.isSome:
    let stored = current.get().data

    if sequence < stored.seqnum:
      return failure(
        "The seqnum " & $sequence & " is lower than the stored one: " & $stored.seqnum
      )

    if sequence == stored.seqnum and cid != stored.cid:
      return failure(
        "The seqnum " & $sequence &
          " is already used by the stored name record with another CID"
      )

  let
    signed = self.mintNameRecord(label, cid, sequence).valueOr:
      return err(error)
    bytes = signed.encode()

  let stored = await self.metaDs.put(persistenceKey, bytes)

  if stored.isErr:
    return failure("Cannot store the name record: " & stored.error.msg)

  let advertised = await self.discovery.putValue(nameKey, bytes)

  # The name record is stored, so the next republish advertises it again.
  if advertised.isErr:
    warn "Cannot advertise the name record", label, error = advertised.error.msg

  ok(signed)

proc unpublish*(
    self: NamePublisherRef, label: string
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Deletes the stored name record.
  ## It stays in the DHT until it expires.
  let
    nameBytes = self.name(label).valueOr:
      return err(error)
    persistenceKey = persistenceKeyFromName(nameBytes)

  let deleted = await self.metaDs.delete(persistenceKey)

  if deleted.isErr:
    return failure("Cannot delete the name record: " & deleted.error.msg)

  ok()

proc republish(
    self: NamePublisherRef, nameRecord: NameRecord
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Signs a name record again with a new expiration and advertises it in the DHT.
  let
    signed = self.mintNameRecord(nameRecord.label, nameRecord.cid, nameRecord.seqnum).valueOr:
      return err(error)
    nameKey = nameKey(signed.name())

  await self.discovery.putValue(nameKey, signed.encode())

proc republishAll(self: NamePublisherRef) {.async: (raises: [CancelledError]).} =
  ## Advertises every stored name record in the DHT again with a new expiration.
  ## A failure on one name record is logged and doesn't stop the others.
  ##
  ## The name records signed by another key are skipped. They stay in the store,
  ## in case the node restarts with the key that signed them.
  let publicKey = self.privateKey.getPublicKey().valueOr:
    warn "Cannot republish the name records", error = $error
    return

  let records = (await self.getNameRecords()).valueOr:
    warn "Cannot republish the name records", error = error.msg
    return

  for signed in records:
    if signed.envelope.publicKey != publicKey:
      warn "Not republishing a name record signed by another key",
        label = signed.data.label
      continue

    let published = await self.republish(signed.data)

    if published.isErr:
      warn "Cannot republish a name record",
        label = signed.data.label, error = published.error.msg

proc republishLoop(self: NamePublisherRef) {.async: (raises: [CancelledError]).} =
  while true:
    await self.republishAll()
    await self.clock.waitUntil(self.clock.now() + RepublishInterval)

proc start*(self: NamePublisherRef) =
  ## Republishes the stored name records now, then every `RepublishInterval`.
  if self.loop.isNil:
    self.loop = self.republishLoop()

proc stop*(self: NamePublisherRef) {.async: (raises: []).} =
  if not self.loop.isNil:
    await self.loop.cancelAndWait()
    self.loop = nil
