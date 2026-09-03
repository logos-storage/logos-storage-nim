## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/cid
import pkg/libp2p/routing_record

import ../discovery
import ../logutils
import ./protocol

export protocol

logScope:
  topics = "storage dht-proxy server"

type DhtProxyProtocol* = ref object of LPProtocol
  discovery*: Discovery
  inFlight: int
  maxInFlight: int

proc handleFindProviders(
    self: DhtProxyProtocol, queryBytes: seq[byte]
): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
  let
    cid = Cid.init(queryBytes).valueOr:
      warn "Invalid CID in lookup request"
      return LookupResponse(code: LookupCode.ErrInvalidCid)
    providers = (await self.discovery.findDirect(cid)).valueOr:
      warn "Direct lookup failed", cid, err = error.msg
      return LookupResponse(code: LookupCode.ErrInternal)

  if providers.len == 0:
    return LookupResponse(code: LookupCode.NotFound)

  var encoded = newSeqOfCap[seq[byte]](providers.len)
  for record in providers:
    encoded.add(record.encode())

  let packed = packProviders(encoded, MaxLookupResponseBytes).valueOr:
    return LookupResponse(code: error)

  LookupResponse(code: LookupCode.Ok, providers: packed)

proc handleLookupRequest(
    self: DhtProxyProtocol, conn: Connection
) {.async: (raises: [CancelledError]).} =
  try:
    let reqBytes =
      try:
        await conn.readLp(MaxLookupRequestBytes).wait(DhtProxyRequestReadTimeout)
      except AsyncTimeoutError:
        debug "DHT proxy request read timed out"
        return

    let req = LookupRequest.decode(reqBytes).valueOr:
      warn "Failed to decode lookup request"
      await conn.writeLp(LookupResponse(code: LookupCode.ErrDecodeFailed).encode())
      return

    if self.inFlight >= self.maxInFlight:
      debug "DHT proxy at capacity, replying ErrTooBusy",
        inFlight = self.inFlight, max = self.maxInFlight
      await conn.writeLp(LookupResponse(code: LookupCode.ErrTooBusy).encode())
      return

    inc self.inFlight
    defer:
      dec self.inFlight

    let resp =
      case req.queryType
      of FindProviders:
        await self.handleFindProviders(req.queryBytes)

    await conn.writeLp(resp.encode())
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Stream error", err = exc.msg
  except CatchableError as exc:
    warn "Handler error", err = exc.msg

proc new*(
    T: type DhtProxyProtocol,
    discovery: Discovery,
    maxInFlight: int = DefaultMaxInFlightLookups,
): DhtProxyProtocol =
  let self = DhtProxyProtocol(discovery: discovery, maxInFlight: maxInFlight)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    try:
      await self.handleLookupRequest(conn)
    finally:
      await noCancel conn.close()

  self.handler = handler
  self.codec = DhtProxyCodec
  return self
