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
  var client: ProxyClient
  var mixProto: MixProtocol
  var transport: MixPeerTransport
  var cid: Cid

  let
    tcpAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")

  setup:
    client = ProxyClient()
    cid = Cid.example

    var nodeInfo = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    nodeInfo.multiAddr = mixUnsetMultiAddr()
    mixProto = MixProtocol.new(nodeInfo, newStandardSwitch())
    transport = MixPeerTransport.new(newMixTransport(mixProto))

  test "fails when the proxy advertises no address":
    let proxy = PeerRecord.init(PeerId.example, newSeq[MultiAddress]())

    let res = await client.lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "Proxy has no addresses" in res.error.msg

  test "fails when no proxy address is Mix-compatible":
    let proxy = PeerRecord.init(PeerId.example, @[udpAddr])

    let res = await client.lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "Proxy has no valid Mix address" in res.error.msg

  test "fails when the local Mix address is not updated yet":
    let proxy = PeerRecord.init(
      mixProto.localMixPubInfo.tryGet().peerId,
      @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()],
    )

    let res = await client.lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "MixProtocol is not ready" in res.error.msg

  test "the lookup starts when the local Mix address is updated":
    mixProto.setLocalMultiAddr(tcpAddr).expect("Mix-encodable address")
    let proxy = PeerRecord.init(
      mixProto.localMixPubInfo.tryGet().peerId,
      @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()],
    )

    let res = await client.lookupProviders(mixProto, transport, proxy, cid)

    check res.isFailure
    check "MixTransport is not started" in res.error.msg

  test "rejects a proxy Mix address belonging to another peer":
    let proxy = PeerRecord.init(
      PeerId.example, @[mixProto.localMixPubInfo.tryGet().toMixAddress().tryGet()]
    )
    let res = await client.lookupProviders(mixProto, transport, proxy, cid)
    check res.isFailure
    check "matching its peer identity" in res.error.msg

  test "rejects a direct transport for a private lookup":
    let proxy = PeerRecord.init(PeerId.example, @[tcpAddr])
    let res = await client.lookupProviders(
      mixProto, DirectPeerTransport.new(newStandardSwitch()), proxy, cid
    )
    check res.isFailure
    check "MixTransport is not enabled" in res.error.msg

import pkg/libp2p_mix/[pool, delay_strategy]
import pkg/storage/discovery
import pkg/storage/dht_proxy/[handler, protocol]

type GatedTransport = ref object of PeerTransport
  next: PeerTransport
  ready: AsyncEvent
  dials: int

method kind(self: GatedTransport): DownloadTransport =
  DownloadTransport.Mix

