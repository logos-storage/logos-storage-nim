import std/sequtils

import pkg/chronos
import pkg/libp2p except setup
from pkg/libp2p/protocols/kademlia/get import getValue
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./helpers/mockclock
import ./examples
import ../../storage/discovery
import ../../storage/naming/record
import ../../storage/naming/publisher {.all.}

type TestNode = object
  switch: Switch
  disc: Discovery

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64
  fourHours = 4 * 60 * 60
  oneHour = 60 * 60

asyncchecksuite "Name publisher":
  var
    nodes: seq[TestNode]
    publishers: seq[NamePublisher]
    clock: MockClock
    server: TestNode
    metaDs: TypedDatastore
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
      bootstrapNodes =
        bootstrap.mapIt((it.switch.peerInfo.peerId, it.switch.peerInfo.addrs))
      disc = Discovery.new(
        switch, bootstrapNodes = bootstrapNodes, isServer = isServer, clock = clock
      )

    switch.mount(disc.kad)

    await switch.start()

    let node = TestNode(switch: switch, disc: disc)
    nodes.add(node)

    node

  proc newMetaDs(): TypedDatastore =
    TypedDatastore.init(SQLiteDatastore.new(Memory).tryGet())

  proc newPublisher(
      node: TestNode, metaDs: TypedDatastore, clock: Clock
  ): NamePublisher =
    let publisher = NamePublisher.new(node.disc, metaDs, privateKey, clock)
    publishers.add(publisher)

    publisher

  proc nameKey(label: string): seq[byte] =
    @(name(publicKey, label).tryGet())

  # Reads the name record of a label from the DHT and validates it
  proc getNameRecord(
      node: TestNode, label: string
  ): Future[SignedNameRecord] {.async: (raises: [CancelledError, CatchableError]).} =
    let
      key = nameKey(label)
      bytes = (await node.disc.getValue(key)).tryGet()

    validate(name(publicKey, label).tryGet(), bytes, clock.now()).tryGet()

  # Expiration of the name record of a label in the DHT, 0 when there is none
  proc getExpiration(
      node: TestNode, label: string
  ): Future[int64] {.async: (raises: [CancelledError, CatchableError]).} =
    # A quorum of 2 also asks the other peers, not only the local copy
    let quorum = Opt.some(2)
    let entry = (await node.disc.kad.getValue(nameKey(label), quorum)).valueOr:
      return 0

    let signed = validate(name(publicKey, label).tryGet(), entry.value, clock.now()).valueOr:
      return 0

    signed.data.expiration

  setup:
    clock = MockClock.new(currentTime)
    server = await startNode(clock, isServer = true)
    metaDs = newMetaDs()
    publisher = newPublisher(server, metaDs, clock)

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
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])

    let published = (await publisher.publish("catalog", cid)).tryGet()
    let read = await reader.getNameRecord("catalog")

    check read.data == published.data
    check read.envelope.publicKey == publicKey

  test "a publisher that is a client node publishes through a server node":
    let
      client = await startNode(clock, isServer = false, bootstrap = @[server])
      reader = await startNode(clock, isServer = false, bootstrap = @[server])
      clientPublisher = newPublisher(client, newMetaDs(), clock)

    let published = (await clientPublisher.publish("catalog", cid)).tryGet()

    check (await server.getNameRecord("catalog")).data == published.data

    let read = await reader.getNameRecord("catalog")

    check read.data == published.data

  test "publishing a newer sequence number replaces the name record":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])

    check (await publisher.publish("catalog", cid, Opt.some(1'u64))).isOk
    check (await publisher.publish("catalog", otherCid, Opt.some(2'u64))).isOk

    let read = await reader.getNameRecord("catalog")

    check read.data.sequenceNumber == 2'u64
    check read.data.cid == otherCid

  test "refuses a sequence number lower than the stored one":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])

    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let refused = await publisher.publish("catalog", otherCid, Opt.some(9'u64))

    check refused.isErr

    # The DHT still holds the first name record
    let read = await reader.getNameRecord("catalog")

    check read.data.sequenceNumber == 10'u64
    check read.data.cid == cid

  test "accepts a sequence number equal to the stored one":
    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let again = await publisher.publish("catalog", cid, Opt.some(10'u64))

    check again.isOk
    check again.tryGet().data.sequenceNumber == 10'u64

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
      newerBytes = newer.sign(privateKey).tryGet().encode().tryGet()

    check (await server.disc.putValue(nameKey("catalog"), newerBytes)).isOk
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

  test "unpublish of an unknown label does not return an error":
    check (await publisher.unpublish("unknown")).isOk

  test "republishAll extends the expiration with the same CID and sequence number":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])
    let sequenceNumber = 3'u64
    let published =
      (await publisher.publish("catalog", cid, Opt.some(sequenceNumber))).tryGet()

    clock.advance(oneHour)

    await publisher.republishAll()

    let read = await reader.getNameRecord("catalog")

    check read.data.cid == cid
    check read.data.sequenceNumber == sequenceNumber
    check read.data.expiration == currentTime + oneHour + NameRecordLifetime
    check read.data.expiration > published.data.expiration
    check read.envelope.publicKey == publicKey

  test "republishAll republishes every stored name record":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])

    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", otherCid)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    let
      catalog = await reader.getNameRecord("catalog")
      release = await reader.getNameRecord("release")

    check catalog.data.expiration == currentTime + oneHour + NameRecordLifetime
    check release.data.expiration == currentTime + oneHour + NameRecordLifetime

  test "start republishes the stored name records right away after a restart":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])
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

  test "the loop republishes every 4 hours":
    let reader = await startNode(clock, isServer = false, bootstrap = @[server])

    check (await publisher.publish("catalog", cid, Opt.some(3'u64))).isOk

    publisher.start()

    check RepublishInterval == fourHours

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
