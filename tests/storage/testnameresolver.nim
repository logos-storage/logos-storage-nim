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
import ../../storage/naming/publisher
import ../../storage/naming/dht

type TestNode = object
  switch: Switch
  disc: Discovery

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64

asyncchecksuite "Name resolver":
  var
    nodes: seq[TestNode]
    publishers: seq[NamePublisher]
    clock: MockClock
    server: TestNode
    publisher: NamePublisher
    reader: TestNode

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

  proc newPublisher(node: TestNode): NamePublisher =
    let publisher = NamePublisher.new(
      node.disc, SQLiteDatastore.new(Memory).tryGet(), privateKey, clock
    )
    publishers.add(publisher)

    publisher

  setup:
    clock = MockClock.new(currentTime)

    server = await startNode(clock, isServer = true)
    publisher = newPublisher(server)

    reader = await startNode(clock, isServer = false, bootstrap = @[server])

  test "resolves a name published by another node":
    check (await publisher.publish("catalog", cid)).isOk

    let catalogName = name(publicKey, "catalog").tryGet()

    let resolved = (await reader.disc.resolve(catalogName)).tryGet()

    check resolved.isSome
    check resolved.get() == cid

  test "resolves the CID of the label, not the CID of another label":
    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", otherCid)).isOk

    let
      catalog = (await reader.disc.resolve(publicKey, "catalog")).tryGet()
      release = (await reader.disc.resolve(publicKey, "release")).tryGet()

    check catalog.get() == cid
    check release.get() == otherCid

  test "resolves the CID of the newest name record":
    check (await publisher.publish("catalog", cid, Opt.some(1'u64))).isOk

    # This resolve gives the reader a local copy
    let first = (await reader.disc.resolve(publicKey, "catalog")).tryGet()

    check first.get() == cid

    check (await publisher.publish("catalog", otherCid, Opt.some(2'u64))).isOk

    let newest = (await reader.disc.resolve(publicKey, "catalog")).tryGet()

    check newest.get() == otherCid

  test "returns no CID when the DHT has no name record for the name":
    let unknownName = name(publicKey, "unknown").tryGet()

    let resolved = await reader.disc.resolve(unknownName)

    check resolved.isOk
    check resolved.tryGet().isNone

  test "returns an error for an empty label":
    check (await reader.disc.resolve(publicKey, "")).isErr
