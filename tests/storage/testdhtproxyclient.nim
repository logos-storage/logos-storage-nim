import std/strutils
import pkg/libp2p/[multiaddress, routing_record]
import pkg/storage/peertransport
import pkg/libp2p_mix

import ../asynctest
import ./helpers
import ./examples
import ../../storage/rng
import ../../storage/dht_proxy/client
import ../../storage/utils/mixidentity

asyncchecksuite "DHT proxy - lookupProviders":
  var mixProto: MixProtocol
  var transport: MixPeerTransport
  var cid: Cid

  let
    tcpAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")

  setup:
    cid = Cid.example

    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())
    transport = MixPeerTransport.new(newMixTransport(mixProto))

  test "fails when the proxy advertises no address":
    let proxy = PeerRecord.init(PeerId.example, newSeq[MultiAddress]())

    let res = await lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "Proxy has no addresses" in res.error.msg

  test "fails when no proxy address is Mix-compatible":
    let proxy = PeerRecord.init(PeerId.example, @[udpAddr])

    let res = await lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "Proxy has no valid Mix address" in res.error.msg

  test "fails when the local Mix address is not updated yet":
    let proxy = PeerRecord.init(
      mixProto.localMixPubInfo.tryGet().peerId,
      @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()],
    )

    let res = await lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "MixProtocol is not ready" in res.error.msg

  test "the lookup starts when the local Mix address is updated":
    mixProto.setLocalMultiAddr(tcpAddr).expect("Mix-encodable address")
    let proxy = PeerRecord.init(
      mixProto.localMixPubInfo.tryGet().peerId,
      @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()],
    )

    let res = await lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "MixTransport is not started" in res.error.msg

  test "rejects a proxy Mix address belonging to another peer":
    let proxy = PeerRecord.init(
      PeerId.example, @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()]
    )
    let res = await lookupProviders(mixProto, transport, proxy, cid)
    check res.isFailure
    check "matching its peer identity" in res.error.msg

  test "rejects a direct transport for a private lookup":
    let proxy = PeerRecord.init(PeerId.example, @[tcpAddr])
    let res = await lookupProviders(
      mixProto, DirectPeerTransport.new(newStandardSwitch()), proxy, cid
    )
    check res.isFailure
    check "MixTransport is not enabled" in res.error.msg

import pkg/libp2p_mix/[pool, delay_strategy]
import pkg/storage/discovery
import pkg/storage/dht_proxy/[handler, protocol]

type ProxyDiscovery = ref object of Discovery
  providers: seq[PeerRecord]
  lookupStarted: AsyncEvent
  directCalls: int

