## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sequtils, strutils, tables]

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/cid
import pkg/libp2p/routing_record
import pkg/libp2p_mix

import ../errors
import ../logutils
import ../utils/mixidentity
import ../peertransport
import ./protocol
import ./experiment

const DefaultLookupTimeout* = 90.seconds

logScope:
  topics = "storage dht-proxy client"

type
  Pending = ref object
    ready: AsyncEvent
    reply: LookupResponse
    limited: bool # the window was full when this request was sent

  ProxyStream = ref object
    peer: PeerId
    ready: AsyncEvent
    slotAvailable: AsyncEvent
    writer: AsyncLock
    conn: Connection
    reader: Future[void]
    pending: Table[uint64, Pending]
    highWater: uint64
    window, slowStartLimit, credits: int
    stated, extra: int # the proxy's stated limit and the probe above it
    reducedAt: uint64 # highest ID sent before the last window reduction
    callers: int
    draining: bool
    failure: string

  ProxyClient* = ref object
    streams: Table[PeerId, ProxyStream]
    live: seq[ProxyStream]

const MaxPendingPerStream = 32

proc limit(s: ProxyStream): int =
  let policy = clientPolicy()
  if policy.adaptive or policy.followLimit:
    s.window
  elif policy.window == 0:
    MaxPendingPerStream
  else:
    policy.window

proc adjustWindow(s: ProxyStream, call: Pending) =
  ## Grow by one per reply until the first busy reply, then by one per full
  ## window of replies. One busy reply shrinks the window once for all the
  ## requests that were already sent.
  let policy = clientPolicy()
  if policy.followLimit:
    if call.reply.limit.isSome:
      s.stated = int(min(call.reply.limit.get, MaxPendingPerStream.uint64))
    if policy.probe:
      # Requests in transit hold a place in the window but no proxy slot, so
      # the stated limit alone leaves slots idle. Add one request per full
      # window of replies and halve the addition after a busy reply.
      if call.reply.code == LookupCode.ErrTooBusy:
        if call.reply.requestId > s.reducedAt:
          s.extra = s.extra div 2
          s.reducedAt = s.highWater
          s.credits = 0
      elif call.limited:
        inc s.credits
        if s.credits >= s.window:
          inc s.extra
          s.credits = 0
    let window = clamp(s.stated + s.extra, 1, MaxPendingPerStream)
    if window != s.window:
      s.window = window
      event("window", s.peer, s.window, s.stated)
    return
  if not policy.adaptive:
    return
  if call.reply.code == LookupCode.ErrTooBusy:
    if call.reply.requestId > s.reducedAt:
      s.window = max(1, int(float(s.window) * policy.decrease))
      s.slowStartLimit = s.window
      s.reducedAt = s.highWater
      s.credits = 0
      event("window", s.peer, s.window, "busy")
  elif call.limited and s.window < MaxPendingPerStream:
    if s.window < s.slowStartLimit:
      inc s.window
    else:
      inc s.credits
      if s.credits >= s.window:
        inc s.window
        s.credits = 0
    event("window", s.peer, s.window, "reply")

proc evict(client: ProxyClient, s: ProxyStream) =
  if client.streams.getOrDefault(s.peer) == s:
    client.streams.del(s.peer)

proc failStream(client: ProxyClient, s: ProxyStream, reason: string) =
  if s.failure.len == 0:
    s.failure = reason
    client.evict(s)
    s.ready.fire()
    s.slotAvailable.fire()
    for call in s.pending.values:
      call.ready.fire()

proc abort(client: ProxyClient, s: ProxyStream, reason: string) =
  client.failStream(s, reason)
  s.reader.cancelSoon()

proc connectAndRead(
    client: ProxyClient, s: ProxyStream, transport: PeerTransport, proxy: PeerRecord
) {.async: (raises: [CancelledError]).} =
  try:
    s.conn = (await transport.dial(proxy, DhtProxyCodec)).valueOr:
      client.failStream(s, "Failed to open MixTransport stream: " & error.msg)
      return
    s.ready.fire()
    while true:
      var first: byte
      await s.conn.readExactly(addr first, 1)
      let bytes = await readFrameBody(s.conn, first, MaxLookupResponseBytes).wait(
        DhtProxyExchangeTimeout
      )
      let reply = LookupResponse.decode(bytes).valueOr:
        client.failStream(s, "Invalid DHT proxy response")
        return
      if reply.requestId == 0 or reply.requestId > s.highWater:
        client.failStream(s, "Unknown DHT proxy request ID")
        return
      var call: Pending
      if s.pending.pop(reply.requestId, call):
        call.reply = reply
        s.adjustWindow(call)
        s.slotAvailable.fire()
        call.ready.fire()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    client.failStream(s, "DHT proxy stream failed: " & exc.msg)
  finally:
    client.failStream(s, "DHT proxy stream closed")
    if not s.conn.isNil:
      await noCancel s.conn.close()
    client.live.keepItIf(it != s)
    event("stream-closed", s.peer, client.live.len, s.failure.replace(' ', '_'))

proc retainProxies*(client: ProxyClient, proxies: seq[PeerRecord]) =
  if client.isNil:
    return
  for s in client.live:
    if not s.draining and not proxies.anyIt(it.peerId == s.peer):
      s.draining = true
      client.evict(s)
      if s.callers == 0:
        client.abort(s, "DHT proxy removed")

proc close*(client: ProxyClient) {.async: (raises: []).} =
  if not client.isNil:
    let active = client.live
    for s in active:
      client.abort(s, "DHT proxy client closed")
    for s in active:
      await noCancel s.reader.cancelAndWait()

