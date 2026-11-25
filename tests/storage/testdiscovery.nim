import std/sequtils
import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/multiaddress
import pkg/libp2p/protocols/protocol
import pkg/libp2p/protocols/kademlia/protobuf as kadpb
import pkg/libp2p_mix
import pkg/questionable/results

import ../asynctest
import ../checktest
import ./helpers
import ./helpers/dhtnodes
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

    check $mixProto.localMixPubInfo.tryGet().multiAddr == $directAddr

  test "a relay circuit address sets the Mix local address":
    switch.peerInfo.addrs = @[circuitAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.tryGet().multiAddr == $circuitAddr

  test "a new address replaces the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[otherAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.tryGet().multiAddr == $otherAddr

  test "clearing the addresses resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.tryGet().multiAddr == $mixUnsetMultiAddr()

  test "no Mix-compatible address resets the Mix local address":
    switch.peerInfo.addrs = @[directAddr]
    disc.updateLocalMultiAddr()

    switch.peerInfo.addrs = @[udpAddr]
    disc.updateLocalMultiAddr()

    check $mixProto.localMixPubInfo.tryGet().multiAddr == $mixUnsetMultiAddr()

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

  test "a put that isn't stored on any peer fails":
    let node = await nodes.startNode(isServer = true)

    check (await node.disc.putValue(toBytes("no-peer"), toBytes("value"))).isErr

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

proc startAndMount(switch: Switch, proto: LPProtocol) {.async.} =
  ## A protocol mounted on a running switch must be started first.
  await proto.start()
  switch.mount(proto)

proc kadResponder(codec: string, providers: seq[kadpb.Peer]): LPProtocol =
  ## Answers every Kademlia request at once: GET_PROVIDERS with `providers`,
  ## anything else with an empty reply of the same type.
  proc handler(
      stream: Stream, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    try:
      while not stream.atEof:
        let request = kadpb.Message.decode(await stream.readLp(65536)).valueOr:
          break
        var reply = kadpb.Message(msgType: request.msgType, key: request.key)
        if request.msgType == Opt.some(kadpb.MessageType.getProviders):
          reply.providerPeers = providers
        await stream.writeLp(reply.encode())
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard
    finally:
      await noCancel stream.close()

  LPProtocol.new(@[codec], handler)

proc kadStaller(codec: string, release: AsyncEvent): LPProtocol =
  ## Reads Kademlia requests and never answers them.
  proc handler(
      stream: Stream, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    try:
      discard await stream.readLp(65536)
      await release.wait()
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard
    finally:
      await noCancel stream.close()

  LPProtocol.new(@[codec], handler)

proc mountDiscovery(switch: Switch, bootstrap: openArray[Switch]): Discovery =
  ## A Discovery on `switch` whose DHT is mounted. The test starts `switch`
  ## once the fake peers serve their protocols.
  let disc = Discovery.new(
    switch, bootstrapNodes = bootstrap.mapIt((it.peerInfo.peerId, it.peerInfo.addrs))
  )
  switch.mount(disc.kad)
  disc

asyncchecksuite "Discovery - provider lookup":
  var
    clientSwitch: Switch
    fastSwitch: Switch
    stallSwitch: Switch
    release: AsyncEvent
    providerId: PeerId
    provider: kadpb.Peer

  setup:
    clientSwitch = newStandardSwitch()
    fastSwitch = newStandardSwitch()
    stallSwitch = newStandardSwitch()
    release = newAsyncEvent()
    await fastSwitch.start()
    await stallSwitch.start()

    providerId = PeerId.example
    provider =
      kadpb.Peer(id: Opt.some(providerId.getBytes()), addrs: fastSwitch.peerInfo.addrs)

  teardown:
    release.fire()
    await allFuturesThrowing(clientSwitch.stop(), fastSwitch.stop(), stallSwitch.stop())

  test "returns the providers found when the lookup times out":
    let disc = clientSwitch.mountDiscovery([fastSwitch, stallSwitch])
    disc.lookupTimeout = 300.milliseconds
    disc.providerGracePeriod = 10.seconds
    await fastSwitch.startAndMount(kadResponder(disc.kad.codec, @[provider]))
    await stallSwitch.startAndMount(kadStaller(disc.kad.codec, release))
    await clientSwitch.start()

    let providers = (await disc.findDirect(Cid.example)).tryGet()

    check providers.mapIt(it.peerId) == @[providerId]

  test "returns soon after the first provider is found":
    let disc = clientSwitch.mountDiscovery([fastSwitch, stallSwitch])
    disc.lookupTimeout = 10.seconds
    disc.providerGracePeriod = 100.milliseconds
    await fastSwitch.startAndMount(kadResponder(disc.kad.codec, @[provider]))
    await stallSwitch.startAndMount(kadStaller(disc.kad.codec, release))
    await clientSwitch.start()

    let
      start = Moment.now()
      providers = (await disc.findDirect(Cid.example)).tryGet()

    check providers.mapIt(it.peerId) == @[providerId]
    check Moment.now() - start < 3.seconds

  test "fails when the lookup times out without providers":
    let disc = clientSwitch.mountDiscovery([stallSwitch])
    disc.lookupTimeout = 200.milliseconds
    await stallSwitch.startAndMount(kadStaller(disc.kad.codec, release))
    await clientSwitch.start()

    check (await disc.findDirect(Cid.example)).isErr

  test "returns no providers when the lookup ends without any":
    let disc = clientSwitch.mountDiscovery([fastSwitch])
    disc.lookupTimeout = 5.seconds
    await fastSwitch.startAndMount(kadResponder(disc.kad.codec, @[]))
    await clientSwitch.start()

    check (await disc.findDirect(Cid.example)).tryGet().len == 0
