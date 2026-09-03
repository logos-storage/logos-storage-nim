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
import std/strutils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/cid
import pkg/libp2p/routing_record
import pkg/libp2p_mix

import ../errors
import ../logutils
import ../utils/mixidentity
import ./protocol

const DefaultLookupTimeout* = 30.seconds

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
  except CatchableError as exc:
    return failure("Client error: " & exc.msg)

proc isReady(mixProto: MixProtocol): bool =
  ## Returns true if the MixProtocol is ready to be used for lookups.
  ## mixUnsetMultiAddr() is set as a placeholder in the setup and updated whenever
  ## the announce no longer carries a usable address.
  ## The Mix lookup cannot be performed until Autonat provides a Reachable
  ## address or a Relay address.
  return $mixProto.localMixPubInfo.multiAddr != $mixUnsetMultiAddr()

proc lookupProviders*(
    mixProto: MixProtocol, proxy: PeerRecord, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  if proxy.addresses.len == 0:
    return failure("Proxy has no addresses")

  let mixAddr = pickMixCompatibleMultiAddr(proxy.addresses.mapIt(it.address)).valueOr:
    let dump = proxy.addresses.mapIt($it.address).join(",")
    return failure(
      "No Mix-compatible address on proxy " & $proxy.peerId & " (advertised: [" & dump &
        "])"
    )

  if not mixProto.isReady:
    return failure(
      "MixProtocol is not ready, multiAddr=" & $mixProto.localMixPubInfo.multiAddr
    )

  let
    destination = MixDestination.init(proxy.peerId, mixAddr)
    request =
      LookupRequest(queryType: QueryType.FindProviders, queryBytes: cid.data.buffer)

  var conn: Connection
  try:
    conn = mixProto.toConnection(
      destination,
      DhtProxyCodec,
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(1'u8)),
    ).valueOr:
      return failure("Failed to obtain Mix connection: " & error)

    let lookupFut = requestLookup(conn, request)
    if not (await lookupFut.withTimeout(DefaultLookupTimeout)):
      lookupFut.cancelSoon()
      return failure("Mix lookup timed out after " & $DefaultLookupTimeout)

    let lookupRes = lookupFut.read()
    if lookupRes.isErr:
      return failure(lookupRes.error)
    let lookup = lookupRes.get()

    case lookup.code
    of LookupCode.Ok:
      return success lookup.providers
    of LookupCode.NotFound:
      return success newSeq[PeerRecord]()
    of LookupCode.ErrDecodeFailed, LookupCode.ErrInvalidCid, LookupCode.ErrInternal,
        LookupCode.ErrResponseTooLarge, LookupCode.ErrTooBusy:
      return failure("Remote returned error: " & $lookup.code)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Mix lookup failed: " & exc.msg)
  finally:
    if not conn.isNil:
      await noCancel conn.close()
