import std/sequtils
import std/tables

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
import ../../storage/naming/publisher

type TestNode = object
  switch: Switch
  disc: Discovery

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64

asyncchecksuite "Name refresh":
  var
    nodes: seq[TestNode]
    publishers: seq[NamePublisher]
    clock: MockClock
    server: TestNode
    publisher: NamePublisher
    refresher: TestNode

  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    cid = Cid.example

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

  # Starts a server node after the publish, then waits until the server of the
  # publisher knows it.
  proc startLateNode(): Future[TestNode] {.
      async: (raises: [CancelledError, LPError, AsyncExceptionError])
  .} =
    let late = await startNode(clock, isServer = true, bootstrap = @[server])

    check eventually(server.disc.routingTable().peers.len >= 1, timeout = 10_000)

    late

  setup:
    clock = MockClock.new(currentTime)

    server = await startNode(clock, isServer = true)
    publisher = newPublisher(server)

    refresher = await startNode(clock, isServer = false, bootstrap = @[server])

  test "a node that joins after the publish gets the same name record after a refresh":
    check (await publisher.publish("catalog", cid)).isOk

    let
      catalogName = name(publicKey, "catalog").tryGet()
      key = nameKey(catalogName)

    let
      published = (await server.disc.getValue(key)).tryGet()
      late = await startLateNode()

    check not late.disc.kad.dataTable.hasKey(key)

    check (await refresh(refresher.disc, catalogName)).isOk

    check late.disc.kad.dataTable.hasKey(key)
    check late.disc.kad.dataTable[key].value == published

  test "returns an error and advertises nothing when the name record has expired":
    check (await publisher.publish("catalog", cid)).isOk

    let
      catalogName = name(publicKey, "catalog").tryGet()
      key = nameKey(catalogName)

    let late = await startLateNode()

    clock.advance(NameRecordLifetime + 1)

    check (await refresh(refresher.disc, catalogName)).isErr
    check not late.disc.kad.dataTable.hasKey(key)

  test "returns an error when the DHT has no name record for the name":
    let unknownName = name(publicKey, "unknown").tryGet()

    check (await refresh(refresher.disc, unknownName)).isErr
