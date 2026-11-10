## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils

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

type LookupResult = object
  code: LookupCode
  providers: seq[PeerRecord]

proc requestLookup(
    conn: Connection, request: LookupRequest
): Future[?!LookupResult] {.async: (raises: [CancelledError]).} =
  try:
    let encoded = request.encode()
    if encoded.len > MaxLookupRequestBytes:
      return failure(
        "Request exceeds " & $MaxLookupRequestBytes & " bytes (got " & $encoded.len & ")"
      )
    await conn.writeLp(encoded)

    let
      respBytes = await conn.readLp(MaxLookupResponseBytes)
      resp = LookupResponse.decode(respBytes).valueOr:
        return
          failure("Failed to decode response (bytes=" & $respBytes.len & "): " & $error)

    var providers = newSeqOfCap[PeerRecord](resp.providers.len)
    for recordBytes in resp.providers:
      let record = PeerRecord.decode(recordBytes)
      if record.isOk:
        providers.add(record.get)
      else:
        warn "Failed to decode PeerRecord from response", err = $record.error
    return success LookupResult(code: resp.code, providers: providers)
  except LPStreamError as exc:
    return failure("Stream error: " & exc.msg)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Client error: " & exc.msg)

proc isReady(mixProto: MixProtocol): bool =
  ## Returns true if the MixProtocol is ready to be used for lookups.
  ## mixUnsetMultiAddr() is set as a placeholder in the setup and updated whenever
  ## the announce no longer carries a usable address.
  ## The Mix lookup cannot be performed until Autonat provides a Reachable
  ## address or a Relay address.
  return $mixProto.localMixPubInfo.multiAddr != $mixUnsetMultiAddr()

proc exchange(
    transport: PeerTransport, proxy: PeerRecord, request: LookupRequest
): Future[?!LookupResult] {.async: (raises: [CancelledError]).} =
  var conn: Connection
  try:
    conn = (await transport.dial(proxy, DhtProxyCodec)).valueOr:
      return failure("Failed to open MixTransport stream: " & error.msg)
    return await requestLookup(conn, request)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Mix lookup failed: " & exc.msg)
  finally:
    if not conn.isNil:
      await noCancel conn.close()

proc lookupProviders*(
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

  let request =
    LookupRequest(queryType: QueryType.FindProviders, queryBytes: cid.data.buffer)
  try:
    # Include session establishment and stream opening in the lookup deadline.
    # wait cancels and awaits the exchange, including its stream cleanup.
    let lookup = (await exchange(transport, proxy, request).wait(timeout)).valueOr:
      return failure(error)
    case lookup.code
    of LookupCode.Ok:
      return success lookup.providers
    of LookupCode.NotFound:
      return success newSeq[PeerRecord]()
    of LookupCode.ErrDecodeFailed, LookupCode.ErrInvalidCid, LookupCode.ErrInternal,
        LookupCode.ErrResponseTooLarge, LookupCode.ErrTooBusy:
      return failure("Remote returned error: " & $lookup.code)
  except AsyncTimeoutError:
    return failure("Mix lookup timed out after " & $timeout)