method dial(
    self: GatedTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  inc self.dials
  await self.ready.wait()
  return await self.next.dial(peer, codec)

type ProxyDiscovery = ref object of Discovery
  providers: seq[PeerRecord]
  hold: int
  started, release: AsyncEvent
  directCalls: int

method findDirect(
    self: ProxyDiscovery, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  inc self.directCalls
  if self.hold > 0:
    dec self.hold
    self.started.fire()
    await self.release.wait()
    return success(newSeq[PeerRecord]())
  return success(self.providers)

asyncchecksuite "DHT proxy over MixTransport":
  test "multi-packet replies, session reuse, timeout, cancellation and no fallback":
    let
      rng = newRng()
      listenAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      backend = ProxyDiscovery(started: newAsyncEvent(), release: newAsyncEvent())
      client = ProxyClient()
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
        protocol = DhtProxyProtocol.new(backend, maxInFlight = 2)
        serve: LPProtoHandler = protocol.handler
        exchangeFinished = newAsyncEvent()
      var opens = 0
      var latest: Connection

      protocol.handler = proc(
          conn: Connection, codec: string
      ) {.async: (raises: [CancelledError]).} =
        inc opens
        latest = conn
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
      # A structurally readable ID permits a request-level error.
      await direct.writeLp(@[0x18'u8, 1])
      let directReply =
        LookupResponse.decode(await direct.readLp(MaxLookupResponseBytes)).tryGet()
      check directReply.code == LookupCode.ErrDecodeFailed
      check directReply.requestId == 1
      # Duplicate ID invalidates this stream.
      await direct.writeLp(
        LookupRequest(requestId: 1, queryBytes: cid.data.buffer).encode()
      )
      await waitForExchange()
      await direct.close()

      for i in 0 ..< 100:
        backend.providers.add(PeerRecord.init(PeerId.example, @[infos[1].multiAddr]))

      # Simultaneous first users share their dial. Two queries for the same CID
      # return distinct results in reverse completion order.
      backend.hold = 1
      let gated = GatedTransport(next: transport, ready: newAsyncEvent())
      let beforeSend = client.lookupProviders(mixes[0], gated, proxy, cid)
      let first = client.lookupProviders(mixes[0], gated, proxy, cid, 20.seconds)
      let second = client.lookupProviders(mixes[0], gated, proxy, cid, 20.seconds)
      await beforeSend.cancelAndWait()
      check beforeSend.cancelled
      check gated.dials == 1
      gated.ready.fire()
      let found = await second
      require found.isSuccess
      check found.get == backend.providers
      check not first.finished
      check backend.directCalls == 2
      check opens == 2 # one direct probe and one Mix stream
      backend.release.fire()
      let empty = await first
      require empty.isSuccess
      check empty.get.len == 0

      backend.started.clear()
      backend.release.clear()
      backend.hold = 2
      let abandoned = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      backend.started.clear()
      let timedOut = client.lookupProviders(mixes[0], transport, proxy, cid, 1.seconds)
      await backend.started.wait().wait(10.seconds)
      let busy =
        await client.lookupProviders(mixes[0], transport, proxy, cid, 10.seconds)
      require busy.isFailure
      check "ErrTooBusy" in busy.error.msg
      await abandoned.cancelAndWait()
      check abandoned.cancelled
      let timeout = await timedOut
      require timeout.isFailure
      check "timed out" in timeout.error.msg
      backend.release.fire()
      let afterCancel = await client.lookupProviders(mixes[0], transport, proxy, cid)
      check afterCancel.isSuccess
      check opens == 2

      backend.started.clear()
      backend.release.clear()
      backend.hold = 1
      let draining = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      client.retainProxies(@[])
      let replacement = await client.lookupProviders(mixes[0], transport, proxy, cid)
      check replacement.isSuccess
      check opens == 3
      backend.release.fire()
      check (await draining).isSuccess
      await waitForExchange()
      check (await client.lookupProviders(mixes[0], transport, proxy, cid)).isSuccess
      check opens == 3

      backend.started.clear()
      backend.release.clear()
      backend.hold = 2
      let interruptedA = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      backend.started.clear()
      let interruptedB = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      await latest.close()
      check (await interruptedA.wait(10.seconds)).isFailure
      check (await interruptedB.wait(10.seconds)).isFailure
      check (await client.lookupProviders(mixes[0], transport, proxy, cid)).isSuccess
      check opens == 4

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
      await clientDiscovery.closeProxyStreams()
      await transports[^1].stop()
      let unavailable =
        await client.lookupProviders(mixes[0], transport, proxy, cid, 200.milliseconds)
      check unavailable.isFailure
    finally:
      await client.close()
      for transport in transports:
        await transport.stop()
      for switch in switches:
        await switch.stop()

  test "provider packing obeys the stream response limit":
    let records = @[newSeq[byte](100000), newSeq[byte](100000), newSeq[byte](100000)]
    let packed = packProviders(records, MaxLookupResponseBytes, high(uint64)).tryGet()
    check packed.len == 2
    check LookupResponse(
      requestId: high(uint64), code: LookupCode.Ok, providers: packed
    ).encode().len <= MaxLookupResponseBytes
    check packProviders(
      @[newSeq[byte](MaxLookupResponseBytes)], MaxLookupResponseBytes, high(uint64)
    ).error == LookupCode.ErrResponseTooLarge

    let
      maxId = high(uint64)
      sample = LookupResponse(
        requestId: maxId, providers: @[newSeq[byte](MaxLookupResponseBytes)]
      )
      overhead = sample.encode().len - MaxLookupResponseBytes
      largest = @[newSeq[byte](MaxLookupResponseBytes - overhead)]
      exact = packProviders(largest, MaxLookupResponseBytes, maxId).tryGet()
    check LookupResponse(requestId: maxId, providers: exact).encode().len ==
      MaxLookupResponseBytes
    check packProviders(largest, MaxLookupResponseBytes - 1, maxId).error ==
      LookupCode.ErrResponseTooLarge

  test "request ID recovery accepts only one readable nonzero ID":
    check requestIdOf(@[0x18'u8, 41]) == 41
    check requestIdOf(@[0x18'u8, 0]) == 0
    check requestIdOf(@[0x18'u8, 41, 0x18, 42]) == 0
    check requestIdOf(@[0x1d'u8, 1, 0, 0, 0]) == 0
    check requestIdOf(@[0xff'u8]) == 0

import pkg/libp2p/[stream/bufferstream, varint]
import ../../storage/dht_proxy/server

type SlowProxyStream = ref object of BufferStream
  writable: AsyncEvent
  replies: seq[tuple[id: uint64, code: LookupCode]]

proc newSlowStream(): SlowProxyStream =
  let s = SlowProxyStream(writable: newAsyncEvent())
  s.initStream()
  s

method write(
    s: SlowProxyStream, bytes: sink seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  await s.writable.wait()
  var length: uint64
  var prefix: int
  PB.getUVarint(bytes, prefix, length).expect("valid response prefix")
  doAssert bytes.len - prefix == length.int
  let reply = LookupResponse.decode(bytes[prefix .. ^1]).expect("valid response")
  s.replies.add((reply.requestId, reply.code))

proc frame(id: uint64): seq[byte] =
  let
    payload = LookupRequest(requestId: id, queryBytes: @[1'u8]).encode()
    prefix = PB.toBytes(payload.len.uint64)
  result.add(prefix.toOpenArray())
  result.add(payload)

asyncchecksuite "DHT proxy admission":
  test "a stalled writer bounds buffered work and retains its global reservations":
    let
      slow = newSlowStream()
      active = newSlowStream()
      probe = newSlowStream()
      release = newAsyncEvent()
    active.writable.fire()
    probe.writable.fire()
    var lookups = 0

    proc lookup(
        req: LookupRequest
    ): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
      inc lookups
      if req.requestId == 10:
        await release.wait()
      return LookupResponse(
        code: LookupCode.Ok, providers: @[newSeq[byte](MaxLookupResponseBytes - 32)]
      )

    let
      serve = newProxyHandler(5, lookup)
      handlers = @[
        serve(slow, DhtProxyCodec),
        serve(active, DhtProxyCodec),
        serve(probe, DhtProxyCodec),
      ]
    try:
      var batch: seq[byte]
      for id in 1'u64 .. 6'u64:
        batch.add(frame(id))
      await slow.pushData(batch)
      # Four workers hold completed results. The fifth request is blocked
      # writing its busy response. The reader leaves request six untouched.
      check eventually (lookups == 4 and slow.len == frame(6).len)
      await active.pushData(frame(10))
      check eventually lookups == 5
      await probe.pushData(frame(20))
      check eventually probe.replies == @[(20'u64, LookupCode.ErrTooBusy)]
      check lookups == 5

      release.fire()
      check eventually active.replies == @[(10'u64, LookupCode.Ok)]
      await probe.pushData(frame(21))
      check eventually probe.replies.len == 2
      check probe.replies[^1] == (21'u64, LookupCode.Ok)
      slow.writable.fire()
      check eventually slow.replies.len == 6
      check (5'u64, LookupCode.ErrTooBusy) in slow.replies
      for id in 1'u64 .. 4'u64:
        check (id, LookupCode.Ok) in slow.replies
    finally:
      for handler in handlers:
        handler.cancelSoon()
      for handler in handlers:
        await handler.cancelAndWait()
