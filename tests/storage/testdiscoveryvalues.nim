import std/sequtils
import std/tables
from std/times import getTime, toUnix

import pkg/chronos
import pkg/libp2p except setup
import pkg/nimcrypto/sha2
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./examples
import ../../storage/discovery
import ../../storage/naming/record
import ../../storage/naming/dht

type TestNode = object
  switch: Switch
  disc: Discovery

asyncchecksuite "Discovery - DHT values":
  var nodes: seq[TestNode]

  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    lookupTimeout = 30.seconds
    expiration = getTime().toUnix + 3600

  teardown:
    for node in nodes:
      await node.switch.stop()

    nodes = @[]

  proc startNode(
      isServer: bool, bootstrap: seq[TestNode] = @[]
  ): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
    let
      switch = newStandardSwitch()
      bootstrapPeers =
        bootstrap.mapIt((it.switch.peerInfo.peerId, it.switch.peerInfo.addrs))
      disc = Discovery.new(switch, bootstrapNodes = bootstrapPeers, isServer = isServer)

    switch.mount(disc.kad)

    await switch.start()

    let node = TestNode(switch: switch, disc: disc)
    nodes.add(node)

    node

  proc newKey(label: string): seq[byte] =
    dhtKeyFromName(name(publicKey, label).tryGet())

  proc newValue(label: string, sequenceNumber: uint64): seq[byte] =
    let record = NameRecord(
      version: NameRecordVersion,
      label: label,
      cid: Cid.example,
      sequenceNumber: sequenceNumber,
      expiration: expiration,
    )

    sign(record, privateKey).tryGet().encode()

  test "a client node puts a value and a server node reads it":
    let
      serverA = await startNode(isServer = true)
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      client = await startNode(isServer = false, bootstrap = @[serverA])
      key = newKey("client-to-server")
      value = newValue("client-to-server", 1)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await client.disc.putValue(key, value)).isOk

    let got = await serverB.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "a client reads another client's value from the server nodes":
    # The read quorum is 2, so two Storage nodes are needed
    let
      serverA = await startNode(isServer = true)
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      bootstrapNodes = @[serverA, serverB]
      writer = await startNode(isServer = false, bootstrap = bootstrapNodes)
      reader = await startNode(isServer = false, bootstrap = bootstrapNodes)
      key = newKey("client-to-client")
      value = newValue("client-to-client", 1)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

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
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      key = newKey("late-servers")
      value = newValue("late-servers", 1)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

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
      value = newValue("client-stores-nothing", 1)

    check (await server.disc.putValue(key, value)).isOk

    check not client.disc.kad.dataTable.hasKey(key)

  test "a second put on the same key replaces the value":
    let
      serverA = await startNode(isServer = true)
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      bootstrapNodes = @[serverA, serverB]
      writer = await startNode(isServer = false, bootstrap = bootstrapNodes)
      reader = await startNode(isServer = false, bootstrap = bootstrapNodes)
      key = newKey("second-put")
      value = newValue("second-put", 1)
      newerValue = newValue("second-put", 2)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await writer.disc.putValue(key, value)).isOk
    check (await writer.disc.putValue(key, newerValue)).isOk

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == newerValue

  test "a put with an older sequence number doesn't replace the value":
    let
      serverA = await startNode(isServer = true)
      serverB = await startNode(isServer = true, bootstrap = @[serverA])
      bootstrapNodes = @[serverA, serverB]
      writer = await startNode(isServer = false, bootstrap = bootstrapNodes)
      reader = await startNode(isServer = false, bootstrap = bootstrapNodes)
      key = newKey("older-put")
      value = newValue("older-put", 2)
      olderValue = newValue("older-put", 1)

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await writer.disc.putValue(key, value)).isOk
    check (await writer.disc.putValue(key, olderValue)).isErr

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "putValue refuses a value that is not a name record":
    let
      writer = await startNode(isServer = false)
      key = @(sha256.digest("not-a-name-record").data)

    check (await writer.disc.putValue(key, @[1'u8, 2, 3])).isErr

  test "putValue refuses a name record stored under the name of another label":
    let
      writer = await startNode(isServer = false)
      key = newKey("catalog")

    check (await writer.disc.putValue(key, newValue("release", 1))).isErr
