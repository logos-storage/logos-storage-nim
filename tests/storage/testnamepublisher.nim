import std/sequtils

import pkg/chronos
import pkg/libp2p except setup
import pkg/datastore
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./helpers/mockclock
import ./examples
import ../../storage/discovery
import ../../storage/naming/record
import ../../storage/naming/dht
import ../../storage/naming/publisher {.all.}

type TestNode = object
  switch: Switch
  disc: Discovery

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64
  oneHour = 60 * 60

asyncchecksuite "Name publisher":
  var
    nodes: seq[TestNode]
    publishers: seq[NamePublisher]
    clock: MockClock
    server: TestNode
    secondServer: TestNode
    bootstrapNodes: seq[TestNode]
    metaDs: Datastore
    publisher: NamePublisher

  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    cid = Cid.example
    otherCid = Cid.example

  teardown:
    for startedPublisher in publishers:
      await startedPublisher.stop()

    publishers = @[]

    for node in nodes:
      await node.switch.stop()

    nodes = @[]

  proc startNode(
      clock: Clock, isServer: bool, bootstrap: seq[TestNode] = @[]
  ): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
    let
      switch = newStandardSwitch()
      bootstrapPeers =
        bootstrap.mapIt((it.switch.peerInfo.peerId, it.switch.peerInfo.addrs))
      disc = Discovery.new(
        switch, bootstrapNodes = bootstrapPeers, isServer = isServer, clock = clock
      )

    switch.mount(disc.kad)

    await switch.start()

    let node = TestNode(switch: switch, disc: disc)
    nodes.add(node)

    node

  proc newMetaDs(): Datastore =
    SQLiteDatastore.new(Memory).tryGet()

  proc newPublisher(
      node: TestNode,
      metaDs: Datastore,
      clock: Clock,
      signingKey: PrivateKey = privateKey,
  ): NamePublisher =
    let publisher = NamePublisher.new(node.disc, metaDs, signingKey, clock)
    publishers.add(publisher)

    publisher

  proc dhtKeyFromLabel(label: string): seq[byte] =
    dhtKeyFromName(name(publicKey, label).tryGet()).tryGet()

  # Reads the name record of a label from the DHT and validates it
  proc getFromDht(
      node: TestNode, label: string
  ): Future[SignedNameRecord] {.async: (raises: [CancelledError, CatchableError]).} =
    let
      key = dhtKeyFromLabel(label)
      bytes = (await node.disc.getValue(key)).tryGet()

    validate(name(publicKey, label).tryGet(), bytes, clock.now()).tryGet()

  # Expiration of the name record of a label in the DHT, 0 when there is none
  proc getExpiration(
      node: TestNode, label: string
  ): Future[int64] {.async: (raises: [CancelledError, CatchableError]).} =
    let bytes = (await node.disc.getValue(dhtKeyFromLabel(label))).valueOr:
      return 0

    let signed = validate(name(publicKey, label).tryGet(), bytes, clock.now()).valueOr:
      return 0

    signed.data.expiration

  setup:
    clock = MockClock.new(currentTime)
    server = await startNode(clock, isServer = true)
    # The read quorum is 2, so a read needs two server nodes
    secondServer = await startNode(clock, isServer = true, bootstrap = @[server])
    bootstrapNodes = @[server, secondServer]
    metaDs = newMetaDs()
    publisher = newPublisher(server, metaDs, clock)

    # Wait until the first server knows the second one
    check eventually(server.disc.routingTable().peers.len >= 1, timeout = 10_000)

  test "publishes with the current time as sequence number by default":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.data.version == NameRecordVersion
    check signed.data.label == "catalog"
    check signed.data.cid == cid
    check signed.data.sequenceNumber == currentTime.uint64

  test "publishes with the given sequence number":
    let sequenceNumber = 7'u64

    let signed = (
      await publisher.publish("catalog", cid, sequenceNumber = Opt.some(sequenceNumber))
    ).tryGet()

    check signed.data.sequenceNumber == sequenceNumber

  test "the expiration is 24 hours after the current time":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.data.expiration == currentTime + NameRecordLifetime
    check signed.data.expiration == currentTime + 24 * 60 * 60

  test "the name record is signed with the private key of the publisher":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.envelope.publicKey == publicKey
    check name(signed).tryGet() == name(publicKey, "catalog").tryGet()

  test "another node reads the published name record through the DHT":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    let published = (await publisher.publish("catalog", cid)).tryGet()
    let read = await reader.getFromDht("catalog")

    check read.data == published.data
    check read.envelope.publicKey == publicKey

  test "the publisher puts the name record under the name's DHT key":
    let
      published = (await publisher.publish("catalog", cid)).tryGet()
      dhtKey = dhtKeyFromLabel("catalog")

    let bytes = (await server.disc.getValue(dhtKey)).tryGet()

    check bytes == published.encode()

  test "a publisher that is a client node publishes through a server node":
    let
      client = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      clientPublisher = newPublisher(client, newMetaDs(), clock)

    let published = (await clientPublisher.publish("catalog", cid)).tryGet()

    check (await server.getFromDht("catalog")).data == published.data

    let read = await reader.getFromDht("catalog")

    check read.data == published.data

  test "publishing a newer sequence number replaces the name record":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(1'u64))).isOk

    # This read gives the reader a local copy
    let first = await reader.getFromDht("catalog")

    check first.data.sequenceNumber == 1'u64

    check (await publisher.publish("catalog", otherCid, Opt.some(2'u64))).isOk

    let read = await reader.getFromDht("catalog")

    check read.data.sequenceNumber == 2'u64
    check read.data.cid == otherCid

  test "refuses a sequence number lower than the stored one":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let refused = await publisher.publish("catalog", otherCid, Opt.some(9'u64))

    check refused.isErr

    # The DHT still holds the first name record
    let read = await reader.getFromDht("catalog")

    check read.data.sequenceNumber == 10'u64
    check read.data.cid == cid

  test "accepts the same CID for an existing sequence number":
    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let again = await publisher.publish("catalog", cid, Opt.some(10'u64))

    check again.isOk
    check again.tryGet().data.sequenceNumber == 10'u64

  test "refuses a different CID for an existing sequence number":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(42'u64))).isOk

    let refused = await publisher.publish("catalog", otherCid, Opt.some(42'u64))

    check refused.isErr

    # The DHT still holds the first name record
    let read = await reader.getFromDht("catalog")

    check read.data.sequenceNumber == 42'u64
    check read.data.cid == cid

  test "keeps the name record stored when the DHT put fails":
    # The publisher is a fresh node that lost its previous name record,
    # with sequence number 10.
    # The put fails because the DHT has a newer name record, but the name
    # record stays stored locally.
    let
      newer = NameRecord(
        version: NameRecordVersion,
        label: "catalog",
        cid: otherCid,
        sequenceNumber: 10'u64,
        expiration: currentTime + oneHour,
      )
      newerBytes = newer.sign(privateKey).tryGet().encode()

    check (await server.disc.putValue(dhtKeyFromLabel("catalog"), newerBytes)).isOk
    check (await publisher.publish("catalog", cid, Opt.some(5'u64))).isErr

    let stored = (await publisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].data.cid == cid
    check stored[0].data.sequenceNumber == 5'u64

  test "unpublish deletes the name record":
    check (await publisher.publish("catalog", cid)).isOk

    check (await publisher.unpublish("catalog")).isOk
    check (await publisher.getNameRecords()).tryGet().len == 0

  test "unpublish keeps the other labels":
    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", cid)).isOk

    check (await publisher.unpublish("catalog")).isOk

    let stored = (await publisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].data.label == "release"

  test "unpublish stops extending the expiration in the DHT":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    let published = (await publisher.publish("catalog", cid)).tryGet()

    check (await publisher.unpublish("catalog")).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    # The DHT still holds the expiration of the publication
    check (await reader.getExpiration("catalog")) == published.data.expiration

  test "unpublish of an unknown label does not return an error":
    check (await publisher.unpublish("unknown")).isOk

  test "republishAll extends the expiration with the same CID and sequence number":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)
    let sequenceNumber = 3'u64

    let published =
      (await publisher.publish("catalog", cid, Opt.some(sequenceNumber))).tryGet()

    clock.advance(oneHour)

    await publisher.republishAll()

    let read = await reader.getFromDht("catalog")

    check read.data.cid == cid
    check read.data.sequenceNumber == sequenceNumber
    check read.data.expiration == currentTime + oneHour + NameRecordLifetime
    check read.data.expiration > published.data.expiration
    check read.envelope.publicKey == publicKey

  test "republishAll republishes every stored name record":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", otherCid)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    let
      catalog = await reader.getFromDht("catalog")
      release = await reader.getFromDht("release")

    check catalog.data.expiration == currentTime + oneHour + NameRecordLifetime
    check release.data.expiration == currentTime + oneHour + NameRecordLifetime

  test "start republishes the stored name records right away after a restart":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)
    let sequenceNumber = 3'u64

    check (await publisher.publish("catalog", cid, Opt.some(sequenceNumber))).isOk

    await publisher.stop()

    clock.advance(oneHour)

    let after = newPublisher(server, metaDs, clock)
    after.start()

    let expected = currentTime + oneHour + NameRecordLifetime

    check eventually(
      (await reader.getExpiration("catalog")) == expected, timeout = 10_000
    )

  test "republishAll keeps going when one name record fails":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", cid)).isOk

    # Make the name record that republishAll reads first fail, then check that
    # republishAll goes on to the next one
    let
      stored = (await publisher.getNameRecords()).tryGet()
      failingLabel = stored[0].data.label
      nextLabel = stored[1].data.label

    # The DHT holds a newer name record for this label, so its put fails
    let
      newer = NameRecord(
        version: NameRecordVersion,
        label: failingLabel,
        cid: otherCid,
        sequenceNumber: currentTime.uint64 + 10,
        expiration: currentTime + oneHour,
      )
      newerBytes = newer.sign(privateKey).tryGet().encode()

    check (await server.disc.putValue(dhtKeyFromLabel(failingLabel), newerBytes)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    check (await reader.getExpiration(nextLabel)) ==
      currentTime + oneHour + NameRecordLifetime

  test "republishAll skips the name records signed by another key":
    let
      reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      otherKey = PrivateKey.example
      otherPublicKey = otherKey.getPublicKey().tryGet()
      otherPublisher = newPublisher(server, metaDs, clock, otherKey)

    check (await publisher.publish("catalog", cid)).isOk

    await otherPublisher.republishAll()

    # The name record of the first key is in the DHT
    check (await reader.disc.getValue(dhtKeyFromLabel("catalog"))).isOk

    # The name record of the other key is not in the DHT
    let otherKey = dhtKeyFromName(name(otherPublicKey, "catalog").tryGet()).tryGet()

    check (await reader.disc.getValue(otherKey)).isErr

    # The name record is persisted in the store
    let stored = (await otherPublisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].envelope.publicKey == publicKey

  test "the loop republishes every 4 hours":
    let reader = await startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(3'u64))).isOk

    publisher.start()

    # Ensure that the republish loop is actually a loop
    for round in 1 .. 2:
      # Wait until the loop waits for the next republish
      check eventually(clock.isWaiting, timeout = 10_000)

      clock.advance(RepublishInterval)

      let expected = currentTime + round * RepublishInterval + NameRecordLifetime

      check eventually(
        (await reader.getExpiration("catalog")) == expected, timeout = 10_000
      )

  test "stop stops the loop":
    publisher.start()

    check eventually(clock.isWaiting, timeout = 10_000)

    await publisher.stop()

    check not clock.isWaiting