method findDirect(
    self: ProxyDiscovery, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  inc self.directCalls
  if not self.lookupStarted.isNil:
    self.lookupStarted.fire()
    await newAsyncEvent().wait() # held until the client cancels or times out
  return success(self.providers)

asyncchecksuite "DHT proxy over MixTransport":
  test "multi-packet replies, session reuse, timeout, cancellation and no fallback":
    let
      rng = newRng()
      listenAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      backend = ProxyDiscovery()
      cid = Cid.example
    var
      infos = MixNodeInfo.generateRandomMany(5, rng)
      switches: seq[Switch]
      mixes: seq[MixProtocol]
      transports: seq[MixTransport]
    try:
      for info in infos:
        let
          switch = SwitchBuilder
            .new()
            .withRng(rng)
            .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: info.libp2pPrivKey))
            .withAddress(listenAddr)
            .withTcpTransport()
            .withYamux()
            .withNoise()
            .build()
          mix = MixProtocol.new(
            info,
            switch,
            delayStrategy = Opt.some(DelayStrategy(NoSamplingDelayStrategy.new(rng))),
          )
        switch.mount(mix)
        switches.add(switch)
        mixes.add(mix)
      let
        protocol = DhtProxyProtocol.new(backend, maxInFlight = 1)
        serve: LPProtoHandler = protocol.handler
        exchangeFinished = newAsyncEvent()

      protocol.handler = proc(
          conn: Connection, codec: string
      ) {.async: (raises: [CancelledError]).} =
        defer:
          exchangeFinished.fire()
        await serve(conn, codec)

      proc waitForExchange() {.async.} =
        await exchangeFinished.wait().wait(10.seconds)
        exchangeFinished.clear()

      switches[^1].mount(protocol)
      for index in 0 ..< switches.len:
        await switches[index].start()
        infos[index].multiAddr = switches[index].peerInfo.listenAddrs[0]
        mixes[index].setLocalMultiAddr(infos[index].multiAddr).tryGet()
      for index, mix in mixes:
        mix.nodePool.add(infos.includeAllExcept(infos[index]))
        await mix.start()
      for index in [0, 4]:
        let transport = newMixTransport(mixes[index])
        (await transport.start()).tryGet()
        transports.add(transport)
      let
        transport = MixPeerTransport.new(transports[0])
        proxy = PeerRecord.init(
          infos[^1].peerId,
          @[mixes[^1].localMixPubInfo.tryGet().toMixAddress().tryGet()],
        )
      let direct =
        await switches[0].dial(infos[^1].peerId, @[infos[^1].multiAddr], DhtProxyCodec)
      await direct.writeLp(@[255'u8])
      let directReply =
        LookupResponse.decode(await direct.readLp(MaxLookupResponseBytes)).tryGet()
      check directReply.code == LookupCode.ErrDecodeFailed
      await direct.close()
      await waitForExchange()

      for i in 0 ..< 100:
        backend.providers.add(PeerRecord.init(PeerId.example, @[infos[1].multiAddr]))
      var encoded: seq[seq[byte]]
      for provider in backend.providers:
        encoded.add(provider.encode())
      check LookupResponse(code: LookupCode.Ok, providers: encoded).encode().len > 4096
      let found = await lookupProviders(mixes[0], transport, proxy, cid, 20.seconds)
      if found.isFailure:
        checkpoint found.error.msg
      check found.isSuccess
      if found.isSuccess:
        check found.get().len == 100
      await waitForExchange()
      backend.providers = @[]
      let empty = await lookupProviders(mixes[0], transport, proxy, cid, 20.seconds)
      check empty.isSuccess
      check empty.get().len == 0
      await waitForExchange()

      let malformed = (await transport.dial(proxy, DhtProxyCodec)).tryGet()
      await malformed.writeLp(@[255'u8])
      let malformedResponse =
        LookupResponse.decode(await malformed.readLp(MaxLookupResponseBytes)).tryGet()
      check malformedResponse.code == LookupCode.ErrDecodeFailed
      await malformed.close()
      await waitForExchange()

      backend.lookupStarted = newAsyncEvent()
      let timedOut =
        await lookupProviders(mixes[0], transport, proxy, cid, 200.milliseconds)
      check timedOut.isFailure
      check "timed out" in timedOut.error.msg
      await waitForExchange()
      backend.lookupStarted.clear()
      let cancelled = lookupProviders(mixes[0], transport, proxy, cid)
      await backend.lookupStarted.wait().wait(10.seconds)
      let busy = await lookupProviders(mixes[0], transport, proxy, cid)
      check busy.isFailure
      check "ErrTooBusy" in busy.error.msg
      await waitForExchange()
      await cancelled.cancelAndWait()
      check cancelled.cancelled
      await waitForExchange()
      backend.lookupStarted = nil
      let afterCancel =
        await lookupProviders(mixes[0], transport, proxy, cid, 20.seconds)
      check afterCancel.isSuccess
      await waitForExchange()

      let clientDiscovery =
        ProxyDiscovery(mixProto: mixes[0], mixPeerTransport: transport)
      let noProxies = await clientDiscovery.find(cid, useMix = true)
      check noProxies.isFailure
      check clientDiscovery.directCalls == 0
      let legacy = PeerRecord.init(infos[^1].peerId, @[infos[^1].multiAddr])
      clientDiscovery.staticDhtMixProxies = @[legacy]
      let allFailed = await clientDiscovery.find(cid, useMix = true)
      check allFailed.isFailure
      check clientDiscovery.directCalls == 0
      clientDiscovery.staticDhtMixProxies.add(proxy)
      let viaConfigured = await clientDiscovery.find(cid, useMix = true)
      check viaConfigured.isSuccess
      check clientDiscovery.directCalls == 0
      await transports[^1].stop()
      let unavailable =
        await lookupProviders(mixes[0], transport, proxy, cid, 200.milliseconds)
      check unavailable.isFailure
    finally:
      for transport in transports:
        await transport.stop()
      for switch in switches:
        await switch.stop()

  test "provider packing obeys the stream response limit":
    let records = @[newSeq[byte](100000), newSeq[byte](100000), newSeq[byte](100000)]
    let packed = packProviders(records, MaxLookupResponseBytes).tryGet()
    check packed.len == 2
    check LookupResponse(code: LookupCode.Ok, providers: packed).encode().len <=
      MaxLookupResponseBytes
    check packProviders(@[newSeq[byte](MaxLookupResponseBytes)], MaxLookupResponseBytes).error ==
      LookupCode.ErrResponseTooLarge
