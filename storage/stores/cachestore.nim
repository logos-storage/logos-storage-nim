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
import std/sets

import pkg/chronos
import pkg/libp2p
import pkg/lrucache
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../units
import ../chunker
import ../errors
import ../logutils
import ../manifest
import ../merkletree
import ../utils
import ../clock

export blockstore

logScope:
  topics = "storage cachestore"

type
  CacheStore* = ref object of BlockStore
    currentSize*: NBytes
    size*: NBytes
    cache: LruCache[Cid, Block]
    cidAndProofCache: LruCache[(Cid, Natural), (Cid, StorageMerkleProof)]
    notAdvertised: HashSet[Cid]

  InvalidBlockSize* = object of StorageError

const DefaultCacheSize*: NBytes = 5.MiBs

method getBlock*(
    self: CacheStore, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  ## Get a block from the stores
  ##

  trace "Getting block from cache", cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock

  if cid notin self.cache:
    return failure (ref BlockNotFoundError)(msg: "Block not in cache " & $cid)

  try:
    return success self.cache[cid]
  except CancelledError as error:
    raise error
  except CatchableError as exc:
    trace "Error requesting block from cache", cid, error = exc.msg
    return failure exc

method getBlocks*(
    self: CacheStore, addresses: seq[BlockAddress]
): Future[SafeAsyncIter[Block]] {.async: (raises: [CancelledError]).} =
  var i = 0

  proc isFinished(): bool =
    i == addresses.len

  proc genNext(): Future[?!Block] {.async: (raises: [CancelledError]).} =
    let value = await self.getBlock(addresses[i])
    inc(i)
    return value

  return SafeAsyncIter[Block].new(genNext, isFinished)

method getCidAndProof*(
    self: CacheStore, treeCid: Cid, index: Natural
): Future[?!(Cid, StorageMerkleProof)] {.async: (raises: [CancelledError]).} =
  if cidAndProof =? self.cidAndProofCache.getOption((treeCid, index)):
    success(cidAndProof)
  else:
    failure(
      newException(
        BlockNotFoundError,
        "Block not in cache: " & $BlockAddress.init(treeCid, index.uint64),
      )
    )

method getBlock*(
    self: CacheStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    return failure(err)

  await self.getBlock(cidAndProof[0])

method getBlockAndProof*(
    self: CacheStore, treeCid: Cid, index: Natural
): Future[?!(Block, StorageMerkleProof)] {.async: (raises: [CancelledError]).} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    return failure(err)

  let (cid, proof) = cidAndProof

  without blk =? await self.getBlock(cid), err:
    return failure(err)

  success((blk, proof))

method getBlock*(
    self: CacheStore, address: BlockAddress
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  self.getBlock(address.treeCid, address.index)

method hasBlock*(
    self: CacheStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking CacheStore for block presence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return (cid in self.cache).success

method hasBlock*(
    self: CacheStore, treeCid: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  without cidAndProof =? (await self.getCidAndProof(treeCid, index)), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(cidAndProof[0])

func cids(self: CacheStore): (iterator (): Cid {.gcsafe, raises: [].}) =
  return
    iterator (): Cid =
      for cid in self.cache.keys:
        yield cid

method listBlocks*(
    self: CacheStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  let cids = self.cids()

  proc isFinished(): bool =
    return finished(cids)

  proc genNext(): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    success(cids())

  let iter = await (
    SafeAsyncIter[Cid].new(genNext, isFinished).filter(
      proc(cid: ?!Cid): Future[bool] {.async: (raises: [CancelledError]).} =
        without cid =? cid, err:
          trace "Cannot get Cid from the iterator", err = err.msg
          return false
        without isManifest =? cid.isManifest, err:
          trace "Error checking if cid is a manifest", err = err.msg
          return false

        case blockType
        of BlockType.Both:
          return true
        of BlockType.Manifest:
          return isManifest
        of BlockType.Block:
          return not isManifest
    )
  )
  success(iter)

func putBlockSync(self: CacheStore, blk: Block): bool =
  let blkSize = blk.data[].len.NBytes # in bytes

  if blkSize > self.size:
    trace "Block size is larger than cache size", blk = blkSize, cache = self.size
    return false

  while self.currentSize + blkSize > self.size:
    try:
      let removed = self.cache.removeLru()
      self.currentSize -= removed.data[].len.NBytes
    except EmptyLruCacheError as exc:
      # if the cache is empty, can't remove anything, so break and add item
      # to the cache
      trace "Exception puting block to cache", exc = exc.msg
      break

  self.cache[blk.cid] = blk
  self.currentSize += blkSize
  return true

method putBlock*(
    self: CacheStore, blk: Block, ttl = Duration.none
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put a block to the blockstore
  ##

  trace "Storing block in cache", cid = blk.cid
  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  discard self.putBlockSync(blk)
  if onBlock =? self.onBlockStored:
    await onBlock(blk.cid)

  return success()

method putCidAndProof*(
    self: CacheStore,
    treeCid: Cid,
    index: Natural,
    blockCid: Cid,
    proof: StorageMerkleProof,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  self.cidAndProofCache[(treeCid, index)] = (blockCid, proof)
  success()

method setAdvertise*(
    self: CacheStore, cid: Cid, advertise: bool
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Set whether the cid is announced to the DHT and served to peers
  ##

  if advertise:
    self.notAdvertised.excl(cid)
  else:
    self.notAdvertised.incl(cid)

  success()

method isAdvertised*(
    self: CacheStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check whether the cid is announced to the DHT and served to peers
  ##

  success(cid notin self.notAdvertised)

method ensureExpiry*(
    self: CacheStore, cid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Updates block's assosicated TTL in store - not applicable for CacheStore
  ##

  discard # CacheStore does not have notion of TTL

method ensureExpiry*(
    self: CacheStore, treeCid: Cid, index: Natural, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Updates block's associated TTL in store - not applicable for CacheStore
  ##

  discard # CacheStore does not have notion of TTL

method delBlock*(
    self: CacheStore, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from cache", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let removed = self.cache.del(cid)
  if removed.isSome:
    self.currentSize -= removed.get.data[].len.NBytes

  return success()

method delBlock*(
    self: CacheStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let maybeRemoved = self.cidAndProofCache.del((treeCid, index))

  if removed =? maybeRemoved:
    return await self.delBlock(removed[0])

  return success()

method close*(self: CacheStore): Future[void] {.async: (raises: []).} =
  ## Close the blockstore, a no-op for this implementation
  ##

  discard

proc new*(
    _: type CacheStore,
    blocks: openArray[Block] = [],
    cacheSize: NBytes = DefaultCacheSize,
    chunkSize: NBytes = DefaultChunkSize,
): CacheStore {.raises: [Defect, ValueError].} =
  ## Create a new CacheStore instance
  ##
  ## `cacheSize` and `chunkSize` are both in bytes
  ##

  if cacheSize < chunkSize:
    raise newException(ValueError, "cacheSize cannot be less than chunkSize")

  let
    currentSize = 0'nb
    size = int(cacheSize div chunkSize)
    cache = newLruCache[Cid, Block](size)
    cidAndProofCache = newLruCache[(Cid, Natural), (Cid, StorageMerkleProof)](size)
    store = CacheStore(
      cache: cache,
      cidAndProofCache: cidAndProofCache,
      currentSize: currentSize,
      size: cacheSize,
      onBlockStored: CidCallback.none,
    )

  for blk in blocks:
    discard store.putBlockSync(blk)

  return store

proc new*(
    _: type CacheStore, blocks: openArray[Block] = [], cacheSize: int, chunkSize: int
): CacheStore {.raises: [Defect, ValueError].} =
  CacheStore.new(blocks, NBytes cacheSize, NBytes chunkSize)
