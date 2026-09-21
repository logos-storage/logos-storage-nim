import std/[tables, os]
import pkg/chronos
import pkg/chronicles
import pkg/libp2p except setup, eventually
import pkg/libp2p/routing_record
import pkg/libp2p_mix
import pkg/libp2p_mix/[pool, delay_strategy]
import pkg/libp2p_mix_transport/address/parse
import pkg/storage/mix
import pkg/storage/blockexchange
import pkg/storage/blockexchange/engine/activedownload
import pkg/storage/manifest/protocol
import pkg/storage/stores
import pkg/storage/merkletree
import pkg/storage/blocktype as bt
import ../../asynctest
import ../helpers

proc verifyRecipientPresenceLifecycle(
    requester, provider: BlockExcNetwork, providerId: PeerId, address: BlockAddress
) {.async.} =
  let
    requestStream = TransportStream(await requester.peers[providerId].connect())
    anonymousPeerId = requestStream.sessionId
    replyPeer = provider.peers[anonymousPeerId]
    presence = @[BlockPresence(address: address, kind: BlockPresenceType.HaveRange)]
    previousHandler = requester.handlers.onPresence
  var received = newFuture[seq[BlockPresence]]("recipient presence")
  requester.handlers.onPresence = proc(
      peer: PeerId, values: seq[BlockPresence]
  ) {.async: (raises: []).} =
    doAssert peer == providerId
    if not received.finished:
      received.complete(values)
  defer:
    requester.handlers.onPresence = previousHandler

  proc exchangePresence(): Future[TransportStream] {.async.} =
    received = newFuture[seq[BlockPresence]]("recipient presence")
    await provider.sendBlockPresence(anonymousPeerId, presence)
    let values = await received.wait(15.seconds)
    doAssert values.len == 1 and values[0].address == address
    return TransportStream(await replyPeer.connect())

  # Presence uses a recipient-opened stream, not the incoming request stream.
  let firstReplyStream = await exchangePresence()
  doAssert firstReplyStream.streamId mod 2 == 0
  doAssert firstReplyStream.sessionId == requestStream.sessionId

  # Subsequent presence messages reuse that sending connection.
  let reusedReplyStream = await exchangePresence()
  doAssert reusedReplyStream == firstReplyStream

  # Closing only the sending stream must not require a replacement session.
  await firstReplyStream.close()
  let replacementReplyStream = await exchangePresence()
  doAssert replacementReplyStream.streamId != firstReplyStream.streamId
  doAssert replacementReplyStream.sessionId == firstReplyStream.sessionId

