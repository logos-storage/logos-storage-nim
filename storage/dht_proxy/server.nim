## Shared stream admission, framing and worker lifetime for both DHT backends.
{.push raises: [].}

import std/sequtils
import pkg/chronos
import pkg/libp2p
import ./protocol

const
  MaxProxyStreams = 128
  IdleStreamTimeout = 90.seconds

type FindProviders = proc(req: LookupRequest): Future[LookupResponse] {.
  async: (raises: [CancelledError]), gcsafe
.}

proc newProxyHandler*(maxInFlight: int, lookup: FindProviders): LPProtoHandler =
  var
    streams = 0
    inFlight = 0

  proc serve(conn: Connection, codec: string) {.async: (raises: [CancelledError]).} =
    if streams >= MaxProxyStreams:
      await noCancel conn.close()
      return
    inc streams
    let writer = newAsyncLock()
    var workers: seq[Future[void]]

    proc write(
        response: LookupResponse
    ) {.async: (raises: [CancelledError, LPStreamError]).} =
      await writer.acquire()
      try:
        await conn.writeLp(response.encode())
      finally:
        writer.release2()

    proc run(req: LookupRequest) {.async: (raises: [CancelledError]).} =
      inc inFlight
      try:
        var response: LookupResponse
        try:
          response = await lookup(req).wait(DhtProxyExchangeTimeout)
        except AsyncTimeoutError:
          response = LookupResponse(code: LookupCode.ErrInternal)
        response.requestId = req.requestId
        await write(response).wait(DhtProxyExchangeTimeout)
      except LPStreamError, AsyncTimeoutError:
        await noCancel conn.close()
      finally:
        dec inFlight

    var lastId: uint64
    try:
      while not conn.closed:
        var first: byte
        let read = conn.readExactly(addr first, 1)
        try:
          # Idle retention begins when the last queued write finishes.
          workers.keepItIf(not it.finished)
          while workers.len > 0 and not read.finished:
            discard await race(FutureBase(read), workers.mapIt(FutureBase(it)))
            workers.keepItIf(not it.finished)
          await read.wait(
            if lastId == 0: DhtProxyRequestReadTimeout else: IdleStreamTimeout
          )
        finally:
          await noCancel read.cancelAndWait()
        let payload = await readFrameBody(conn, first, MaxLookupRequestBytes).wait(
          DhtProxyRequestReadTimeout
        )
        let id = requestIdOf(payload)
        if id <= lastId:
          break
        lastId = id
        let req = LookupRequest.decode(payload).valueOr:
          await write(
            LookupResponse(requestId: lastId, code: LookupCode.ErrDecodeFailed)
          )
            .wait(DhtProxyExchangeTimeout)
          continue
        workers.keepItIf(not it.finished)
        # A worker owns its slot through the write. At most four full responses
        # and one inline busy reply can queue on this stream.
        if workers.len >= MaxLookupsPerStream or inFlight >= maxInFlight:
          await write(LookupResponse(requestId: lastId, code: LookupCode.ErrTooBusy))
            .wait(DhtProxyExchangeTimeout)
        else:
          workers.add(run(req))
    except LPStreamError, AsyncTimeoutError:
      discard
    finally:
      for worker in workers:
        worker.cancelSoon()
      for worker in workers:
        await noCancel worker.cancelAndWait()
      await noCancel conn.close()
      dec streams

  serve
