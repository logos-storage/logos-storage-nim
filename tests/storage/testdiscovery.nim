import pkg/libp2p/multiaddress
import pkg/libp2p_mix

import ../asynctest
import ./helpers
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
