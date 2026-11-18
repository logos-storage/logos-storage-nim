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
import pkg/datastore/typedds
import pkg/libp2p
import pkg/questionable/results
import pkg/stew/byteutils

import ../clock
import ../discovery
import ../logutils
import ../namespaces
import ./record

export record

logScope:
  topics = "storage naming"

const
  RepublishInterval* = 4 * 60 * 60 # seconds
  NameRecordLifetime* = 24 * 60 * 60 # seconds

type NamePublisher* = ref object
  ## Publishes the names of the node to the DHT. The name records the node
  ## publishes are persisted in the metadata store. They are republished when
  ## the node starts and every 4 hours, with a new expiration.
  discovery: Discovery
  metaDs: TypedDatastore
  privateKey: PrivateKey
  clock: Clock
  loop: Future[void]

proc new*(
    T: type NamePublisher,
    discovery: Discovery,
    metaDs: TypedDatastore,
    privateKey: PrivateKey,
    clock: Clock,
): NamePublisher =
  NamePublisher(
    discovery: discovery, metaDs: metaDs, privateKey: privateKey, clock: clock
  )

proc storageKey(name: Name): Result[Key, ref CatchableError] =
  ## The name is raw bytes, so it is written in hex to make a valid key.
  let key = Key.init(StorageNamesNamespace & "/" & byteutils.toHex(name)).valueOr:
    return failure("Cannot make the storage key of the name record: " & error.msg)

  ok(key)

proc nameAndStorageKey(
    self: NamePublisher, label: string
): Result[tuple[name: Name, key: Key], ref CatchableError] =
  let publicKey = self.privateKey.getPublicKey().valueOr:
    return failure("Cannot get the public key: " & $error)

  let nameBytes = name(publicKey, label).valueOr:
    return err(error)

  let key = storageKey(nameBytes).valueOr:
    return err(error)

  ok((name: nameBytes, key: key))

proc getNameRecord(
    self: NamePublisher, key: Key
): Future[Result[Opt[SignedNameRecord], ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  let bytes = (await self.metaDs.ds.get(key)).valueOr:
    if error of DatastoreKeyNotFound:
      return ok(Opt.none(SignedNameRecord))

    return failure("Cannot read the stored name record: " & error.msg)

  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  ok(Opt.some(signed))

proc getNameRecords(
    self: NamePublisher
): Future[Result[seq[SignedNameRecord], ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  ## Every stored name record. Those that don't decode are logged and skipped.
  let queryKey = Key.init(StorageNamesNamespace & "/*").valueOr:
    return failure("Cannot make the query key of the name records: " & error.msg)

  let iter = (await self.metaDs.ds.query(Query.init(queryKey))).valueOr:
    return failure("Cannot query the stored name records: " & error.msg)

  var records: seq[SignedNameRecord]

  while not iter.finished:
    let item = (await iter.next()).valueOr:
      warn "Cannot read a stored name record", error = error.msg
      break

    let signed = decodeNameRecord(item.data).valueOr:
      warn "Cannot decode a stored name record", error = error.msg
      continue

    records.add(signed)

  let disposed = await iter.dispose()

  if disposed.isErr:
    warn "Cannot dispose the name records query", error = disposed.error.msg

  ok(records)

proc mintNameRecord(
    self: NamePublisher, label: string, cid: Cid, sequenceNumber: uint64
): Result[SignedNameRecord, ref CatchableError] =
  ## Builds a name record that expires in `NameRecordLifetime` and signs it.
  let nameRecord = NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: cid,
    sequenceNumber: sequenceNumber,
    expiration: self.clock.now() + NameRecordLifetime,
  )

  sign(nameRecord, self.privateKey)

proc publish*(
    self: NamePublisher, label: string, cid: Cid, sequenceNumber = Opt.none(uint64)
): Future[Result[SignedNameRecord, ref CatchableError]] {.
    async: (raises: [CancelledError])
.} =
  ## Publishes a name record for the label. The sequence number is the current
  ## time unless it is given. It can't be lower than the stored one. The name
  ## record is stored, then put in the DHT.
  let target = self.nameAndStorageKey(label).valueOr:
    return err(error)

  let key = target.key

  let sequence = sequenceNumber.valueOr:
    self.clock.now().uint64

  let current = (await self.getNameRecord(key)).valueOr:
    return err(error)

  if current.isSome and sequence < current.get().data.sequenceNumber:
    return failure(
      "The sequence number " & $sequence & " is lower than the stored one: " &
        $current.get().data.sequenceNumber
    )

  let
    signed = self.mintNameRecord(label, cid, sequence).valueOr:
      return err(error)
    bytes = signed.encode()

  let stored = await self.metaDs.ds.put(key, bytes)

  if stored.isErr:
    return failure("Cannot store the name record: " & stored.error.msg)

  let put = await self.discovery.putValue(@(target.name), bytes)

  if put.isErr:
    return err(put.error)

  ok(signed)

proc unpublish*(
    self: NamePublisher, label: string
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Deletes the stored name record.
  ## It stays in the DHT until it expires.
  let target = self.nameAndStorageKey(label).valueOr:
    return err(error)

  let deleted = await self.metaDs.ds.delete(target.key)

  if deleted.isErr:
    return failure("Cannot delete the name record: " & deleted.error.msg)

  ok()

proc republish(
    self: NamePublisher, nameRecord: NameRecord
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Signs a name record again with a new expiration and puts it in the DHT.
  let
    signed = self.mintNameRecord(
      nameRecord.label, nameRecord.cid, nameRecord.sequenceNumber
    ).valueOr:
      return err(error)
    nameBytes = signed.name().valueOr:
      return err(error)

  await self.discovery.putValue(@nameBytes, signed.encode())

proc republishAll*(self: NamePublisher) {.async: (raises: [CancelledError]).} =
  ## Puts every stored name record in the DHT again with a new expiration.
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

proc republishLoop(self: NamePublisher) {.async: (raises: [CancelledError]).} =
  await self.republishAll()

  while true:
    await self.clock.waitUntil(self.clock.now() + RepublishInterval)
    await self.republishAll()

proc start*(self: NamePublisher) =
  ## Republishes the stored name records now, then every `RepublishInterval`.
  if self.loop.isNil:
    self.loop = self.republishLoop()

proc stop*(self: NamePublisher) {.async: (raises: []).} =
  if not self.loop.isNil:
    await self.loop.cancelAndWait()
    self.loop = nil
