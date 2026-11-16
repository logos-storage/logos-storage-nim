import std/sequtils
import std/tables

import pkg/chronos
import pkg/nimcrypto/sha2
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ../../storage/discovery

type TestNode = object
  switch: Switch
  disc: Discovery

asyncchecksuite "Discovery - DHT values":
  var nodes: seq[TestNode]

  let
    value = @[1'u8, 2, 3]
    newValue = @[4'u8, 5, 6]
    lookupTimeout = 30.seconds

  teardown:
    for node in nodes:
      await node.switch.stop()

    nodes = @[]

  proc startNode(
      isServer: bool, bootstrap: seq[TestNode] = @[]
  ): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
    let
      switch = newStandardSwitch()
      bootstrapNodes =
        bootstrap.mapIt((it.switch.peerInfo.peerId, it.switch.peerInfo.addrs))
      disc = Discovery.new(switch, bootstrapNodes = bootstrapNodes, isServer = isServer)

    switch.mount(disc.kad)

    await switch.start()

    let node = TestNode(switch: switch, disc: disc)
    nodes.add(node)

    node

  proc newKey(label: string): seq[byte] =
    @(sha256.digest(label).data)

  test "a client node puts a value and a server node reads it":
    let
      serverA = await startNode(isServer = true)
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      client = await startNode(isServer = false, bootstrap = @[serverA])
      key = newKey("client-to-server")

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await client.disc.putValue(key, value)).isOk

    let got = await serverB.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "a client reads another client's value from a single server node":
    # The read quorum is 1 for now, so a single Storage node is enough
    let
      server = await startNode(isServer = true)
      writer = await startNode(isServer = false, bootstrap = @[server])
      reader = await startNode(isServer = false, bootstrap = @[server])
      key = newKey("client-to-client")

    check (await writer.disc.putValue(key, value)).isOk

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "reading a key that does not exist fails":
    let
      server = await startNode(isServer = true)
      client = await startNode(isServer = false, bootstrap = @[server])
      fut = client.disc.getValue(newKey("unknown"))

    check await fut.withTimeout(lookupTimeout)
    check fut.read().isErr

  test "the quorum doesn't count empty replies":
    let
      serverA = await startNode(isServer = true)
      key = newKey("late-servers")

    check (await serverA.disc.putValue(key, value)).isOk

    let
      serverC = await startNode(isServer = true, bootstrap = @[serverA])
      reader = await startNode(isServer = false, bootstrap = @[serverC])

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "a client node doesn't store values for other nodes":
    let
      server = await startNode(isServer = true)
      client = await startNode(isServer = false, bootstrap = @[server])
      key = newKey("client-stores-nothing")

    check (await server.disc.putValue(key, value)).isOk

    check not client.disc.kad.dataTable.hasKey(key)

  test "a second put on the same key replaces the value":
    let
      server = await startNode(isServer = true)
      writer = await startNode(isServer = false, bootstrap = @[server])
      reader = await startNode(isServer = false, bootstrap = @[server])
      key = newKey("second-put")

    check (await writer.disc.putValue(key, value)).isOk
    check (await writer.disc.putValue(key, newValue)).isOk

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == newValue
