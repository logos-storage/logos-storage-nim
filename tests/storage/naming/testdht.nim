import std/tables

import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/protocols/kademlia
import pkg/libp2p/vbuffer
import pkg/datastore
import pkg/questionable/results

import ../../asynctest
import ../../checktest
import ../helpers
import ../helpers/mockclock
import ../examples
import ../helpers/dhtnodes
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
    publisher: NamePublisherRef
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
    publisher = NamePublisherRef.new(
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

asyncchecksuite "Name refresh with a signed name record":
  var
    clock: MockClock
    server: TestNode
    reader: TestNode

  let
    nodes = TestNodes()
    # The key of a CI: it is not the key of the node
    ciKey = PrivateKey.example
    ciPublicKey = ciKey.getPublicKey().tryGet()
    catalogName = name(ciPublicKey, "catalog").tryGet()
    key = nameKey(catalogName)

  teardown:
    await nodes.stop()

  setup:
    clock = MockClock.new(currentTime)

    server = await nodes.startNode(clock, isServer = true)
    reader = await nodes.startNode(clock, isServer = false, bootstrap = @[server])

  proc signedBytes(
      seqnum: uint64,
      expiration: int64,
      label = "catalog",
      recordCid = Cid.example,
      signingKey = ciKey,
  ): seq[byte] =
    SignedNameRecord.init(signingKey, newRecord(seqnum, expiration, label, recordCid))
    .tryGet()
    .encode()

  test "advertises a name record signed by another key than the key of the node":
    let
      recordCid = Cid.example
      bytes = signedBytes(1, currentTime + 3600, recordCid = recordCid)

    check (await refresh(server.disc, catalogName, bytes)).isOk

    let resolved = (await reader.disc.resolve(catalogName)).tryGet()

    check resolved.get() == recordCid

  test "a name record with the same seqnum and CID that expires later replaces the stored one":
    let
      recordCid = Cid.example
      first = signedBytes(1, currentTime + 3600, recordCid = recordCid)
      second = signedBytes(1, currentTime + 7200, recordCid = recordCid)

    check (await refresh(server.disc, catalogName, first)).isOk
    check (await refresh(server.disc, catalogName, second)).isOk

    let stored = (await server.disc.getValue(key)).tryGet()

    check decodeNameRecord(stored).tryGet().data.expiration == currentTime + 7200

  test "refuses a name record signed by another key than the key of the name":
    let bytes = signedBytes(1, currentTime + 3600, signingKey = PrivateKey.example)

    let res = await refresh(server.disc, catalogName, bytes)

    check res.isErr

  test "refuses an older name record when the node holds a newer one":
    let
      newer = signedBytes(2, currentTime + 3600)
      older = signedBytes(1, currentTime + 3600)

    check (await refresh(server.disc, catalogName, newer)).isOk

    let res = await refresh(server.disc, catalogName, older)

    check res.isErr

    check (await server.disc.getValue(key)).tryGet() == newer

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
    selector = NameRecordSelectorRef()
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

  proc sha256Key(digest: seq[byte]): RecordKey =
    ## A name key written by hand, since MultiHash.init refuses a digest of
    ## another length.
    var buffer = initVBuffer()
    buffer.writeVarint(1'u64)
    buffer.writeVarint(uint64(int(multiCodec("storage-name"))))
    buffer.writeVarint(uint64(int(multiCodec("sha2-256"))))
    buffer.writeVarint(uint64(digest.len))
    buffer.writeArray(digest)
    buffer.finish()

    RecordKey.fromBytes(buffer.buffer).tryGet()

  test "accepts a valid name record under the name key":
    let validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))

    check validator.isValid(key, EntryRecord(value: signedBytes()))

  test "refuses a key that is not a CID":
    let validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))

    let shortKey = RecordKey.fromBytes(nameKey(catalogName)[0 ..< 5]).tryGet()

    check not validator.isValid(shortKey, EntryRecord(value: signedBytes()))

  test "refuses a CIDv1 with the right digest and another codec":
    let
      validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))
      otherKey = cidKey(multiCodec("raw"), multiCodec("sha2-256"), @catalogName)

    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a CID with the right codec and another hash function":
    let
      validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))
      otherKey =
        cidKey(multiCodec("storage-name"), multiCodec("blake2b-256"), @catalogName)

    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a CID with a SHA2-256 digest that is not 32 bytes":
    let validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))

    check validator.isValid(sha256Key(@catalogName), EntryRecord(value: signedBytes()))
    check not validator.isValid(
      sha256Key(@(catalogName[0 ..< 31])), EntryRecord(value: signedBytes())
    )
    check not validator.isValid(
      sha256Key(@catalogName & @[0'u8]), EntryRecord(value: signedBytes())
    )

  test "refuses a valid name record stored under the name of another label":
    let validator = NameRecordValidatorRef(clock: MockClock.new(currentTime))

    check not validator.isValid(key, EntryRecord(value: signedBytes(label = "release")))

  test "refuses a name record once the clock is past its expiration":
    let
      clock = MockClock.new(currentTime)
      validator = NameRecordValidatorRef(clock: clock)
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
