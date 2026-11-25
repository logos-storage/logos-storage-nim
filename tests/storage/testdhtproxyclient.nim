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
  dials, active, passFirst, failFirst: int
  failAfter: Duration
  replacement: AsyncEvent

method kind(self: GatedTransport): DownloadTransport =
  DownloadTransport.Mix

method dial(
    self: GatedTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  inc self.dials
  inc self.active
  defer:
    dec self.active
  if self.dials == 6 and not self.replacement.isNil:
    self.replacement.fire()
  if self.dials <= self.failFirst:
    await sleepAsync(self.failAfter)
    return failure("Gated dial failed")
  if self.dials > self.passFirst:
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
        protocol = DhtProxyProtocol.new(backend, maxInFlight = MaxLookupsPerStream)
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

      backend.release.clear()
      backend.hold = MaxLookupsPerStream
      var held: seq[Future[?!seq[PeerRecord]]]
      for i in 0 ..< MaxLookupsPerStream:
        backend.started.clear()
        held.add(client.lookupProviders(mixes[0], transport, proxy, cid))
        await backend.started.wait().wait(10.seconds)
      # A different client can still receive the proxy-wide capacity error.
      let busy = await lookupProviders(mixes[0], transport, proxy, cid, 10.seconds)
      require busy.isFailure
      check "ErrTooBusy" in busy.error.msg
      await waitForExchange()
      let queued = client.lookupProviders(mixes[0], transport, proxy, cid)
      let timedOut =
        await client.lookupProviders(mixes[0], transport, proxy, cid, 1.seconds)
      require timedOut.isFailure
      check "timed out" in timedOut.error.msg
      check not queued.finished
      backend.release.fire()
      for call in held:
        check (await call).isSuccess
      check (await queued).isSuccess
      check opens == 3

      backend.started.clear()
      backend.release.clear()
      backend.hold = 2
      let abandoned = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      backend.started.clear()
      let expires = client.lookupProviders(mixes[0], transport, proxy, cid, 1.seconds)
      await backend.started.wait().wait(10.seconds)
      await abandoned.cancelAndWait()
      check abandoned.cancelled
      let timeout = await expires
      require timeout.isFailure
      check "timed out" in timeout.error.msg
      backend.release.fire()
      let afterCancel = await client.lookupProviders(mixes[0], transport, proxy, cid)
      check afterCancel.isSuccess
      check opens == 3

      backend.started.clear()
      backend.release.clear()
      backend.hold = 1
      let draining = client.lookupProviders(mixes[0], transport, proxy, cid)
      await backend.started.wait().wait(10.seconds)
      client.retainProxies(@[])
      let replacement = await client.lookupProviders(mixes[0], transport, proxy, cid)
      check replacement.isSuccess
      check opens == 4
      backend.release.fire()
      check (await draining).isSuccess
      await waitForExchange()
      check (await client.lookupProviders(mixes[0], transport, proxy, cid)).isSuccess
      check opens == 4

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
      check opens == 5

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
  test "a new stream must start its first request within the request read timeout":
    proc lookup(
        req: LookupRequest
    ): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
      return LookupResponse(code: LookupCode.NotFound)

    let serve = newProxyHandler(1, lookup)
    let idle = newSlowStream()
    let active = newSlowStream()
    active.writable.fire()
    let established = serve(active, DhtProxyCodec)
    let unopened = serve(idle, DhtProxyCodec)
    try:
      await active.pushData(frame(1))
      await unopened.wait(DhtProxyRequestReadTimeout + 2.seconds)
      check idle.closed
      await active.pushData(frame(2))
      check eventually active.replies.len == 2
    finally:
      await unopened.cancelAndWait()
      await established.cancelAndWait()

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

type GatedBackend = ref object of Discovery
  ready: AsyncEvent
  reply: Future[?!seq[PeerRecord]].Raising([CancelledError])
  calls: int

method findDirect(
    self: GatedBackend, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  inc self.calls
  self.ready.fire()
  return await self.reply

asyncchecksuite "Concurrent Mix provider discovery":
  test "refills five outstanding attempts until a usable result, then drains":
    let
      rng = newRng()
      listen = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      arrived = newAsyncEvent()
      discovery = Discovery()
      cid = Cid.example
    var
      infos = MixNodeInfo.generateRandomMany(9, rng)
      switches: seq[Switch]
      mixes: seq[MixProtocol]
      transports: seq[MixTransport]
      backends: seq[GatedBackend]
      released: seq[int]
      batches: seq[seq[PeerRecord]]
      received = newAsyncEvent()

    proc attempts(): int =
      for backend in backends:
        result += backend.calls

    proc waitForAttempts(n: int) {.async.} =
      while attempts() < n:
        arrived.clear()
        await arrived.wait().wait(10.seconds)
      check attempts() == n

    proc respond(reply: ?!seq[PeerRecord]) =
      for i, backend in backends:
        if backend.calls > 0 and i notin released:
          released.add(i)
          backend.reply.complete(reply)
          return
      doAssert false, "no pending request"

    try:
      for i, info in infos:
        let
          switch = SwitchBuilder
            .new()
            .withRng(rng)
            .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: info.libp2pPrivKey))
            .withAddress(listen)
            .withTcpTransport()
            .withYamux()
            .withNoise()
            .build()
          mix = MixProtocol.new(
            info,
            switch,
            delayStrategy = Opt.some(DelayStrategy(NoSamplingDelayStrategy.new(rng))),
          )
        switches.add(switch)
        mixes.add(mix)
        switch.mount(mix)
        if i > 0:
          let backend = GatedBackend(
            ready: arrived,
            reply: Future[?!seq[PeerRecord]].Raising([CancelledError]).init(),
          )
          backends.add(backend)
          switch.mount(DhtProxyProtocol.new(backend))
        await switch.start()
        infos[i].multiAddr = switch.peerInfo.listenAddrs[0]
        mix.setLocalMultiAddr(infos[i].multiAddr).tryGet()
      for i, mix in mixes:
        mix.nodePool.add(infos.includeAllExcept(infos[i]))
        await mix.start()
        let transport = newMixTransport(mix)
        (await transport.start()).tryGet()
        transports.add(transport)
        if i > 0:
          let record = PeerRecord.init(
            infos[i].peerId, @[mix.localMixPubInfo.tryGet().toMixAddress().tryGet()]
          )
          discovery.staticDhtMixProxies.add(@[record, record])

      discovery.mixProto = mixes[0]
      discovery.mixPeerTransport = MixPeerTransport.new(transports[0])
      let
        start = Moment.now()
        provider = discovery.staticDhtMixProxies[0]
        extra = discovery.staticDhtMixProxies[^1]
      proc receive(batch: seq[PeerRecord]) =
        batches.add(batch)
        echo "provider batch ",
          batches.len,
          " elapsed_ms=",
          (Moment.now() - start).milliseconds,
          " records=",
          batch.len,
          " attempts=",
          attempts()
        received.fire()

      let query = discovery.findBatches(cid, true, start + 60.seconds, receive)
      await waitForAttempts(5)
      respond(success(newSeq[PeerRecord]()))
      await waitForAttempts(6)
      respond(seq[PeerRecord].failure("fixture lookup error"))
      await waitForAttempts(7)
      respond(success(@[provider]))
      await received.wait().wait(10.seconds)
      check not query.finished
      received.clear()
      respond(success(@[provider, extra]))
      await received.wait().wait(10.seconds)
      for _ in 0 ..< 3:
        respond(success(newSeq[PeerRecord]()))
      check (await query.wait(10.seconds)).isOk
      check batches == @[@[provider], @[provider, extra]]
      check attempts() == 7
      for backend in backends:
        check backend.calls <= 1

      # The manifest caller needs one nonempty list. Hold all but two stream
      # opens, so cancellation of the remaining attempts is observable.
      await discovery.closeProxyStreams()
      let openTwo = GatedTransport(
        next: discovery.mixPeerTransport,
        ready: newAsyncEvent(),
        replacement: newAsyncEvent(),
        passFirst: 2,
      )
      discovery.mixPeerTransport = openTwo
      released.setLen(0)
      for backend in backends:
        backend.calls = 0
        backend.reply = Future[?!seq[PeerRecord]].Raising([CancelledError]).init()
      let manifest = discovery.find(cid, useMix = true)
      await waitForAttempts(2)
      respond(success(newSeq[PeerRecord]()))
      await openTwo.replacement.wait().wait(5.seconds)
      check not manifest.finished
      check openTwo.active == 4
      respond(success(@[provider]))
      let first = await manifest.wait(5.seconds)
      require first.isOk
      check first.get == @[provider]
      check openTwo.active == 0
      check openTwo.dials == 6

      discovery.mixPeerTransport = openTwo.next
      for backend in backends:
        backend.calls = 0
        backend.reply = Future[?!seq[PeerRecord]].Raising([CancelledError]).init()
        backend.reply.complete(success(newSeq[PeerRecord]()))
      let empty = await discovery.find(cid, useMix = true)
      require empty.isOk
      check empty.get.len == 0
      for backend in backends:
        check backend.calls == 1

      # Five stalled dials keep their places past the former 30-second attempt
      # limit. No replacement starts while the lookup deadline still runs.
      await discovery.closeProxyStreams()
      let stalled = GatedTransport(ready: newAsyncEvent(), replacement: newAsyncEvent())
      discovery.mixPeerTransport = stalled
      let held = discovery.findBatches(cid, true, Moment.now() + 60.seconds, receive)
      check stalled.active == 5
      await sleepAsync(32.seconds)
      check not held.finished
      check stalled.active == 5
      check stalled.dials == 5
      check not stalled.replacement.isSet
      await held.cancelAndWait()
      check held.cancelled
      check stalled.active == 0

      # Attempts that stay silent until the deadline end the lookup there, and
      # no replacement starts.
      let quiet = GatedTransport(ready: newAsyncEvent(), replacement: newAsyncEvent())
      discovery.mixPeerTransport = quiet
      let silent = discovery.findBatches(cid, true, Moment.now() + 2.seconds, receive)
      check quiet.active == 5
      check (await silent.wait(10.seconds)).isErr
      check quiet.dials == 5
      check not quiet.replacement.isSet
      check quiet.active == 0

      # A dial that fails after four seconds frees its place at once. Its
      # replacement starts with about two seconds left on the six-second
      # deadline and ends there. A fresh six-second allowance would outlast
      # the four-second wait below.
      let failing = GatedTransport(
        ready: newAsyncEvent(),
        replacement: newAsyncEvent(),
        failFirst: 1,
        failAfter: 4.seconds,
      )
      discovery.mixPeerTransport = failing
      let refilled = discovery.findBatches(cid, true, Moment.now() + 6.seconds, receive)
      check failing.active == 5
      await sleepAsync(2.seconds)
      check failing.dials == 5
      check not failing.replacement.isSet
      await failing.replacement.wait().wait(10.seconds)
      check failing.active == 5
      check (await refilled.wait(4.seconds)).isErr
      check failing.dials == 6
      check failing.active == 0

      discovery.mixPeerTransport = quiet
      let short =
        await discovery.findBatches(cid, true, Moment.now() + 50.milliseconds, receive)
      check short.isErr
      check quiet.active == 0
      check batches.len == 2
    finally:
      await discovery.closeProxyStreams()
      for transport in transports:
        await transport.stop()
      for switch in switches:
        await switch.stop()