proc isReady(mixProto: MixProtocol): bool =
  ## Returns true if the MixProtocol is ready to be used for lookups.
  ## mixUnsetMultiAddr() is set as a placeholder in the setup and updated whenever
  ## the announce no longer carries a usable address.
  ## The Mix lookup cannot be performed until Autonat provides a Reachable
  ## address or a Relay address.
  let info = mixProto.localMixPubInfo.valueOr:
    return false
  info.multiAddr != mixUnsetMultiAddr()

proc exchange(
    client: ProxyClient, transport: PeerTransport, proxy: PeerRecord, cid: Cid
): Future[?!LookupResponse] {.async: (raises: [CancelledError]).} =
  var s = client.streams.getOrDefault(proxy.peerId)
  if s.isNil:
    let policy = clientPolicy()
    s = ProxyStream(
      peer: proxy.peerId,
      window: max(1, policy.initialWindow),
      stated: max(1, policy.initialWindow),
      slowStartLimit: MaxPendingPerStream,
      ready: newAsyncEvent(),
      writer: newAsyncLock(),
      slotAvailable: newAsyncEvent(),
    )
    client.streams[proxy.peerId] = s
    client.live.add(s)
    s.reader = client.connectAndRead(s, transport, proxy)
  if s.callers >= MaxPendingPerStream:
    return failure("DHT proxy client at capacity")
  inc s.callers
  var id: uint64
  try:
    await s.ready.wait()
    if s.failure.len > 0:
      return failure(s.failure)
    var attempt = 0
    while true:
      let call = Pending(ready: newAsyncEvent())
      event("wait", cid, attempt)
      await s.writer.acquire()
      try:
        # Only the writer can reserve a slot. The reader or a departing caller
        # signals when another request can proceed.
        while s.pending.len >= s.limit and s.failure.len == 0:
          s.slotAvailable.clear()
          await s.slotAvailable.wait()
        if s.failure.len > 0:
          return failure(s.failure)
        if s.highWater == high(uint64):
          s.draining = true
          client.evict(s)
          return failure("DHT proxy request IDs exhausted")
        id = s.highWater + 1
        let bytes = LookupRequest(
          requestId: id, queryType: QueryType.FindProviders, queryBytes: cid.data.buffer
        ).encode()
        if bytes.len > MaxLookupRequestBytes:
          return failure("DHT proxy request too large")
        s.highWater = id
        s.pending[id] = call
        call.limited = s.pending.len >= s.limit
        event("send", cid, id, s.pending.len, s.limit)
        try:
          await s.conn.writeLp(bytes)
        except CancelledError as exc:
          client.abort(s, "Interrupted DHT proxy write")
          raise exc
        except LPStreamError as exc:
          client.abort(s, "DHT proxy write failed: " & exc.msg)
          return failure(s.failure)
      finally:
        s.writer.release2()
      await call.ready.wait()
      if call.reply.requestId != id:
        return failure(s.failure)
      event("reply", cid, id, call.reply.code)
      if call.reply.code != LookupCode.ErrTooBusy or not clientPolicy().retryBusy:
        return success(call.reply)
      # The caller keeps its place among this stream's callers and its original
      # deadline while the rejected request waits to be sent again.
      inc attempt
      let pause = clientPolicy().backoff(attempt)
      event("backoff", cid, attempt, pause.microseconds)
      await sleepAsync(pause)
  finally:
    if s.pending.hasKey(id):
      s.pending.del(id)
      s.slotAvailable.fire()
    dec s.callers
    event("leave", cid, s.callers, s.pending.len)
    if s.callers == 0 and (s.draining or s.conn.isNil):
      client.abort(s, "DHT proxy stream released")
      await noCancel s.reader.cancelAndWait()

proc lookupProviders*(
    client: ProxyClient,
    mixProto: MixProtocol,
    transport: PeerTransport,
    proxy: PeerRecord,
    cid: Cid,
    timeout: Duration = DefaultLookupTimeout,
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  if transport.isNil or transport.kind != DownloadTransport.Mix:
    return failure("MixTransport is not enabled")
  if proxy.addresses.len == 0:
    return failure("Proxy has no addresses")
  if mixAddresses(proxy.peerId, proxy.addresses.mapIt(it.address)).len == 0:
    return failure("Proxy has no valid Mix address matching its peer identity")
  if mixProto.isNil or not mixProto.isReady:
    return failure("MixProtocol is not ready")

  try:
    # Include session establishment and stream opening in the lookup deadline.
    # wait cancels and awaits the exchange, including its stream cleanup.
    let lookup = (await client.exchange(transport, proxy, cid).wait(timeout)).valueOr:
      return failure(error)
    case lookup.code
    of LookupCode.Ok:
      var providers: seq[PeerRecord]
      for bytes in lookup.providers:
        let record = PeerRecord.decode(bytes).valueOr:
          warn "Failed to decode PeerRecord from response", err = $error
          continue
        providers.add(record)
      return success providers
    of LookupCode.NotFound:
      return success newSeq[PeerRecord]()
    of LookupCode.ErrDecodeFailed, LookupCode.ErrInvalidCid, LookupCode.ErrInternal,
        LookupCode.ErrResponseTooLarge, LookupCode.ErrTooBusy:
      return failure("Remote returned error: " & $lookup.code)
  except AsyncTimeoutError:
    return failure("Mix lookup timed out after " & $timeout)

proc lookupProviders*(
    mixProto: MixProtocol,
    transport: PeerTransport,
    proxy: PeerRecord,
    cid: Cid,
    timeout: Duration = DefaultLookupTimeout,
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  ## One-shot lookup for callers without a client lifecycle.
  let client = ProxyClient()
  try:
    return await client.lookupProviders(mixProto, transport, proxy, cid, timeout)
  finally:
    await client.close()
