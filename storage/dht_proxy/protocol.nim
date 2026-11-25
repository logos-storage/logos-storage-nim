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
import pkg/libp2p/[stream/connection, varint]
import pkg/protobuf_serialization
import pkg/protobuf_serialization/std/enums
import pkg/protobuf_serialization/pkg/results

import ../logutils
import ../utils/protobuf/serializer

const DhtProxyCodec* = "/storage/dht-proxy/2.0.0"

const DefaultMaxInFlightLookups* = 100
const DhtProxyRequestReadTimeout* = 5.seconds

# Stream limits are independent of Sphinx packet capacity.
const MaxLookupRequestBytes* = 4 * 1024
const MaxLookupResponseBytes* = 256 * 1024
const DhtProxyExchangeTimeout* = 90.seconds

type
  QueryType* {.pure.} = enum
    FindProviders = 0

  LookupCode* {.pure.} = enum
    Ok = 0
    NotFound = 1
    ErrDecodeFailed = 100
    ErrInvalidCid = 101
    ErrInternal = 200
    ErrResponseTooLarge = 201
    ErrTooBusy = 202

  # Decode correlation separately so a malformed query with one ID can receive
  # ErrDecodeFailed. A repeated field lets us reject conflicting IDs.
  RequestEnvelope {.proto2.} = object
    requestIds {.fieldNumber: 3, pint.}: seq[uint64]

  LookupRequest* {.proto2.} = object
    requestId* {.fieldNumber: 3, required, pint.}: uint64
    queryType* {.fieldNumber: 1, required, ext.}: QueryType
    queryBytes* {.fieldNumber: 2, required.}: seq[byte]

  LookupResponse* {.proto2.} = object
    requestId* {.fieldNumber: 3, required, pint.}: uint64
    code* {.fieldNumber: 1, required, ext.}: LookupCode
    providers* {.fieldNumber: 2.}: seq[seq[byte]]

Protobuf.serializerForResult([LookupRequest, LookupResponse, RequestEnvelope])

proc requestIdOf*(bytes: seq[byte]): uint64 =
  let envelope = RequestEnvelope.decode(bytes).valueOr:
    return 0
  if envelope.requestIds.len == 1:
    return envelope.requestIds[0]

proc readFrameBody*(
    conn: Connection, first: byte, maxSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  var prefix: array[10, byte]
  prefix[0] = first
  for i in 0 ..< prefix.len:
    if i > 0:
      await conn.readExactly(addr prefix[i], 1)
    var
      length: uint64
      consumed: int
    let decoded = PB.getUVarint(prefix.toOpenArray(0, i), consumed, length)
    if decoded.isOk:
      if length == 0 or length > maxSize.uint64:
        raise (ref MaxSizeError)(msg: "Invalid DHT proxy frame length")
      var payload = newSeqUninit[byte](int(length))
      await conn.readExactly(addr payload[0], payload.len)
      return payload
    if decoded.error != VarintError.Incomplete:
      break
  raise (ref InvalidVarintError)(msg: "Invalid DHT proxy length prefix")

proc packProviders*(
    providers: seq[seq[byte]], budget_bytes: int, requestId: uint64
): Result[seq[seq[byte]], LookupCode] =
  if providers.len == 0:
    error "packProviders called with no providers"
    return err(LookupCode.ErrInternal)

  let single = LookupResponse(
    requestId: requestId, code: LookupCode.Ok, providers: providers[0 ..< 1]
  )
  if single.encode().len > budget_bytes:
    return err(LookupCode.ErrResponseTooLarge)

  var
    lo = 1
    hi = providers.len
  while lo < hi:
    let
      mid = (lo + hi + 1) div 2
      test = LookupResponse(
        requestId: requestId, code: LookupCode.Ok, providers: providers[0 ..< mid]
      )
    if test.encode().len <= budget_bytes:
      lo = mid
    else:
      hi = mid - 1

  ok(providers[0 ..< lo])
