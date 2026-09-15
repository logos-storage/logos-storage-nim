import std/[sequtils, tables]

import pkg/chronos

import pkg/storage/rng
import pkg/storage/chunker
import pkg/storage/blocktype as bt
import pkg/storage/blockexchange
import pkg/storage/blockexchange/protocol/wantblocks
import pkg/storage/downloadtransport
import pkg/storage/mix
import pkg/libp2p_mix_transport/streams

import ../../asynctest
import ../examples
import ../helpers

asyncchecksuite "Network - Handlers":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng.libp2pRng).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    network: BlockExcNetwork
    networkPeer: NetworkPeer
    buffer: BufferStream
    blocks: seq[bt.Block]
    done: Future[void]

  proc getConn(): Future[Connection] {.async: (raises: [CancelledError]).} =
    return Connection(buffer)

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    done = newFuture[void]()
    buffer = BufferStream.new()
    network = BlockExcNetwork.new(switch = newStandardSwitch(), connProvider = getConn)
    await network.handlePeerJoined(peerId)
    networkPeer = network.peers[peerId]
    discard await networkPeer.connect()

  test "Want List handler":
    let treeCid = Cid.example

    proc wantListHandler(peer: PeerId, wantList: WantList) {.async: (raises: []).} =
      check wantList.entries.len == 4

      for entry in wantList.entries:
        check entry.address.treeCid == treeCid
        check entry.wantType == WantType.WantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network.handlers.onWantList = wantListHandler

    let wantList =
      makeWantList(treeCid, blocks.len, 1, true, WantType.WantHave, true, true)

    let msg = Message(wantlist: wantList)
    await buffer.pushData(frameProtobufMessage(msg.encode()))

    await done.wait(500.millis)

  test "Presence Handler":
    let
      treeCid = Cid.example
      addresses =
        (0 ..< blocks.len).mapIt(BlockAddress(treeCid: treeCid, index: it.uint64))

    proc presenceHandler(
        peer: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: []).} =
      check presence.len == blocks.len
      for p in presence:
        check p.address.treeCid == treeCid

      done.complete()

    network.handlers.onPresence = presenceHandler

    let msg = Message(
      blockPresences:
        addresses.mapIt(BlockPresence(address: it, kind: BlockPresenceType.HaveRange))
    )
    await buffer.pushData(frameProtobufMessage(msg.encode()))

    await done.wait(500.millis)

asyncchecksuite "Network - Senders":
  let chunker = RandomChunker.new(Rng.instance(), size = 1024, chunkSize = 256)

  var
    switch1, switch2: Switch
    network1, network2: BlockExcNetwork
    blocks: seq[bt.Block]
    done: Future[void]

  setup:
    while true:
      let chunk = await chunker.getBytes()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()
    network1 = BlockExcNetwork.new(switch = switch1)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(switch = switch2)
    switch2.mount(network2)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  test "Send want list":
    let
      treeCid = Cid.example
      addresses =
        (0 ..< blocks.len).mapIt(BlockAddress(treeCid: treeCid, index: it.uint64))

    proc wantListHandler(peer: PeerId, wantList: WantList) {.async: (raises: []).} =
      check wantList.entries.len == 4

      for entry in wantList.entries:
        check entry.address.treeCid == treeCid
        check entry.wantType == WantType.WantHave
        check entry.priority == 1
        check entry.cancel == true
        check entry.sendDontHave == true

      done.complete()

    network2.handlers.onWantList = wantListHandler
    await network1.sendWantList(
      switch2.peerInfo.peerId, addresses, 1, true, WantType.WantHave, true, true
    )

    await done.wait(500.millis)

  test "send presence":
    let
      treeCid = Cid.example
      addresses =
        (0 ..< blocks.len).mapIt(BlockAddress(treeCid: treeCid, index: it.uint64))

    proc presenceHandler(
        peer: PeerId, precense: seq[BlockPresence]
    ) {.async: (raises: []).} =
      check precense.len == blocks.len
      for p in precense:
        check p.address.treeCid == treeCid

      done.complete()

    network2.handlers.onPresence = presenceHandler

    await network1.sendBlockPresence(
      switch2.peerInfo.peerId,
      addresses.mapIt(BlockPresence(address: it, kind: BlockPresenceType.HaveRange)),
    )

    await done.wait(500.millis)

