import std/sequtils
import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/multiaddress
import pkg/libp2p/routing_record
import pkg/libp2p_mix
from pkg/libp2p_mix/mix_protocol import exitNode
import pkg/libp2p_mix/[mix_node, multiaddr, pool, serialization, sphinx, tag_manager]
import pkg/libp2p_mix_transport/address/parse
import pkg/questionable/results

import ../asynctest
import ./helpers
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils/mixidentity
import ../../storage/utils/spr

suite "Mix address mapper - announced MixTransport address":
  ## Regression for the MixTransport address missing from the announced
  ## addresses and the signed peer record on the update that first delivers a
  ## verified endpoint. The Mix mapper used the endpoint that the PeerInfo
  ## observer saved after the previous update, so it lagged one update behind.

  var
    switch: Switch
    disc: Discovery
    mixProto: MixProtocol
    mixPeerId: PeerId
    verified: seq[MultiAddress]
    observed: seq[string]

  let
    firstAddr = MultiAddress.init("/ip4/204.168.234.45/tcp/8070").expect("valid")
    secondAddr = MultiAddress.init("/ip4/95.217.10.20/tcp/8071").expect("valid")
    privateAddr = MultiAddress.init("/ip4/192.168.1.10/tcp/8070").expect("valid")
    circuitAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")

  proc mixEndpoints(addrs: seq[MultiAddress]): seq[string] =
    ## The endpoints carried by the MixTransport addresses in `addrs`. Each one
    ## must decode to this node's Mix identity.
    for address in addrs:
      if address.isMTAddress():
        let info = MixPubInfo.fromMixAddress(address, Opt.some(mixPeerId)).expect(
            "a MixTransport address of this node"
          )
        result.add($info.multiAddr)

  proc plainAddrs(addrs: seq[MultiAddress]): seq[string] =
    addrs.filterIt(not it.isMTAddress()).mapIt($it)

  proc recordAddrs(): seq[MultiAddress] =
    ## The addresses in the signed peer record that libp2p built on the update,
    ## after an encode and decode round trip.
    let decoded =
      SignedPeerRecord.decode(switch.peerInfo.signedPeerRecord.encode()).tryGet()
    check decoded.data.peerId == switch.peerInfo.peerId
    decoded.toPeerIdAndAddrs()[1]

  proc sprAddrs(spr: string): seq[MultiAddress] =
    SignedPeerRecord.parse(spr).tryGet().toPeerIdAndAddrs()[1]

  proc localEndpoint(): string =
    $mixProto.localMixPubInfo.tryGet().multiAddr

  setup:
    verified = @[]
    observed = @[]

    # Mirror the node startup: no dialable address known yet.
    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixPeerId = nodeInfo.peerId
    let key = PrivateKey(scheme: Secp256k1, skkey: nodeInfo.libp2pPrivKey)
    switch = newStandardSwitch(privateKey = Opt.some(key))
    disc = Discovery.new(switch)
    mixProto = MixProtocol.new(nodeInfo, switch)
    disc.mixProto = mixProto

    # Stands in for libp2p's address manager, which is the first mapper and
    # yields the endpoints that AutoNAT verified or a relay reserved.
    let endpointMapper: AddressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return verified

    # The same order and policy as a `--nat=auto` node: the Mix mapper runs
    # after the endpoint-producing mapper, then the address policy filters.
    switch.peerInfo.addressMappers =
      @[endpointMapper, mixProto.addressMapper(dialableMixAddressPolicy)]
    switch.peerInfo.addressPolicy = dialableMixAddressPolicy

    switch.peerInfo.addObserver(disc.mixAddressObserver())
    # Check the full published address inside the next notification, before update returns.
    switch.peerInfo.addObserver(
      proc(p: PeerInfo) {.gcsafe, raises: [].} =
        let live = mixProto.localMixPubInfo.expect("live Mix identity")
        let published =
          p.signedPeerRecord.data.addresses.mapIt(it.address).filterIt(it.isMTAddress())
        if live.multiAddr == mixUnsetMultiAddr():
          doAssert published.len == 0
        else:
          doAssert published == @[live.toMixAddress().expect("valid live Mix address")]
        let spr = disc.getSpr()
        if spr.isOk:
          observed.add(spr.get())
    )

    # The update that the switch runs on start, before any verification.
    await switch.peerInfo.update()

  test "no MixTransport address is announced before an endpoint is verified":
    check switch.peerInfo.addrs.len == 0
    check recordAddrs().len == 0
    check localEndpoint() == $mixUnsetMultiAddr()

  test "the first verified endpoint is announced with its MixTransport address at once":
    verified = @[firstAddr]
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$firstAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$firstAddr]
    check localEndpoint() == $firstAddr

  test "the first signed peer record carries the MixTransport address":
    verified = @[firstAddr]
    await switch.peerInfo.update()

    check plainAddrs(recordAddrs()) == @[$firstAddr]
    check mixEndpoints(recordAddrs()) == @[$firstAddr]

    # The record that the node logs and serves from its observer.
    check observed.len == 1
    check plainAddrs(sprAddrs(observed[^1])) == @[$firstAddr]
    check mixEndpoints(sprAddrs(observed[^1])) == @[$firstAddr]

  test "a later update with the same endpoint keeps a single MixTransport address":
    verified = @[firstAddr]
    await switch.peerInfo.update()
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$firstAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$firstAddr]
    check mixEndpoints(recordAddrs()) == @[$firstAddr]
    check observed.len == 1

  test "a replaced endpoint replaces the MixTransport address in the same update":
    verified = @[firstAddr]
    await switch.peerInfo.update()

    verified = @[secondAddr]
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$secondAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$secondAddr]
    check mixEndpoints(recordAddrs()) == @[$secondAddr]
    check mixEndpoints(sprAddrs(observed[^1])) == @[$secondAddr]
    check localEndpoint() == $secondAddr

  test "a withdrawn endpoint withdraws the MixTransport address in the same update":
    verified = @[firstAddr]
    await switch.peerInfo.update()

    verified = @[]
    await switch.peerInfo.update()

    check switch.peerInfo.addrs.len == 0
    check recordAddrs().len == 0
    check sprAddrs(observed[^1]).len == 0
    check localEndpoint() == $mixUnsetMultiAddr()

  test "falling back to a private address withdraws the MixTransport address":
    verified = @[firstAddr]
    await switch.peerInfo.update()

    verified = @[privateAddr]
    await switch.peerInfo.update()

    check switch.peerInfo.addrs.len == 0
    check recordAddrs().len == 0
    check sprAddrs(observed[^1]).len == 0
    check localEndpoint() == $mixUnsetMultiAddr()

  test "a withdrawn endpoint that is verified again is announced at once":
    verified = @[firstAddr]
    await switch.peerInfo.update()
    verified = @[]
    await switch.peerInfo.update()

    verified = @[secondAddr]
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$secondAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$secondAddr]
    check mixEndpoints(recordAddrs()) == @[$secondAddr]

  test "a relay circuit endpoint is announced with its MixTransport address at once":
    verified = @[circuitAddr]
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$circuitAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$circuitAddr]
    check mixEndpoints(recordAddrs()) == @[$circuitAddr]
    check localEndpoint() == $circuitAddr

  test "a private endpoint is skipped in favour of the public one":
    verified = @[privateAddr, firstAddr]
    await switch.peerInfo.update()

    check plainAddrs(switch.peerInfo.addrs) == @[$firstAddr]
    check mixEndpoints(switch.peerInfo.addrs) == @[$firstAddr]
    check mixEndpoints(recordAddrs()) == @[$firstAddr]
    check localEndpoint() == $firstAddr

  test "expanding a candidate leaves the signed and live endpoints at the last publication":
    verified = @[firstAddr]
    await switch.peerInfo.update()
    verified = @[secondAddr]
    check mixEndpoints(await switch.peerInfo.expandAddrs()) == @[$secondAddr]
    check mixEndpoints(recordAddrs()) == @[localEndpoint()]
    check localEndpoint() == $firstAddr

  test "a plain address without a signed Mix address clears the live endpoint":
    verified = @[firstAddr]
    await switch.peerInfo.update()
    switch.peerInfo.announcedAddrs = @[secondAddr]
    await switch.peerInfo.update()
    check plainAddrs(recordAddrs()) == @[$secondAddr]
    check mixEndpoints(recordAddrs()).len == 0
    check localEndpoint() == $mixUnsetMultiAddr()

  test "the signed Mix address selects the live endpoint among several plain addresses":
    let announced =
      @[secondAddr].withMixAddress(mixProto, switch.peerInfo.addressPolicy)
    switch.peerInfo.announcedAddrs = @[firstAddr] & announced
    await switch.peerInfo.update()
    check plainAddrs(recordAddrs()) == @[$firstAddr, $secondAddr]
    check mixEndpoints(recordAddrs()) == @[localEndpoint()]
    check localEndpoint() == $secondAddr

  test "a new SURB routes its final hop to the endpoint in the signed record":
    var relays =
      MixNodeInfo.generateRandomMany(PathLength - 1, Rng.instance().libp2pRng)
    for relay in relays.mitems:
      relay.multiAddr = firstAddr
      mixProto.nodePool.add(relay.toMixPubInfo())

    for endpoint in [firstAddr, secondAddr]:
      verified = @[endpoint]
      await switch.peerInfo.update()

      var created = mixProto.createSurb(MixDestination.exitNode(mixPeerId))
      require created.isOk
      var built = move(created.get())
      defer:
        built.credential.wipe()
      var
        packet = useSURB(built.surb, newSeq[byte](MessageSize))
        hop = built.surb.hop.get().bytesToMultiAddr().tryGet()
      # Follow the reply through its relays and read the destination they receive.
      for _ in relays:
        let matches = relays.filterIt(it.peerId == hop[0])
        require matches.len == 1
        let relay = matches[0]
        var tags = TagManager.new(autoStart = false)
        let processed = processSphinxPacket(packet, relay.mixPrivKey, tags).tryGet()
        require processed.status == Intermediate
        hop = processed.nextHop.get().bytesToMultiAddr().tryGet()
        packet = SphinxPacket.deserialize(processed.serializedSphinxPacket).tryGet()

      check hop[0] == switch.peerInfo.peerId
      check mixEndpoints(recordAddrs()) == @[$hop[1]]
      check hop[1] == endpoint

  test "an explicitly announced LAN endpoint can carry Mix while an unbound port cannot":
    let unbound = MultiAddress.init("/ip4/192.168.1.10/tcp/0").expect("valid")
    switch.peerInfo.addressPolicy = defaultAddressPolicy
    switch.peerInfo.announcedAddrs =
      @[unbound, privateAddr].withMixAddress(mixProto, switch.peerInfo.addressPolicy)
    await switch.peerInfo.update()
    check localEndpoint() == $privateAddr
    check mixEndpoints(recordAddrs()) == @[localEndpoint()]
