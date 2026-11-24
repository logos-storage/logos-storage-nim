import std/tables

import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/protocols/kademlia
import pkg/datastore
import pkg/questionable/results

import ../../asynctest
import ../../checktest
import ../helpers
import ../helpers/mockclock
import ../examples
import ./namenodes
import ../../../storage/discovery
import ../../../storage/naming/record
import ../../../storage/naming/publisher
import ../../../storage/naming/dht

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64
  # 10:00:00 UTC on 12 November 2026
  tenOClock = 1794477600'i64
  # 14:00:00 UTC on 12 November 2026
  twoOClock = 1794492000'i64

proc newRecord(
    seqnum: uint64, expiration: int64, label = "catalog", cid = Cid.example
): NameRecord =
  NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: cid,
    seqnum: seqnum,
    expiration: expiration,
  )

asyncchecksuite "Name resolver":
  var
    clock: MockClock
    server: TestNode
    publisher: NamePublisher
    reader: TestNode

  let
    nodes = TestNodes()
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    cid = Cid.example
    otherCid = Cid.example

  teardown:
    await nodes.stop()

  setup:
    clock = MockClock.new(currentTime)

    server = await nodes.startNode(clock, isServer = true)
    publisher = NamePublisher.new(
      server.disc, SQLiteDatastore.new(Memory).tryGet(), privateKey, clock
    )

    reader = await nodes.startNode(clock, isServer = false, bootstrap = @[server])

  test "resolves a name published by another node":
    check (await publisher.publish("catalog", cid)).isOk

    let catalogName = name(publicKey, "catalog").tryGet()

    let resolved = (await reader.disc.resolve(catalogName)).tryGet()

    check resolved.isSome
    check resolved.get() == cid

  test "resolves the CID published under a public key and a label":
    check (await publisher.publish("catalog", cid)).isOk

    let resolved = (await reader.disc.resolve(publicKey, "catalog")).tryGet()

    check resolved.get() == cid

  test "resolves the CID of the newest name record":
    check (await publisher.publish("catalog", cid, Opt.some(1'u64))).isOk

    # This resolve gives the reader a local copy
    let first = (await reader.disc.resolve(publicKey, "catalog")).tryGet()

    check first.get() == cid

    check (await publisher.publish("catalog", otherCid, Opt.some(2'u64))).isOk

    let newest = (await reader.disc.resolve(publicKey, "catalog")).tryGet()

    check newest.get() == otherCid

  test "doesn't return a CID when the DHT doesn't have a name record for the name":
    let unknownName = name(publicKey, "unknown").tryGet()

    let resolved = await reader.disc.resolve(unknownName)

    check resolved.isOk
    check resolved.tryGet().isNone

  test "returns an error for an empty label":
    check (await reader.disc.resolve(publicKey, "")).isErr

asyncchecksuite "Name refresh":
  var
    clock: MockClock
    server: TestNode
    publisher: NamePublisher
    refresher: TestNode

  let
    nodes = TestNodes()
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    cid = Cid.example

  teardown:
    await nodes.stop()

  # Starts a server node after the publish, then waits until the server of the
  # publisher knows it.
  proc startLateNode(): Future[TestNode] {.
      async: (raises: [CancelledError, LPError, AsyncExceptionError])
  .} =
    let late = await nodes.startNode(clock, isServer = true, bootstrap = @[server])

    check eventually(server.disc.routingTable().peers.len >= 1, timeout = 10_000)

    late

  setup:
    clock = MockClock.new(currentTime)

    server = await nodes.startNode(clock, isServer = true)
    publisher = NamePublisher.new(
      server.disc, SQLiteDatastore.new(Memory).tryGet(), privateKey, clock
    )

    refresher = await nodes.startNode(clock, isServer = false, bootstrap = @[server])

  test "a node that joins after the publish gets the same name record after a refresh":
    check (await publisher.publish("catalog", cid)).isOk

    let
      catalogName = name(publicKey, "catalog").tryGet()
      key = nameKey(catalogName)
      recordKey = RecordKey.fromBytes(key).tryGet()

    let
      published = (await server.disc.getValue(key)).tryGet()
      late = await startLateNode()

    check not late.disc.kad.dataTable.hasKey(recordKey)

    check (await refresh(refresher.disc, catalogName)).isOk

    check late.disc.kad.dataTable.hasKey(recordKey)
    check late.disc.kad.dataTable[recordKey].value.toBytes() == published

  test "returns an error and doesn't advertise anything when the name record has expired":
    check (await publisher.publish("catalog", cid)).isOk

    let
      catalogName = name(publicKey, "catalog").tryGet()
      recordKey = RecordKey.fromBytes(nameKey(catalogName)).tryGet()

    let late = await startLateNode()

    clock.advance(NameRecordLifetime + 1)

    check (await refresh(refresher.disc, catalogName)).isErr
    check not late.disc.kad.dataTable.hasKey(recordKey)

  test "returns an error when the DHT doesn't have a name record for the name":
    let unknownName = name(publicKey, "unknown").tryGet()

    check (await refresh(refresher.disc, unknownName)).isErr

asyncchecksuite "Name records in the DHT":
  var clock: MockClock

  let
    nodes = TestNodes()
    privateKey = PrivateKey.example

  teardown:
    await nodes.stop()

  proc newKey(label: string): seq[byte] =
    nameKey(name(privateKey.getPublicKey().tryGet(), label).tryGet())

  proc newValue(label: string, seqnum: uint64): seq[byte] =
    let record = NameRecord(
      version: NameRecordVersion,
      label: label,
      cid: Cid.example,
      seqnum: seqnum,
      expiration: currentTime + 3600,
    )

    sign(record, privateKey).tryGet().encode()

  setup:
    clock = MockClock.new(currentTime)

  test "a put with an older seqnum doesn't replace the value":
    let
      serverA = await nodes.startNode(clock, isServer = true)
      serverB = await nodes.startNode(clock, isServer = true, bootstrap = @[serverA])
      bootstrapNodes = @[serverA, serverB]
      writer =
        await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      # It never gets the newer value
      olderWriter =
        await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      key = newKey("older-put")
      value = newValue("older-put", 2)
      olderValue = newValue("older-put", 1)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await writer.disc.putValue(key, value)).isOk
    check olderWriter.disc.routingTable().peers.len == 2
    # The servers keep the newer value and refuse this put, so it fails
    check (await olderWriter.disc.putValue(key, olderValue)).isErr

    let recordKey = RecordKey.fromBytes(key).tryGet()

    check olderWriter.disc.kad.dataTable.get(recordKey).get().value.toBytes() ==
      olderValue
    check serverA.disc.kad.dataTable.get(recordKey).get().value.toBytes() == value
    check serverB.disc.kad.dataTable.get(recordKey).get().value.toBytes() == value

  test "putValue refuses a name record stored under the name of another label":
    let
      server = await nodes.startNode(clock, isServer = true)
      writer = await nodes.startNode(clock, isServer = false, bootstrap = @[server])
      key = newKey("catalog")

    check (await writer.disc.putValue(key, newValue("release", 1))).isErr

checksuite "Name record selector":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    key = RecordKey.fromBytes(@(name(publicKey, "catalog").tryGet())).tryGet()
    selector = NameRecordSelector()
    cid = Cid.example
    otherCid = Cid.example

  proc signedBytes(seqnum: uint64, expiration: int64, recordCid = cid): Value =
    let signed =
      SignedNameRecord.init(privateKey, newRecord(seqnum, expiration, cid = recordCid))

    Value.init(signed.tryGet().encode())

  test "selects the newest name record wherever it is in the list":
    let
      newest = EntryRecord(value: signedBytes(43'u64, tenOClock))
      older = EntryRecord(value: signedBytes(42'u64, twoOClock))
      oldest = EntryRecord(value: signedBytes(41'u64, twoOClock))

    check selector.select(key, @[newest, older, oldest]).tryGet() == 0
    check selector.select(key, @[older, newest, oldest]).tryGet() == 1
    check selector.select(key, @[oldest, older, newest]).tryGet() == 2

  test "keeps the first name record when both have the same fields":
    let
      first = EntryRecord(value: signedBytes(42'u64, tenOClock))
      second = EntryRecord(value: signedBytes(42'u64, tenOClock))

    check selector.select(key, @[first, second]).tryGet() == 0

  test "keeps the last name record when both have the same seqnum and another CID":
    let
      expiresLater = EntryRecord(value: signedBytes(42'u64, twoOClock, otherCid))
      expiresEarlier = EntryRecord(value: signedBytes(42'u64, tenOClock))

    # When the DHT stores a name record, the list is [received, stored]: the
    # stored one stays, even when the received one expires later.
    check selector.select(key, @[expiresLater, expiresEarlier]).tryGet() == 1
    check selector.select(key, @[expiresEarlier, expiresLater]).tryGet() == 1

  test "skips a name record that doesn't decode":
    let
      undecodable = EntryRecord(value: Value.init(@[1'u8, 2, 3]))
      older = EntryRecord(value: signedBytes(41'u64, twoOClock))
      valid = EntryRecord(value: signedBytes(42'u64, tenOClock))

    check selector.select(key, @[undecodable, valid]).tryGet() == 1
    check selector.select(key, @[older, undecodable, valid]).tryGet() == 2

  test "fails when none of the name records decodes":
    let undecodable = EntryRecord(value: Value.init(@[1'u8, 2, 3]))

    check selector.select(key, @[undecodable, undecodable]).isErr

checksuite "Name record validator":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    catalogName = name(publicKey, "catalog").tryGet()
    key = RecordKey.fromBytes(nameKey(catalogName)).tryGet()

  proc signedBytes(label = "catalog", expiration = currentTime + 3600): Value =
    let signed = SignedNameRecord.init(privateKey, newRecord(42'u64, expiration, label))

    Value.init(signed.tryGet().encode())

  proc cidKey(codec: MultiCodec, hashCodec: MultiCodec, digest: seq[byte]): RecordKey =
    let
      hash = MultiHash.init(hashCodec, digest).tryGet()
      cid = Cid.init(CIDv1, codec, hash).tryGet()

    RecordKey.fromBytes(cid.data.buffer).tryGet()

  test "accepts a valid name record under the name key":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check validator.isValid(key, EntryRecord(value: signedBytes()))

  test "refuses a key that is not a CID":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    let shortKey = RecordKey.fromBytes(nameKey(catalogName)[0 ..< 5]).tryGet()

    check not validator.isValid(shortKey, EntryRecord(value: signedBytes()))

  test "refuses a CIDv1 with the right digest and another codec":
    let
      validator = NameRecordValidator(clock: MockClock.new(currentTime))
      otherKey = cidKey(multiCodec("raw"), multiCodec("sha2-256"), @catalogName)

    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a CID with the right codec and another hash function":
    let
      validator = NameRecordValidator(clock: MockClock.new(currentTime))
      otherKey =
        cidKey(multiCodec("storage-name"), multiCodec("blake2b-256"), @catalogName)

    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a valid name record stored under the name of another label":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key, EntryRecord(value: signedBytes(label = "release")))

  test "refuses a name record once the clock is past its expiration":
    let
      clock = MockClock.new(currentTime)
      validator = NameRecordValidator(clock: clock)
      record = EntryRecord(value: signedBytes(expiration = currentTime + 3600))

    check validator.isValid(key, record)

    clock.set(currentTime + 3601)

    check not validator.isValid(key, record)

checksuite "Name key":
  let
    publicKey = PrivateKey.example.getPublicKey().tryGet()
    catalogName = name(publicKey, "catalog").tryGet()
    key = nameKey(catalogName)

  test "the key is a CIDv1 with the storage-name codec and a SHA2-256 multihash":
    let
      cid = Cid.init(key).tryGet()
      hash = cid.mhash().tryGet()

    check cid.version == CIDv1
    check cid.mcodec == multiCodec("storage-name")
    check hash.mcodec == multiCodec("sha2-256")
    check hash.data.buffer[hash.dpos ..< hash.dpos + hash.size] == @catalogName
