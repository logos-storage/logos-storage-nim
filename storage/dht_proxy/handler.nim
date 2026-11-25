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
import ./server

export protocol

logScope:
  topics = "storage dht-proxy server"

type DhtProxyProtocol* = ref object of LPProtocol
  discovery*: Discovery

proc handleFindProviders(
    self: DhtProxyProtocol, req: LookupRequest
): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
  let
    cid = Cid.init(req.queryBytes).valueOr:
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

  let packed = packProviders(encoded, MaxLookupResponseBytes, req.requestId).valueOr:
    return LookupResponse(code: error)

  LookupResponse(code: LookupCode.Ok, providers: packed)

proc new*(
    T: type DhtProxyProtocol,
    discovery: Discovery,
    maxInFlight: int = DefaultMaxInFlightLookups,
): DhtProxyProtocol =
  let self = DhtProxyProtocol(discovery: discovery)
  self.handler = newProxyHandler(
    maxInFlight,
    proc(
        req: LookupRequest
    ): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
      await self.handleFindProviders(req)
    ,
  )
  self.codec = DhtProxyCodec
  return self
