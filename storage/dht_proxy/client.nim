## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sequtils, tables]

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

const DefaultLookupTimeout* = 90.seconds

logScope:
  topics = "storage dht-proxy client"

type
  Pending = ref object
    ready: AsyncEvent
    reply: LookupResponse

  ProxyStream = ref object
    peer: PeerId
    ready: AsyncEvent
    writer: AsyncLock
    conn: Connection
    reader: Future[void]
    pending: Table[uint64, Pending]
    highWater: uint64
    callers: int
    draining: bool
    failure: string

  ProxyClient* = ref object
    streams: Table[PeerId, ProxyStream]
    live: seq[ProxyStream]

const MaxPendingPerStream = 32

proc evict(client: ProxyClient, s: ProxyStream) =
  if client.streams.getOrDefault(s.peer) == s:
    client.streams.del(s.peer)

proc failStream(client: ProxyClient, s: ProxyStream, reason: string) =
  if s.failure.len == 0:
    s.failure = reason
    client.evict(s)
    s.ready.fire()
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
    s = ProxyStream(peer: proxy.peerId, ready: newAsyncEvent(), writer: newAsyncLock())
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
    let call = Pending(ready: newAsyncEvent())
    await s.writer.acquire()
    try:
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
    if call.reply.requestId == id:
      return success(call.reply)
    return failure(s.failure)
  finally:
    s.pending.del(id)
    dec s.callers
    if s.callers == 0 and (s.draining or s.conn.isNil):
      client.abort(s, "DHT proxy stream released")

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
