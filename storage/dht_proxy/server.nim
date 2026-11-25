## Shared stream admission, framing and worker lifetime for both DHT backends.
{.push raises: [].}

import std/sequtils
import pkg/chronos
import pkg/libp2p
import ./protocol
import ./experiment

const
  MaxProxyStreams = 128
  IdleStreamTimeout = 90.seconds

type FindProviders = proc(req: LookupRequest): Future[LookupResponse] {.
  async: (raises: [CancelledError]), gcsafe
.}

const ClaimPeriod = 2.seconds

type StreamLoad = ref object
  ## A stream's recent demand: its lookups in flight now and the most it had
  ## in flight during the current and previous period.
  lookups, peakNow, peakPrev: int
  period: int64

proc note(load: StreamLoad, lookups: int, since: Moment) =
  let period = (Moment.now() - since).nanoseconds div ClaimPeriod.nanoseconds
  if period != load.period:
    load.peakPrev = if period == load.period + 1: load.peakNow else: 0
    load.peakNow = load.lookups
    load.period = period
  load.lookups = lookups
  load.peakNow = max(load.peakNow, lookups)

proc claim(load: StreamLoad, since: Moment): int =
  load.note(load.lookups, since)
  max(load.peakNow, load.peakPrev)

proc newProxyHandler*(maxInFlight: int, lookup: FindProviders): LPProtoHandler =
  var
    streams = 0
    inFlight = 0
    activeStreams = 0 # streams with a lookup in flight
    accepted = 0
    heldBytes = 0 # finished replies not yet written, across streams
    writingSlots = 0 # lookup slots kept by workers that are writing
    loads: seq[StreamLoad]
  let since = Moment.now()

  proc serve(conn: Connection, codec: string) {.async: (raises: [CancelledError]).} =
    if streams >= MaxProxyStreams:
      await noCancel conn.close()
      return
    inc streams
    inc accepted
    let
      sid = accepted
      writer = newAsyncLock()
      load = StreamLoad()
    var
      workers: seq[Future[void]]
      lookups = 0 # this stream's lookups in flight
      unwrittenBytes = 0 # this stream's finished replies not yet written
      unwritten = 0
    loads.add(load)
    event("accept", sid, streams)

    proc statedLimit(): Opt[uint64] =
      ## What this stream may have in flight: an equal share of the lookup
      ## slots, or whatever the other streams' recent demand and the headroom
      ## leave free.
      let policy = proxyPolicy()
      if not policy.advertise:
        return Opt.none(uint64)
      if policy.replyBudget > 0 and unwrittenBytes * 2 >= policy.replyBudget:
        return Opt.some(1'u64) # let a slow reader drain its replies first
      var
        active = 1
        others = 0
      for other in loads:
        if other != load:
          let claimed = other.claim(since)
          others += claimed
          if claimed > 0:
            inc active
      let share = max(1, maxInFlight div active)
      Opt.some(uint64(max(share, maxInFlight - policy.headroom - others)))

    proc write(
        response: LookupResponse
    ) {.async: (raises: [CancelledError, LPStreamError]).} =
      await writer.acquire()
      try:
        await conn.writeLp(response.encode())
      finally:
        writer.release2()

    proc run(req: LookupRequest) {.async: (raises: [CancelledError]).} =
      let policy = proxyPolicy()
      var
        looking = true
        slot = true
      inc inFlight
      inc lookups
      load.note(lookups, since)
      if lookups == 1:
        inc activeStreams
      event("slots", sid, inFlight, lookups, activeStreams)
      try:
        var response: LookupResponse
        try:
          response = await lookup(req).wait(DhtProxyExchangeTimeout)
        except AsyncTimeoutError:
          response = LookupResponse(code: LookupCode.ErrInternal)
        response.requestId = req.requestId
        looking = false
        dec lookups
        load.note(lookups, since)
        if lookups == 0:
          dec activeStreams
        var size = response.encode().len + 4
        if policy.replyBudget > 0:
          # The lookup slot returns to the proxy before the reply is written.
          # A stream may hold finished replies up to its budget. A reply that
          # does not fit becomes a busy reply for the client to retry.
          slot = false
          dec inFlight
          if unwrittenBytes > 0 and unwrittenBytes + size > policy.replyBudget:
            response =
              LookupResponse(requestId: req.requestId, code: LookupCode.ErrTooBusy)
            size = response.encode().len + 4
            event("shed", sid, req.requestId)
        else:
          inc writingSlots
        event("slots", sid, inFlight, lookups, activeStreams)
        response.limit = statedLimit()
        unwrittenBytes += size
        heldBytes += size
        inc unwritten
        event("held", sid, unwrittenBytes, unwritten, heldBytes, writingSlots)
        try:
          await write(response).wait(DhtProxyExchangeTimeout)
        finally:
          unwrittenBytes -= size
          heldBytes -= size
          dec unwritten
          if slot:
            dec writingSlots
          event("held", sid, unwrittenBytes, unwritten, heldBytes, writingSlots)
      except LPStreamError, AsyncTimeoutError:
        await noCancel conn.close()
      finally:
        if looking:
          dec lookups
          load.note(lookups, since)
          if lookups == 0:
            dec activeStreams
        if slot:
          dec inFlight
        event("slots", sid, inFlight, lookups, activeStreams)

    proc admits(): bool =
      let policy = proxyPolicy()
      if inFlight >= maxInFlight:
        return false
      if policy.perStream > 0 and workers.len >= policy.perStream:
        return false
      if policy.softShare:
        # A stream may exceed an equal share of the lookup slots only while
        # the reserved headroom stays free for streams below their share.
        let active = activeStreams + (if lookups == 0: 1 else: 0)
        if lookups >= max(1, maxInFlight div active) and
            inFlight >= maxInFlight - policy.headroom:
          return false
      if policy.replyBudget > 0 and
          (unwrittenBytes >= policy.replyBudget or unwritten >= policy.maxUnwritten):
        return false
      true

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
        event("request", sid, id, tail(req.queryBytes))
        if not admits():
          event("busy", sid, req.requestId, inFlight, lookups, unwrittenBytes)
          await write(
            LookupResponse(
              requestId: lastId, code: LookupCode.ErrTooBusy, limit: statedLimit()
            )
          )
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
      loads.keepItIf(it != load)
      dec streams
      event("stream-end", sid, streams, inFlight, heldBytes, writingSlots)

  serve
