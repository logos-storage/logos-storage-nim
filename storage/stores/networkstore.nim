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
import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import ../clock
import ../blocktype
import ../blockexchange
import ../logutils
import ../merkletree
import ../utils/asyncheapqueue
import ../utils/safeasynciter
import ./blockstore

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "storage networkstore"

type NetworkStore* = ref object of BlockStore
  engine*: BlockExcEngine # blockexc decision engine
  localStore*: BlockStore # local block store
  downloadId: Option[uint64]
    # A streaming download must wait on its own handles, not another download
    # of the same tree that may use a different transport.

method getBlocks*(
    self: NetworkStore, addresses: seq[BlockAddress]
): Future[SafeAsyncIter[Block]] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.getBlocks(addresses)

method getBlock*(
    self: NetworkStore, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  let downloadOpt =
    if self.downloadId.isSome:
      self.engine.downloadManager.getDownload(self.downloadId.get(), address.treeCid)
    else:
      self.engine.downloadManager.getDownload(address.treeCid)
  if downloadOpt.isSome:
    let handle = downloadOpt.get().getWantHandle(address)
    without blk =? (await self.localStore.getBlock(address)), err:
      if not (err of BlockNotFoundError):
        handle.cancelSoon()
        return failure err
      return await handle
    discard downloadOpt.get().completeWantHandle(address, some(blk))
    return success blk

  return await self.localStore.getBlock(address)

method getBlock*(
    self: NetworkStore, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block from the local blockstore only.
  ##
  self.localStore.getBlock(cid)

method getBlock*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(treeCid, index.uint64))

method putBlock*(
    self: NetworkStore, blk: Block, ttl = Duration.none
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store block locally and notify the network
  ##
  let res = await self.localStore.putBlock(blk, ttl)
  if res.isErr:
    return res

  return success()

method putCidAndProof*(
    self: NetworkStore,
    treeCid: Cid,
    index: Natural,
    blockCid: Cid,
    proof: StorageMerkleProof,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.putCidAndProof(treeCid, index, blockCid, proof)

method getCidAndProof*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!(Cid, StorageMerkleProof)] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block proof from the blockstore
  ##

  self.localStore.getCidAndProof(treeCid, index)

method ensureExpiry*(
    self: NetworkStore, cid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Ensure that block's assosicated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  without blockCheck =? await self.localStore.hasBlock(cid), err:
    return failure(err)

  if blockCheck:
    return await self.localStore.ensureExpiry(cid, expiry)
  else:
    trace "Updating expiry - block not in local store", cid

  return success()

method ensureExpiry*(
    self: NetworkStore, treeCid: Cid, index: Natural, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  without blockCheck =? await self.localStore.hasBlock(treeCid, index), err:
    return failure(err)

  if blockCheck:
    return await self.localStore.ensureExpiry(treeCid, index, expiry)
  else:
    trace "Updating expiry - block not in local store", treeCid, index

  return success()

method listBlocks*(
    self: NetworkStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.listBlocks(blockType)

method delBlock*(
    self: NetworkStore, cid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from network store", cid
  return self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(
    self: NetworkStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking network store for block existence", cid
  return await self.localStore.hasBlock(cid)

method hasBlock*(
    self: NetworkStore, tree: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##
  trace "Checking network store for block existence", tree, index
  return await self.localStore.hasBlock(tree, index)

method close*(self: NetworkStore): Future[void] {.async: (raises: []).} =
  ## Close the underlying local blockstore
  ##

  if not self.localStore.isNil:
    await self.localStore.close

proc new*(
    T: type NetworkStore,
    engine: BlockExcEngine,
    localStore: BlockStore,
    downloadId: Option[uint64] = none(uint64),
): NetworkStore =
  ## Create new instance of a NetworkStore
  ##
  NetworkStore(localStore: localStore, engine: engine, downloadId: downloadId)
