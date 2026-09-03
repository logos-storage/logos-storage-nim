## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options
import std/sequtils
import std/strformat
import times

import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/chronos

import pkg/libp2p/[switch, multicodec, multihash, peerinfo]
import pkg/libp2p/stream/bufferstream

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./chunker
import ./clock
import ./blocktype as bt
import ./manifest
import ./merkletree
import ./stores
import ./blockexchange
import ./streams
import ./discovery
import ./utils
import ./errors
import ./logutils
import ./utils/safeasynciter
import ./utils/trackedfutures

export logutils

logScope:
  topics = "storage node"

type
  StorageNode* = object
    switch: Switch
    networkId: PeerId
    networkStore: NetworkStore
    engine: BlockExcEngine
    discovery: Discovery
    manifestProto: ManifestProtocol
    clock*: Clock
    taskPool: Taskpool
    trackedFutures: TrackedFutures
    addrObserver: PeerInfoObserver

  StorageNodeRef* = ref StorageNode

  OnManifest* = proc(cid: Cid, manifest: Manifest): void {.gcsafe, raises: [].}
  OnBlockStoredProc = proc(chunk: seq[byte]): void {.gcsafe, raises: [].}

func switch*(self: StorageNodeRef): Switch =
  return self.switch

func blockStore*(self: StorageNodeRef): BlockStore =
  return self.networkStore

func engine*(self: StorageNodeRef): BlockExcEngine =
  return self.engine

func discovery*(self: StorageNodeRef): Discovery =
  return self.discovery

