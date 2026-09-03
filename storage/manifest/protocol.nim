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
import pkg/questionable
import pkg/questionable/results
import pkg/stew/endians2

import ../blocktype as bt
import ../stores/blockstore
import ../discovery
import ../logutils
import ../errors
import ./manifest
import ./coders

export manifest, coders

logScope:
  topics = "storage manifestprotocol"

const
  ManifestProtocolCodec* = "/storage/manifest/1.0.0"
  ManifestMaxCidSize = 512
  ManifestMaxDataSize = 65536 # 64KB

  DefaultManifestRetries* = 10
  DefaultManifestRetryDelay* = 3.seconds
  DefaultManifestFetchTimeout* = 30.seconds

type
  ManifestProtocol* = ref object of LPProtocol
    switch*: Switch
    localStore*: BlockStore
    discovery*: Discovery
    retries*: int
    retryDelay*: Duration
    fetchTimeout*: Duration

  ManifestFetchStatus* = enum
    Found = 0
    NotFound = 1

proc writeManifestResponse(
    conn: Connection, status: ManifestFetchStatus, data: seq[byte] = @[]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let contentLen = 1 + data.len
  var buf = newSeqUninit[byte](4 + contentLen)
  let contentLenLE = contentLen.uint32.toLE
  copyMem(addr buf[0], unsafeAddr contentLenLE, 4)
  buf[4] = status.uint8
  if data.len > 0:
    copyMem(addr buf[5], unsafeAddr data[0], data.len)
  await conn.write(buf)

proc readManifestResponse(
    conn: Connection
): Future[?!(ManifestFetchStatus, seq[byte])] {.
    async: (raises: [CancelledError, LPStreamError])
.} =
  var lenBuf: array[4, byte]
  await conn.readExactly(addr lenBuf[0], 4)
  let contentLen = uint32.fromBytes(lenBuf, littleEndian).int

  if contentLen < 1:
    return failure("Manifest response too short: " & $contentLen)

  if contentLen > 1 + ManifestMaxDataSize:
    return failure("Manifest response too large: " & $contentLen)

  var content = newSeq[byte](contentLen)
  await conn.readExactly(addr content[0], contentLen)

  let statusByte = content[0]
  if statusByte > ManifestFetchStatus.high.uint8:
    return failure("Invalid manifest response status: " & $statusByte)

  let
    status = ManifestFetchStatus(statusByte)
    data =
      if contentLen > 1:
        content[1 ..< contentLen]
      else:
        newSeq[byte]()
  return success (status, data)

proc handleManifestRequest(
    self: ManifestProtocol, conn: Connection
) {.async: (raises: [CancelledError]).} =
  try:
    var cidLenBuf: array[2, byte]
    await conn.readExactly(addr cidLenBuf[0], 2)
    let cidLen = uint16.fromBytes(cidLenBuf, littleEndian).int

    if cidLen == 0 or cidLen > ManifestMaxCidSize:
      warn "Invalid CID length in manifest request", cidLen
      await writeManifestResponse(conn, ManifestFetchStatus.NotFound)
      return

    var cidBuf = newSeq[byte](cidLen)
    await conn.readExactly(addr cidBuf[0], cidLen)

    let cid = Cid.init(cidBuf).valueOr:
      warn "Invalid CID in manifest request"
      await writeManifestResponse(conn, ManifestFetchStatus.NotFound)
      return

    without blk =? await self.localStore.getBlock(cid), err:
      trace "Manifest not found locally", cid, err = err.msg
      await writeManifestResponse(conn, ManifestFetchStatus.NotFound)
      return

    await writeManifestResponse(conn, ManifestFetchStatus.Found, blk.data[])
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Error handling manifest request", exc = exc.msg

proc fetchManifestFromPeer(
    self: ManifestProtocol, peer: PeerRecord, cid: Cid
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  var conn: Connection
  try:
    conn = await self.switch.dial(
      peer.peerId, peer.addresses.mapIt(it.address), ManifestProtocolCodec
    )

    let cidBytes = cid.data.buffer
    var reqBuf = newSeqUninit[byte](2 + cidBytes.len)
    let cidLenLE = cidBytes.len.uint16.toLE
    copyMem(addr reqBuf[0], unsafeAddr cidLenLE, 2)
    if cidBytes.len > 0:
      copyMem(addr reqBuf[2], unsafeAddr cidBytes[0], cidBytes.len)
    await conn.write(reqBuf)

    without (status, data) =? await readManifestResponse(conn), err:
      return failure(err)

    if status == ManifestFetchStatus.NotFound:
      return failure(
        newException(BlockNotFoundError, "Manifest not found on peer " & $peer.peerId)
      )

    without blk =? bt.Block.new(cid, data, verify = true), err:
      return failure("Manifest CID verification failed: " & err.msg)

    return success blk
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error fetching manifest from peer " & $peer.peerId & ": " & exc.msg)
  finally:
    if not conn.isNil:
      await conn.close()

proc fetchManifest*(
    self: ManifestProtocol, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Fetching manifest", cid

  without localBlk =? await self.localStore.getBlock(cid), err:
    if not (err of BlockNotFoundError):
      return failure err

    trace "Manifest not in local store, starting discovery loop", cid

    var lastErr = err
    for attempt in 0 ..< self.retries:
      trace "Manifest fetch attempt", cid, attempt, maxRetries = self.retries

      let providers = await self.discovery.find(cid)

      if providers.len > 0:
        for provider in providers:
          let fetchFut = self.fetchManifestFromPeer(provider, cid)

          var blkResult: ?!bt.Block
          if (await fetchFut.withTimeout(self.fetchTimeout)):
            blkResult = await fetchFut
          else:
            trace "Manifest fetch from peer timed out", cid, peer = provider.peerId
            continue

          without blk =? blkResult, fetchErr:
            trace "Failed to fetch manifest from peer",
              cid, peer = provider.peerId, err = fetchErr.msg
            lastErr = fetchErr
            continue

          if putErr =? (await self.localStore.putBlock(blk)).errorOption:
            warn "Failed to store fetched manifest locally", cid, err = putErr.msg

          without manifest =? Manifest.decode(blk), err:
            return failure("Unable to decode manifest: " & err.msg)

          return success manifest
      else:
        trace "No providers found for manifest, will retry", cid, attempt

      if attempt < self.retries - 1:
        await sleepAsync(self.retryDelay)

    return failure(
      newException(
        BlockNotFoundError,
        "Failed to fetch manifest " & $cid & " after " & $self.retries & " attempts: " &
          lastErr.msg,
      )
    )

  without manifest =? Manifest.decode(localBlk), err:
    return failure("Unable to decode manifest: " & err.msg)

  return success manifest

proc new*(
    T: type ManifestProtocol,
    switch: Switch,
    localStore: BlockStore,
    discovery: Discovery,
    retries: int = DefaultManifestRetries,
    retryDelay: Duration = DefaultManifestRetryDelay,
    fetchTimeout: Duration = DefaultManifestFetchTimeout,
): ManifestProtocol =
  let self = ManifestProtocol(
    switch: switch,
    localStore: localStore,
    discovery: discovery,
    retries: retries,
    retryDelay: retryDelay,
    fetchTimeout: fetchTimeout,
  )

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    await self.handleManifestRequest(conn)

  self.handler = handler
  self.codec = ManifestProtocolCodec
  return self
