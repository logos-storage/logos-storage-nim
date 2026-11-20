import std/sequtils
import std/tables
from std/times import getTime, toUnix
import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/multiaddress
import pkg/libp2p_mix
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./examples
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils/mixidentity
import ../../storage/naming/record
import ../../storage/naming/dht

type TestNode = object
  switch: Switch
  disc: Discovery

suite "Discovery - Mix local address":
  var switch: Switch
  var disc: Discovery
  var mixProto: MixProtocol

  let
    directAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    otherAddr = MultiAddress.init("/ip4/9.9.9.9/tcp/4003").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")
    circuitAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")

  setup:
    switch = newStandardSwitch()
    disc = Discovery.new(switch)

    # Mirror the node startup: no dialable address known yet.
    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())
    disc.mixProto = mixProto

  test "a dialable address sets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $directAddr

  test "a relay circuit address sets the Mix local address":
    switch.peerInfo.addrs = @[circuitAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $circuitAddr

  test "a new address replaces the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[otherAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $otherAddr

  test "clearing the addresses resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()

  test "no Mix-compatible address resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[udpAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.multiAddr == $mixUnsetMultiAddr()

suite "Discovery - bootstrap addresses":
  let
    publicAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    privateAddr = MultiAddress.init("/ip4/10.1.0.85/tcp/4001").expect("valid")

  proc bootstrapAddrs(disc: Discovery): seq[string] =
    disc.routingTable().peers[0].record.addresses.mapIt($it.address)

  test "a private address of a bootstrap node is kept by default":
    let disc = Discovery.new(
      newStandardSwitch(),
      bootstrapNodes = [(PeerId.example, @[publicAddr, privateAddr])],
    )

    check $privateAddr in disc.bootstrapAddrs

  test "a private address of a bootstrap node is dropped by a public address policy":
    let disc = Discovery.new(
      newStandardSwitch(),
      bootstrapNodes = [(PeerId.example, @[publicAddr, privateAddr])],
      addressPolicy = dialableMixAddressPolicy,
    )

    check $privateAddr notin disc.bootstrapAddrs

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
    nameKey(name(publicKey, label).tryGet())

  proc newValue(label: string, seqnum: uint64): seq[byte] =
    let record = NameRecord(
      version: NameRecordVersion,
      label: label,
      cid: Cid.example,
      seqnum: seqnum,
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

  test "reading a key that does not exist fails":
    let
      server = await startNode(isServer = true)
      client = await startNode(isServer = false, bootstrap = @[server])
      fut = client.disc.getValue(newKey("unknown"))

    check await fut.withTimeout(lookupTimeout)
    check fut.read().isErr

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

  test "a put with an older seqnum doesn't replace the value":
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

  test "putValue refuses a name record stored under the name of another label":
    let
      writer = await startNode(isServer = false)
      key = newKey("catalog")

    check (await writer.disc.putValue(key, newValue("release", 1))).isErr
