## Local experiment only. Load driver for adaptive concurrency per Mix DHT
## proxy. Lookups enter through Discovery.findBatches, the call the download
## engine makes, and reach the mounted DhtProxyProtocol handler. Only the DHT
## search behind the proxy is simulated.
##
##   proxyload <mode> <scene> <seed> [key=value ...]
import std/[deques, math, os, random, sequtils, strutils, tables]
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/[cid, routing_record, stream/bufferstream, varint]
import pkg/libp2p_mix
import pkg/libp2p_mix/[pool, delay_strategy]
import pkg/questionable/results
import ../storage/[blocktype, discovery, peertransport, rng]
import ../storage/dht_proxy/[experiment, handler]
import ./storage/helpers/switchutils

type
  Settings = object
    mode, scene: string
    seed: int
    capacity, callers, cids: int
    delayMs, linkBytes, slowRate: int
    fastLowMs, fastHighMs, slowLowMs, slowHighMs: int
    slowShare: float
    deadlineMs: int
    bigBytes: int
    lateMs, lightCallers, lightCids: int
    mixNodes: int

  Pipe = ref object of BufferStream
    ## One direction of an in-memory link with latency, a bounded amount of
    ## data in transit and an optional delivery rate.
    peer: Pipe
    delay: Duration
    rate: int
    capacity: int
    inTransit: int
    queue: Deque[(Moment, seq[byte])]
    wake, space: AsyncEvent
    pump: Future[void]
    sentEof: bool

  Wire = ref object of PeerTransport
    node: int
    settings: Settings
    serve: LPProtoHandler
    downRate: int
    dials: int
    pipes: seq[Pipe]
    handlers: seq[Future[void]]

  Backend = ref object of Discovery
    durations: Table[Cid, Duration]
    replies: Table[Cid, seq[PeerRecord]]
    holds: Table[Cid, AsyncEvent]
    holdAll: AsyncEvent
    small: seq[PeerRecord]

  Node = ref object
    index: int
    discovery: Discovery
    next, total, callers: int
    startAfter: Duration
    until: Node
    big: bool
    finished: bool

var
  settings {.threadvar.}: Settings
  backend {.threadvar.}: Backend
  bigReply {.threadvar.}: seq[PeerRecord]

# --- in-memory link ---------------------------------------------------------

proc pumpLoop(s: Pipe) {.async: (raises: []).} =
  try:
    while true:
      while s.queue.len == 0:
        s.wake.clear()
        await s.wake.wait()
      let (due, bytes) = s.queue.popFirst()
      let now = Moment.now()
      if due > now:
        await sleepAsync(due - now)
      if bytes.len == 0:
        await s.peer.pushEof()
        return
      if s.rate > 0:
        await sleepAsync(microseconds(int64(bytes.len) * 1_000_000 div s.rate))
      let size = bytes.len
      await s.peer.pushData(bytes)
      s.inTransit -= size
      s.space.fire()
  except CancelledError, LPStreamError:
    discard
  finally:
    s.inTransit = 0
    s.space.fire()