proc storeManifest*(
    self: StorageNodeRef, manifest: Manifest
): Future[?!bt.Block] {.async.} =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await self.networkStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc fetchManifest*(
    self: StorageNodeRef, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest
  return await self.manifestProto.fetchManifest(cid)

proc findPeer*(self: StorageNodeRef, peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given StorageNode
  ##
  return await self.discovery.findPeer(peerId)

proc connect*(
    self: StorageNodeRef, peerId: PeerId, addrs: seq[MultiAddress]
): Future[void] =
  self.switch.connect(peerId, addrs)

proc updateExpiry*(
    self: StorageNodeRef, manifestCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without manifest =? await self.fetchManifest(manifestCid), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  try:
    let ensuringFutures = Iter[int].new(0 ..< manifest.blocksCount).mapIt(
        self.networkStore.localStore.ensureExpiry(manifest.treeCid, it, expiry)
      )

    let res = await allDone[?!void](ensuringFutures)
    if res.failed.len > 0:
      trace "Some blocks failed to update expiry", len = res.failed.len
      return failure("Some blocks failed to update expiry (" & $res.failed.len & " )")
    if res.cancelled.len > 0:
      trace "Block expiry update was cancelled in some blocks", len = res.cancelled.len
      raise
        newException(CancelledError, "Block expiry update was cancelled in some blocks")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()

proc fetchDatasetAsync*(
    self: StorageNodeRef,
    md: ManifestDescriptor,
    fetchLocal = true,
    selectionPolicy: SelectionPolicy = spSequential,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let download = ?self.engine.startTreeDownloadOpaque(
    md, selectionPolicy = selectionPolicy, fetchLocal = fetchLocal
  )
  try:
    trace "Starting tree download",
      treeCid = md.manifest.treeCid, totalBlocks = md.manifest.blocksCount
    return await download.waitForComplete()
  finally:
    self.engine.releaseDownload(download)

proc cancelBackgroundDownload*(
    self: StorageNodeRef, downloadId: uint64, cid: Cid
): bool =
  self.engine.cancelBackgroundDownload(downloadId, cid)

proc getDownloadProgress*(
    self: StorageNodeRef, downloadId: uint64, cid: Cid
): Option[DownloadProgress] =
  self.engine.getDownloadProgress(downloadId, cid)

proc startBackgroundDownload*(
    self: StorageNodeRef,
    md: ManifestDescriptor,
    selectionPolicy: SelectionPolicy = spSequential,
): Future[?!uint64] {.async: (raises: [CancelledError]).} =
  let
    treeCid = md.manifest.treeCid
    existing = self.engine.downloadManager.getBackgroundDownload(treeCid)

  if existing.isSome:
    return success(existing.get().id)

  let
    download = ?self.engine.startTreeDownloadOpaque(
      md, selectionPolicy = selectionPolicy, isBackground = true
    )
    downloadId = download.downloadId

  proc waitForCompleteTask(): Future[void] {.async: (raises: []).} =
    try:
      discard await download.waitForComplete()
    except CancelledError:
      trace "Background download cancelled", treeCid = treeCid, downloadId
    finally:
      self.engine.releaseDownload(download)

  self.trackedFutures.track(waitForCompleteTask())
  return success(downloadId)

proc fetchDatasetAsyncTask*(self: StorageNodeRef, md: ManifestDescriptor) =
  ## Kept for C library compatibility.
  proc fetchTask(): Future[void] {.async: (raises: []).} =
    try:
      discard await self.startBackgroundDownload(md, selectionPolicy = spRandomWindow)
    except CancelledError:
      trace "Background dataset fetch cancelled", treeCid = md.manifest.treeCid

  self.trackedFutures.track(fetchTask())

proc streamSingleBlock(
    self: StorageNodeRef, cid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of a single block.
  ##
  trace "Streaming single block", cid = cid

  let stream = BufferStream.new()

  without blk =? (await self.networkStore.localStore.getBlock(cid)), err:
    return failure(err)

  proc streamOneBlock(): Future[void] {.async: (raises: []).} =
    try:
      defer:
        await stream.pushEof()
      await stream.pushData(blk.data[])
    except CancelledError as exc:
      trace "Streaming block cancelled", cid, exc = exc.msg
    except LPStreamError as exc:
      trace "Unable to send block", cid, exc = exc.msg

  self.trackedFutures.track(streamOneBlock())
  LPStream(stream).success

proc streamEntireDataset(
    self: StorageNodeRef, md: ManifestDescriptor, fetchLocal: bool = false
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of the entire dataset described by the manifest.
  ##
  trace "Retrieving blocks from manifest", manifestCid = md.manifestCid

  let
    treeCid = md.manifest.treeCid
    download = ?self.engine.startTreeDownloadOpaque(md, fetchLocal = fetchLocal)
    stream = LPStream(StoreStream.new(self.networkStore, md.manifest, pad = false))

  var jobs: seq[Future[void]]

  proc fetchTask(): Future[void] {.async: (raises: []).} =
    try:
      trace "Starting tree download",
        treeCid = treeCid, totalBlocks = md.manifest.blocksCount
      if err =? (await download.waitForComplete()).errorOption:
        error "Dataset fetch failed during streaming",
          manifestCid = md.manifestCid, err = err.msg
        await stream.close()
    except CancelledError:
      trace "Dataset fetch cancelled during streaming", manifestCid = md.manifestCid
    finally:
      self.engine.releaseDownload(download)

  jobs.add(fetchTask())

  # Monitor stream completion and cancel background jobs when done
  proc monitorStream() {.async: (raises: []).} =
    try:
      await stream.join()
    except CancelledError as exc:
      warn "Stream cancelled", exc = exc.msg
    finally:
      await noCancel allFutures(jobs.mapIt(it.cancelAndWait))

  self.trackedFutures.track(monitorStream())

  # Retrieve all blocks of the dataset sequentially from the local store or network
  trace "Creating store stream for manifest", manifestCid = md.manifestCid

  stream.success

proc retrieve*(
    self: StorageNodeRef, cid: Cid, local: bool = true
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if local and not await (cid in self.networkStore):
    return failure((ref BlockNotFoundError)(msg: "Block not found in local store"))

  without manifest =? (await self.fetchManifest(cid)), err:
    if err of AsyncTimeoutError:
      return failure(err)

    return await self.streamSingleBlock(cid)

  await self.streamEntireDataset(
    ManifestDescriptor(manifest: manifest, manifestCid: cid)
  )

proc deleteSingleBlock(self: StorageNodeRef, cid: Cid): Future[?!void] {.async.} =
  if err =? (await self.networkStore.delBlock(cid)).errorOption:
    error "Error deleting block", cid, err = err.msg
    return failure(err)

  trace "Deleted block", cid
  return success()

proc deleteEntireDataset(self: StorageNodeRef, cid: Cid): Future[?!void] {.async.} =
  # Deletion is a strictly local operation
  var store = self.networkStore.localStore

  if not (await cid in store):
    # As per the contract for delete*, an absent dataset is not an error.
    return success()

  without manifestBlock =? await store.getBlock(cid), err:
    return failure(err)

  without manifest =? Manifest.decode(manifestBlock), err:
    return failure(err)

  let runtimeQuota = initDuration(milliseconds = 100)
  var lastIdle = getTime()
  for i in 0 ..< manifest.blocksCount:
    if (getTime() - lastIdle) >= runtimeQuota:
      await idleAsync()
      lastIdle = getTime()

    if err =? (await store.delBlock(manifest.treeCid, i)).errorOption:
      # The contract for delBlock is fuzzy, but we assume that if the block is
      # simply missing we won't get an error. This is a best effort operation and
      # can simply be retried.
      error "Failed to delete block within dataset", index = i, err = err.msg
      return failure(err)

  if err =? (await store.delBlock(cid)).errorOption:
    error "Error deleting manifest block", err = err.msg

  success()

proc delete*(
    self: StorageNodeRef, cid: Cid
): Future[?!void] {.async: (raises: [CatchableError]).} =
  ## Deletes a whole dataset, if Cid is a Manifest Cid, or a single block, if Cid a block Cid,
  ## from the underlying block store. This is a strictly local operation.
  ##
  ## Missing blocks in dataset deletes are ignored.
  ##

  without isManifest =? cid.isManifest, err:
    trace "Bad content type for CID:", cid = cid, err = err.msg
    return failure(err)

  if not isManifest:
    return await self.deleteSingleBlock(cid)

  await self.deleteEntireDataset(cid)

proc store*(
    self: StorageNodeRef,
    stream: LPStream,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
    blockSize = DefaultBlockSize,
    onBlockStored: OnBlockStoredProc = nil,
): Future[?!Cid] {.async.} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  info "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var cids: seq[Cid]

  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? bt.Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)

      if err =? (await self.networkStore.putBlock(blk)).errorOption:
        error "Unable to store block", cid = blk.cid, err = err.msg
        return failure(&"Unable to store block {blk.cid}")

      if not onBlockStored.isNil:
        onBlockStored(chunk)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  without tree =? (await StorageMerkleTree.init(self.taskPool, cids)), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    if err =?
        (await self.networkStore.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    filename = filename,
    mimetype = mimetype,
  )

  without manifestBlk =? await self.storeManifest(manifest), err:
    error "Unable to store manifest"
    return failure(err)

  info "Stored data",
    manifestCid = manifestBlk.cid,
    treeCid = treeCid,
    blocks = manifest.blocksCount,
    datasetSize = manifest.datasetSize,
    filename = manifest.filename,
    mimetype = manifest.mimetype

  return manifestBlk.cid.success

proc iterateManifests*(self: StorageNodeRef, onManifest: OnManifest) {.async.} =
  without cidsIter =? await self.networkStore.listBlocks(BlockType.Manifest):
    warn "Failed to listBlocks"
    return

  for c in cidsIter:
    if cid =? await c:
      without blk =? await self.networkStore.getBlock(cid):
        warn "Failed to get manifest block by cid", cid
        return

      without manifest =? Manifest.decode(blk):
        warn "Failed to decode manifest", cid
        return

      onManifest(cid, manifest)

proc togglePrivateQueries*(self: StorageNodeRef, enable: bool): ?!bool =
  self.discovery.togglePrivateQueries(enable)

proc onExpiryUpdate(
    self: StorageNodeRef, rootCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return await self.updateExpiry(rootCid, expiry)

proc start*(self: StorageNodeRef) {.async.} =
  self.addrObserver = proc(p: PeerInfo) {.gcsafe, raises: [].} =
    self.discovery.updateLocalMultiAddr()
    self.engine.advertiser.onAddrChange()

    let spr = self.discovery.getSpr()
    if spr.isErr:
      warn "Unable to build the signed peer record", err = spr.error.msg
      return

    info "Signed peer record updated", addrs = p.addrs, spr = spr.get()

  self.switch.peerInfo.addObserver(self.addrObserver)

  if not self.engine.isNil:
    await self.engine.start()

  if not self.discovery.isNil:
    self.discovery.updateLocalMultiAddr()

  if not self.clock.isNil:
    await self.clock.start()

  self.networkId = self.switch.peerInfo.peerId
  notice "Started Storage node", id = self.networkId, addrs = self.switch.peerInfo.addrs

proc stop*(self: StorageNodeRef) {.async.} =
  trace "Stopping node"

  self.switch.peerInfo.removeObserver(self.addrObserver)
  self.addrObserver = nil

  await self.trackedFutures.cancelTracked()

  if not self.engine.isNil:
    await self.engine.stop()

  if not self.clock.isNil:
    await self.clock.stop()

proc close*(self: StorageNodeRef) {.async.} =
  if not self.networkStore.isNil:
    await self.networkStore.close

proc new*(
    T: type StorageNodeRef,
    switch: Switch,
    networkStore: NetworkStore,
    engine: BlockExcEngine,
    discovery: Discovery,
    manifestProto: ManifestProtocol,
    taskpool: Taskpool,
): StorageNodeRef =
  ## Create new instance of a Storage self, call `start` to run it
  ##

  StorageNodeRef(
    switch: switch,
    networkStore: networkStore,
    engine: engine,
    discovery: discovery,
    manifestProto: manifestProto,
    taskPool: taskpool,
    trackedFutures: TrackedFutures(),
  )

proc hasLocalBlock*(
    self: StorageNodeRef, cid: Cid
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Returns true if the given Cid is present in the local store

  return await (cid in self.networkStore.localStore)