asyncchecksuite "Network - MixTransport peer events":
  var switch1, switch2: Switch

  setup:
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()

  teardown:
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  test "Protocol mode follows the supplied MixTransport":
    let
      directNetwork = BlockExcNetwork.new(switch1)
      mixNetwork = BlockExcNetwork.new(switch1, mixTransport = MixTransport())
    check not directNetwork.isMixDownload
    check mixNetwork.isMixDownload
    await directNetwork.stop()
    await mixNetwork.stop()

  test "Direct and Mix peer entries and departures are independent":
    let
      network = BlockExcNetwork.new(switch1)
      mixNetwork = BlockExcNetwork.new(switch1, mixTransport = MixTransport())
      peer = switch2.peerInfo.peerId
    await network.handlePeerJoined(peer)
    await mixNetwork.handlePeerJoined(peer)
    check network.peers[peer] != mixNetwork.peers[peer]
    await mixNetwork.handlePeerDeparted(peer)
    check peer in network.peers
    check peer notin mixNetwork.peers
    await network.stop()
    await mixNetwork.stop()

  test "Disabled Mix has no protocol instance and does not select Direct":
    var directCalls = 0
    proc directConnection(): Future[Connection] {.async: (raises: [CancelledError]).} =
      inc directCalls
      return nil

    let
      network = BlockExcNetwork.new(switch1, connProvider = directConnection)
      networks = newBlockExcNetworks(network)
    check networks.networkFor(DownloadTransport.Mix).isNil
    check not networks.isMixEnabled
    check directCalls == 0
    await network.stop()

  test "Physical Mix relay connections do not become BlockExchange peers":
    let
      directNetwork = BlockExcNetwork.new(switch1)
      networks = newBlockExcNetworks(directNetwork)
      network = BlockExcNetwork.new(switch1, mixTransport = MixTransport())
    networks.mix = network
    switch1.mount(networks.dispatchProtocol)
    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

    check switch2.peerInfo.peerId notin network.peers
    await networks.stop()

  test "Mounted dispatcher closes a Mix stream when Mix is disabled":
    let
      directNetwork = BlockExcNetwork.new(switch1)
      networks = newBlockExcNetworks(directNetwork)
      peer = switch2.peerInfo.peerId
      stream = newTransportStream(peer, peer, 1, Codec, StreamDirection.Inbound)
    await networks.dispatchProtocol.handler(stream, Codec)
    check stream.closed
    check peer notin directNetwork.peers
    await networks.stop()

asyncchecksuite "Network - Test Limits":
  var
    switch1, switch2: Switch
    network1, network2: BlockExcNetwork
    done: Future[void]

  setup:
    done = newFuture[void]()
    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()

    network1 = BlockExcNetwork.new(switch = switch1, maxInflight = 0)
    switch1.mount(network1)

    network2 = BlockExcNetwork.new(switch = switch2)
    switch2.mount(network2)

    await switch1.start()
    await switch2.start()

    await switch1.connect(switch2.peerInfo.peerId, switch2.peerInfo.addrs)

  teardown:
    await allFuturesThrowing(switch1.stop(), switch2.stop())

  test "Concurrent Sends":
    network2.handlers.onPresence = proc(
        peer: PeerId, presence: seq[BlockPresence]
    ): Future[void] {.async: (raises: []).} =
      check false

    let fut = network1.send(switch2.peerInfo.peerId, Message())

    await sleepAsync(100.millis)
    check not fut.finished