asyncchecksuite "Download transport selection":
  test "Transport parameter accepts only direct and mix":
    check parseDownloadTransport("direct").tryGet() == DownloadTransport.Direct
    check parseDownloadTransport("mix").tryGet() == DownloadTransport.Mix
    check parseDownloadTransport("automatic").isErr

  test "Provider Mix addresses must match the provider identity":
    let
      rng = newRng()
      infos = MixNodeInfo.generateRandomMany(2, rng)
      mix = MixProtocol.new(infos[0], newStandardSwitch())
      address = mix.localMixPubInfo.toMixAddress().tryGet()
    check mixAddresses(infos[0].peerId, @[address]).len == 1
    check mixAddresses(infos[1].peerId, @[address]).len == 0
    check mixAddresses(infos[0].peerId, @[infos[0].multiAddr]).len == 0
    check not TCP.match(address)
    check not QUIC_V1.match(address)

  test "Manifest and blocks use the selected transport to the same provider":
    let previousWriter = defaultChroniclesStream.output.writer
    if getEnv("MIX_DOWNLOAD_TEST_LOGS") != "":
      defaultChroniclesStream.output.writer = proc(
          level: LogLevel, message: LogOutputStr
      ) =
        echo message
    defer:
      defaultChroniclesStream.output.writer = previousWriter
    let
      rng = newRng()
      infos = MixNodeInfo.generateRandomMany(5, rng)
    var
      switches: seq[Switch]
      mixes: seq[MixProtocol]
      transports: seq[MixTransport]
      engines: seq[BlockExcEngine]
      manifests: seq[ManifestProtocol]
      stores: seq[BlockStore]
    try:
      for info in infos:
        let
          switch = SwitchBuilder
            .new()
            .withRng(rng)
            .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: info.libp2pPrivKey))
            .withAddress(info.multiAddr)
            .withTcpTransport()
            .withMplex()
            .withNoise()
            .build()
          mix = MixProtocol.new(
            info,
            switch,
            delayStrategy = Opt.some(DelayStrategy(NoSamplingDelayStrategy.new(rng))),
          )
        mix.nodePool.add(infos.includeAllExcept(info))
        switch.mount(mix)
        switches.add(switch)
        mixes.add(mix)

      let provider = PeerRecord.init(
        switches[^1].peerInfo.peerId,
        # Put the Mix advertisement first: Direct dialing must skip an
        # unsupported candidate, not rely on the advertisement being last.
        @[mixes[^1].localMixPubInfo.toMixAddress().tryGet(), infos[^1].multiAddr],
      )
      for index in [0, 4]:
        let
          store = CacheStore.new()
          discovery = MockDiscovery.new()
          network = BlockExcNetwork.new(switches[index])
          networks = newBlockExcNetworks(network)
          peers = PeerContextStore.new()
          manager = DownloadManager.new()
          discoveryEngine = DiscoveryEngine.new(store, peers, networks, discovery)
          advertiser =
            Advertiser.new(store, discovery, peerInfo = switches[index].peerInfo)
          engine = BlockExcEngine.new(
            store, networks, discoveryEngine, advertiser, peers, manager
          )
          manifest = ManifestProtocol.new(
            switches[index], store, discovery, retries = 1, fetchTimeout = 15.seconds
          )
          transport = newMixTransport(mixes[index])
        discovery.findBlockProvidersHandler = proc(
            d: MockDiscovery, cid: Cid
        ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
          return @[provider]
        engine.enableMixNetwork(transport)
        manifest.attachMixTransport(transport)
        switches[index].mount(networks.dispatchProtocol)
        switches[index].mount(manifest)
        stores.add(store)
        engines.add(engine)
        manifests.add(manifest)
        transports.add(transport)

      for index in 0 ..< switches.len:
        await switches[index].start()
        await mixes[index].start()
      for transport in transports:
        (await transport.start()).tryGet()
      for engine in engines:
        await engine.start()

      let
        blocks = await makeRandomBlocks(2 * 1024, 1024.NBytes)
        dataset = makeDataset(blocks).tryGet()
        manifestBlock = bt.Block
          .new(dataset.manifestCid, dataset.manifest.encode().tryGet(), verify = true)
          .tryGet()
      (await stores[1].putBlock(manifestBlock)).tryGet()
      for index, blk in dataset.blocks:
        (await stores[1].putBlock(blk)).tryGet()
        (
          await stores[1].putCidAndProof(
            dataset.manifest.treeCid,
            index,
            blk.cid,
            dataset.tree.getProof(index).tryGet(),
          )
        ).tryGet()

      # Start both fetches before awaiting either: both miss the local cache.
      let
        directManifest =
          manifests[0].fetchManifest(dataset.manifestCid, DownloadTransport.Direct)
        mixManifest =
          manifests[0].fetchManifest(dataset.manifestCid, DownloadTransport.Mix)
      check (await directManifest).isOk
      check (await mixManifest).isOk

      # A working direct provider is not a fallback for missing Mix metadata,
      # even when an earlier request established a Mix session with that peer.
      let directOnlyDiscovery = MockDiscovery.new()
      directOnlyDiscovery.findBlockProvidersHandler = proc(
          d: MockDiscovery, cid: Cid
      ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
        return success(@[PeerRecord.init(provider.peerId, @[infos[^1].multiAddr])])
      let directOnlyManifest = ManifestProtocol.new(
        switches[0], CacheStore.new(), directOnlyDiscovery, retries = 1
      )
      directOnlyManifest.attachMixTransport(transports[0])
      check (
        await directOnlyManifest.fetchManifest(
          dataset.manifestCid, DownloadTransport.Mix
        )
      ).isErr

      for transport in [DownloadTransport.Direct, DownloadTransport.Mix]:
        let handle = engines[0]
          .startTreeDownloadOpaque(dataset.manifestDesc, transport = transport)
          .tryGet()
        try:
          check (await handle.waitForComplete().wait(30.seconds)).isOk
          for blk in dataset.blocks:
            check (await stores[0].getBlock(blk.cid)).isOk
            # Ensure the next download also has to transfer the blocks.
            (await stores[0].delBlock(blk.cid)).tryGet()
        finally:
          engines[0].releaseDownload(handle)

      let
        peer = provider.peerId
        directNetwork = engines[0].networks.direct
        mixNetwork = engines[0].networks.mix
      check peer in directNetwork.peers
      check peer in mixNetwork.peers
      check directNetwork.peers[peer] != mixNetwork.peers[peer]
      check not ((await directNetwork.peers[peer].connect()) of TransportStream)
      check (await mixNetwork.peers[peer].connect()) of TransportStream
      check engines[0].peersFor(DownloadTransport.Direct).get(peer) !=
        engines[0].peersFor(DownloadTransport.Mix).get(peer)
      await verifyRecipientPresenceLifecycle(
        mixNetwork,
        engines[1].networks.mix,
        peer,
        BlockAddress(treeCid: dataset.manifest.treeCid, index: 0),
      )
    finally:
      for transport in transports:
        await transport.stop()
      for engine in engines:
        await engine.stop()
      for mix in mixes:
        await mix.stop()
      for switch in switches:
        await switch.stop()
