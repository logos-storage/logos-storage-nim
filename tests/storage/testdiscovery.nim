import std/sequtils
import std/tables
import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/multiaddress
import pkg/libp2p_mix
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./helpers/testnodes
import ./examples
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils/mixidentity

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
  let
    nodes = TestNodes()
    lookupTimeout = 30.seconds

  teardown:
    await nodes.stop()

  proc toBytes(text: string): seq[byte] =
    @(text.toOpenArrayByte(0, text.high))

  test "a client node puts a value and a server node reads it":
    let
      serverA = await nodes.startNode(isServer = true)
      serverB = await nodes.startNode(isServer = true, bootstrap = @[serverA])
      client = await nodes.startNode(isServer = false, bootstrap = @[serverA])
      key = toBytes("client-to-server")
      value = toBytes("value")

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await client.disc.putValue(key, value)).isOk

    let got = await serverB.disc.getValue(key)
    check got.isOk
    check got.tryGet == value

  test "reading a key that does not exist fails":
    let
      server = await nodes.startNode(isServer = true)
      client = await nodes.startNode(isServer = false, bootstrap = @[server])
      fut = client.disc.getValue(toBytes("unknown"))

    check await fut.withTimeout(lookupTimeout)
    check fut.read().isErr

  test "a second put on the same key replaces the value":
    let
      serverA = await nodes.startNode(isServer = true)
      serverB = await nodes.startNode(isServer = true, bootstrap = @[serverA])
      bootstrapNodes = @[serverA, serverB]
      writer = await nodes.startNode(isServer = false, bootstrap = bootstrapNodes)
      reader = await nodes.startNode(isServer = false, bootstrap = bootstrapNodes)
      key = toBytes("second-put")
      value = toBytes("first value")
      newerValue = toBytes("second value")

    # Wait until serverA knows serverB
    check eventually(serverA.disc.routingTable().peers.len >= 1, timeout = 10_000)

    check (await writer.disc.putValue(key, value)).isOk
    check (await writer.disc.putValue(key, newerValue)).isOk

    let got = await reader.disc.getValue(key)
    check got.isOk
    check got.tryGet == newerValue