method write(
    s: Pipe, bytes: sink seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  if s.closed or s.sentEof:
    raise newLPStreamClosedError()
  while s.inTransit > 0 and s.inTransit + bytes.len > s.capacity:
    s.space.clear()
    await s.space.wait()
    if s.closed or s.pump.finished:
      raise newLPStreamClosedError()
  if s.pump.finished:
    raise newLPStreamClosedError()
  s.inTransit += bytes.len
  s.queue.addLast((Moment.now() + s.delay, bytes))
  s.wake.fire()

method closeImpl(s: Pipe): Future[void] {.async: (raises: [], raw: true).} =
  if not s.sentEof:
    s.sentEof = true
    s.queue.addLast((Moment.now() + s.delay, newSeq[byte]()))
    s.wake.fire()
  s.space.fire()
  procCall BufferStream(s).closeImpl()

proc newPipe(delay: Duration, rate, capacity: int): Pipe =
  let s = Pipe(
    timeout: 10.minutes,
    delay: delay,
    rate: rate,
    capacity: capacity,
    wake: newAsyncEvent(),
    space: newAsyncEvent(),
  )
  s.initStream()
  s

method kind(w: Wire): DownloadTransport =
  DownloadTransport.Mix

method dial(
    w: Wire, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  inc w.dials
  let
    delay = w.settings.delayMs.milliseconds
    toProxy = newPipe(delay, 0, w.settings.linkBytes)
    toClient = newPipe(delay, w.downRate, w.settings.linkBytes)
  toProxy.peer = toClient
  toClient.peer = toProxy
  toProxy.pump = toProxy.pumpLoop()
  toClient.pump = toClient.pumpLoop()
  w.pipes.add(toProxy)
  w.pipes.add(toClient)
  # The proxy numbers accepted streams in this order.
  event("dial", w.node, w.dials)
  w.handlers.add(w.serve(toClient, codec))
  return success(Connection(toProxy))

proc shutdown(w: Wire) {.async.} =
  for handler in w.handlers:
    await handler.cancelAndWait()
  for pipe in w.pipes:
    await pipe.close()
  for pipe in w.pipes:
    await pipe.pump.cancelAndWait()
    pipe.peer = nil

# --- simulated DHT search ---------------------------------------------------

method findDirect(
    b: Backend, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  if not b.holdAll.isNil:
    await b.holdAll.wait()
  let hold = b.holds.getOrDefault(cid)
  if not hold.isNil:
    await hold.wait()
  await sleepAsync(b.durations.getOrDefault(cid, 200.milliseconds))
  return success(b.replies.getOrDefault(cid, b.small))

proc cidFor(node, index: int): Cid =
  blocktype.Block.new(
    @[byte(settings.seed and 255), byte(node), byte(index shr 8), byte(index and 255)]
  ).tryGet().cid

proc searchTime(node, index: int): Duration =
  var r = initRand(int64(settings.seed) * 1_000_003 + int64(node) * 10_007 + index + 1)
  if r.rand(1.0) < settings.slowShare:
    r.rand(settings.slowLowMs .. settings.slowHighMs).milliseconds
  else:
    r.rand(settings.fastLowMs .. settings.fastHighMs).milliseconds

# --- lookups through the downloader's discovery call -----------------------

proc lookup(
    node: Node, index: int, deadline: Duration, register = true
): Future[bool] {.async.} =
  let cid = cidFor(node.index, index)
  if register:
    backend.durations[cid] = searchTime(node.index, index)
    if node.big:
      backend.replies[cid] = bigReply
  var got = 0
  proc deliver(batch: seq[PeerRecord]) {.gcsafe, raises: [].} =
    got += batch.len
  event("start", cid, node.index, tail(cid.data.buffer), deadline.milliseconds)
  try:
    let res =
      await node.discovery.findBatches(cid, true, Moment.now() + deadline, deliver)
    if res.isOk:
      let expected = backend.replies.getOrDefault(cid, backend.small).len
      doAssert got == expected, "provider count " & $got & " != " & $expected
      event("ok", cid, node.index, got)
      return true
    event("fail", cid, node.index, res.error.msg.replace(' ', '_'))
    return false
  except CancelledError as exc:
    event("cancelled", cid, node.index)
    raise exc

proc drive(node: Node) {.async.} =
  if node.startAfter > ZeroDuration:
    await sleepAsync(node.startAfter)
  event("node-start", node.index, node.callers)
  proc caller() {.async.} =
    while true:
      if node.until.isNil:
        if node.next >= node.total:
          break
      elif node.until.finished:
        break
      let index = node.next
      inc node.next
      discard await node.lookup(index, settings.deadlineMs.milliseconds)
  var callers: seq[Future[void]]
  for _ in 0 ..< node.callers:
    callers.add(caller())
  await allFutures(callers)
  for fut in callers:
    fut.read()
  node.finished = true
  event("node-done", node.index, node.next)

proc policies(mode: string, capacity: int): (ClientPolicy, ProxyPolicy) =
  var
    client = StockClientPolicy
    proxy = StockProxyPolicy
  client.initialWindow = 4
  client.decrease = 0.5
  client.backoffBase = 100.milliseconds
  client.backoffMax = 1600.milliseconds
  let budget = ProxyPolicy(
    softShare: true,
    headroom: max(1, capacity div 10),
    replyBudget: 1024 * 1024,
    maxUnwritten: 32,
  )
  case mode
  of "stock":
    discard
  of "fixed4", "fixed8", "fixed16":
    client.window = parseInt(mode[5 .. ^1])
    client.retryBusy = true
    proxy.perStream = client.window
  of "nocap":
    client.window = 0
    client.retryBusy = true
    proxy.perStream = 0
  of "adaptive", "adaptive-b75", "adaptive-noshare", "adaptive-oldproxy":
    client.adaptive = true
    client.retryBusy = true
    proxy = budget
    if mode == "adaptive-b75":
      client.decrease = 0.75
    elif mode == "adaptive-noshare":
      proxy.softShare = false
    elif mode == "adaptive-oldproxy":
      proxy = StockProxyPolicy
  of "stated", "stated-probe", "stated-probe-oldproxy":
    client.followLimit = true
    client.probe = mode != "stated"
    client.retryBusy = true
    proxy = budget
    proxy.advertise = true
    if mode == "stated-probe-oldproxy":
      proxy = StockProxyPolicy
  else:
    quit("unknown mode " & mode, 2)
  (client, proxy)

# --- scenes over the in-memory link ----------------------------------------

proc makeBigReply(peer: PeerId, address: MultiAddress): seq[PeerRecord] =
  let record = PeerRecord.init(peer, @[address])
  for _ in 0 ..< settings.bigBytes div record.encode().len:
    result.add(record)

proc rawRequests(node: int, count: int): seq[byte] =
  ## Requests written straight onto a proxy stream, to occupy lookup slots.
  for i in 1 .. count:
    let cid = cidFor(node, i)
    backend.durations[cid] = 100.milliseconds
    let req = LookupRequest(
      requestId: i.uint64, queryType: QueryType.FindProviders, queryBytes: cid.data.buffer
    ).encode()
    result.add(PB.toBytes(req.len.uint64).toOpenArray())
    result.add(req)

proc pipeScene() {.async.} =
  let
    address = MultiAddress.init("/ip4/127.0.0.1/tcp/4001").tryGet()
    info = MixNodeInfo.generateRandom(0, Rng.instance().libp2pRng)
    mix = MixProtocol.new(info, newStandardSwitch())
  mix.setLocalMultiAddr(address).tryGet()
  let
    proxy = PeerRecord.init(
      info.peerId, @[mix.localMixPubInfo.tryGet().toMixAddress().tryGet()]
    )
    serve = DhtProxyProtocol.new(backend, settings.capacity).handler
  backend.small = @[PeerRecord.init(info.peerId, @[address])]
  bigReply = makeBigReply(info.peerId, address)

  var
    nodes: seq[Node]
    wires: seq[Wire]
  proc addNode(callers, total: int): Node =
    let wire = Wire(node: nodes.len, settings: settings, serve: serve)
    let node = Node(
      index: nodes.len,
      callers: callers,
      total: total,
      discovery: Discovery(
        mixProto: mix, mixPeerTransport: wire, staticDhtMixProxies: @[proxy]
      ),
    )
    nodes.add(node)
    wires.add(wire)
    node

  case settings.scene
  of "one":
    discard addNode(settings.callers, settings.cids)
  of "four", "eight":
    for _ in 0 ..< (if settings.scene == "four": 4 else: 8):
      discard addNode(settings.callers, settings.cids)
  of "late":
    # One node has the proxy to itself before three more arrive.
    discard addNode(settings.callers, settings.cids)
    for _ in 0 ..< 3:
      addNode(settings.callers, settings.cids).startAfter = settings.lateMs.milliseconds
  of "skew":
    # One busy node beside three nodes with little to look up.
    discard addNode(settings.callers, settings.cids)
    for _ in 0 ..< 3:
      discard addNode(settings.lightCallers, settings.lightCids)
  of "slow":
    # Node 0 receives large replies over a slow link.
    let slow = addNode(settings.callers, settings.cids div 4)
    slow.big = true
    wires[0].downRate = settings.slowRate
    for _ in 0 ..< 3:
      discard addNode(settings.callers, settings.cids)
  of "deadline":
    discard
  else:
    quit("unknown scene " & settings.scene, 2)

  if settings.scene == "deadline":
    # Every search takes 100 to 300 ms here so the timings show the waiting.
    settings.slowShare = 0
    # Raw streams fill every lookup slot while the simulated search is held.
    let
      policy = proxyPolicy()
      per = if policy.perStream > 0: policy.perStream else: settings.capacity
      hogs = (settings.capacity + per - 1) div per
      victim = addNode(1, 0)
    backend.holdAll = newAsyncEvent()
    var
      hogPipes: seq[Pipe]
      hogHandlers: seq[Future[void]]
    for hog in 0 ..< hogs:
      let
        toProxy = newPipe(ZeroDuration, 0, 1 shl 20)
        toHog = newPipe(ZeroDuration, 0, 1 shl 30)
      toProxy.peer = toHog
      toHog.peer = toProxy
      toProxy.pump = toProxy.pumpLoop()
      toHog.pump = toHog.pumpLoop()
      hogPipes.add(toProxy)
      hogPipes.add(toHog)
      event("dial", 100 + hog, 1)
      hogHandlers.add(serve(toHog, DhtProxyCodec))
      await toProxy.write(rawRequests(100 + hog, per))
    proc drain(pipe: Pipe) {.async.} =
      var buf: array[4096, byte]
      try:
        while true:
          discard await pipe.readOnce(addr buf[0], buf.len)
      except CancelledError, LPStreamError:
        discard
    var drains: seq[Future[void]]
    for i in countup(0, hogPipes.high, 2):
      drains.add(drain(hogPipes[i]))
    await sleepAsync(50.milliseconds)
    event("phase", "saturated")

    # A: a short deadline expires while the proxy stays busy.
    let expiring = victim.lookup(0, 1500.milliseconds)
    # B: a caller is cancelled while its request waits to be retried.
    let abandoned = victim.lookup(1, 60.seconds)
    await sleepAsync(700.milliseconds)
    # Without retries the busy reply has already failed this lookup.
    await abandoned.cancelAndWait()
    discard await expiring
    # C: a lookup that started while the proxy was busy completes afterwards.
    let patient = victim.lookup(2, 60.seconds)
    await sleepAsync(1500.milliseconds)
    event("phase", "released")
    backend.holdAll.fire()
    discard await patient
    # D: a caller is cancelled after the proxy admitted its request.
    let heldCid = cidFor(victim.index, 3)
    backend.holds[heldCid] = newAsyncEvent()
    let admitted = victim.lookup(3, 60.seconds)
    await sleepAsync(1.seconds)
    await admitted.cancelAndWait()
    doAssert admitted.cancelled
    backend.holds[heldCid].fire()
    await sleepAsync(500.milliseconds)
    # E: the same stream still serves the next lookup.
    discard await victim.lookup(4, 60.seconds)
    event("dials", victim.index, wires[0].dials)
    for handler in hogHandlers:
      await handler.cancelAndWait()
    for fut in drains:
      await fut.cancelAndWait()
    for pipe in hogPipes:
      await pipe.close()
    for pipe in hogPipes:
      await pipe.pump.cancelAndWait()
      pipe.peer = nil
  else:
    var runs: seq[Future[void]]
    for node in nodes:
      runs.add(node.drive())
    await allFutures(runs)
    for fut in runs:
      fut.read()
    for i, wire in wires:
      event("dials", i, wire.dials)

  for node in nodes:
    await node.discovery.closeProxyStreams()
  # Let the proxy see each stream close before the harness stops it.
  await sleepAsync((2 * settings.delayMs + 200).milliseconds)
  for wire in wires:
    await wire.shutdown()

# --- scenes over real MixTransport -----------------------------------------

proc mixScene() {.async.} =
  let
    rng = newRng()
    listen = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
    clients = if settings.scene == "mix1": 1 else: 3
  var
    infos = MixNodeInfo.generateRandomMany(settings.mixNodes, rng)
    switches: seq[Switch]
    mixes: seq[MixProtocol]
    transports: seq[MixTransport]
    nodes: seq[Node]
  try:
    for i, info in infos:
      let sw = SwitchBuilder
        .new()
        .withRng(rng)
        .withPrivateKey(PrivateKey(scheme: Secp256k1, skkey: info.libp2pPrivKey))
        .withAddress(listen)
        .withTcpTransport()
        .withYamux()
        .withNoise()
        .build()
      let mix = MixProtocol.new(
        info,
        sw,
        delayStrategy = Opt.some(DelayStrategy(NoSamplingDelayStrategy.new(rng))),
      )
      sw.mount(mix)
      if i == infos.high:
        sw.mount(DhtProxyProtocol.new(backend, settings.capacity))
      switches.add(sw)
      mixes.add(mix)
      await sw.start()
      infos[i].multiAddr = sw.peerInfo.listenAddrs[0]
      mix.setLocalMultiAddr(infos[i].multiAddr).tryGet()
    for i, mix in mixes:
      mix.nodePool.add(infos.includeAllExcept(infos[i]))
      await mix.start()
      let transport = newMixTransport(mix)
      (await transport.start()).tryGet()
      transports.add(transport)
    let proxy = PeerRecord.init(
      infos[^1].peerId, @[mixes[^1].localMixPubInfo.tryGet().toMixAddress().tryGet()]
    )
    backend.small = @[proxy]
    bigReply = makeBigReply(infos[^1].peerId, infos[^1].multiAddr)
    for n in 0 ..< clients:
      nodes.add(
        Node(
          index: n,
          callers: settings.callers,
          total: settings.cids,
          discovery: Discovery(
            mixProto: mixes[n],
            mixPeerTransport: MixPeerTransport.new(transports[n]),
            staticDhtMixProxies: @[proxy],
          ),
        )
      )
    if settings.scene == "mixslow":
      nodes[0].big = true
      nodes[0].total = settings.cids div 4
    var runs: seq[Future[void]]
    for node in nodes:
      runs.add(node.drive())
    await allFutures(runs)
    for fut in runs:
      fut.read()
  finally:
    for node in nodes:
      await node.discovery.closeProxyStreams()
    await sleepAsync(500.milliseconds)
    for transport in transports:
      await transport.stop()
    for sw in switches:
      await sw.stop()

proc main() {.async.} =
  settings = Settings(
    mode: paramStr(1),
    scene: paramStr(2),
    seed: parseInt(paramStr(3)),
    capacity: 20,
    callers: 32,
    cids: 192,
    delayMs: 150,
    linkBytes: 64 * 1024,
    slowRate: 256 * 1024,
    fastLowMs: 100,
    fastHighMs: 300,
    slowLowMs: 2000,
    slowHighMs: 4000,
    slowShare: 0.2,
    deadlineMs: 60_000,
    bigBytes: 240 * 1024,
    lateMs: 5000,
    lightCallers: 2,
    lightCids: 20,
    mixNodes: 6,
  )
  for i in 4 .. paramCount():
    let pair = paramStr(i).split('=', 1)
    doAssert pair.len == 2, paramStr(i)
    case pair[0]
    of "capacity": settings.capacity = parseInt(pair[1])
    of "callers": settings.callers = parseInt(pair[1])
    of "cids": settings.cids = parseInt(pair[1])
    of "delayMs": settings.delayMs = parseInt(pair[1])
    of "linkBytes": settings.linkBytes = parseInt(pair[1])
    of "slowRate": settings.slowRate = parseInt(pair[1])
    of "fastLowMs": settings.fastLowMs = parseInt(pair[1])
    of "fastHighMs": settings.fastHighMs = parseInt(pair[1])
    of "slowLowMs": settings.slowLowMs = parseInt(pair[1])
    of "slowHighMs": settings.slowHighMs = parseInt(pair[1])
    of "slowShare": settings.slowShare = parseFloat(pair[1])
    of "deadlineMs": settings.deadlineMs = parseInt(pair[1])
    of "bigBytes": settings.bigBytes = parseInt(pair[1])
    of "lateMs": settings.lateMs = parseInt(pair[1])
    of "lightCallers": settings.lightCallers = parseInt(pair[1])
    of "lightCids": settings.lightCids = parseInt(pair[1])
    of "mixNodes": settings.mixNodes = parseInt(pair[1])
    else: quit("unknown setting " & pair[0], 2)
  let (client, proxy) = policies(settings.mode, settings.capacity)
  configure(client, proxy, settings.seed)
  event("config", $settings)
  event("client-policy", $client)
  event("proxy-policy", $proxy)
  backend = Backend()
  if settings.scene.startsWith("mix"):
    await mixScene()
  else:
    await pipeScene()
  event("done", settings.capacity)

waitFor main()
