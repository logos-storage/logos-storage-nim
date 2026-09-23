{.push raises: [].}

## This file contains the node storage request.
## 4 operations are available:
## - LIST: list all manifests stored in the node.
## - DELETE: Deletes either a single block or an entire dataset from the local node.
## - FETCH: download a file from the network to the local node.
## - SPACE: get the amount of space used by the local node.
## - EXISTS: check the existence of a cid in a node (local store).

import chronos
import chronicles
import serde/json as serde
import ../../alloc
import ../../../storage/units
import ../../../storage/manifest
import ../../../storage/stores/repostore

from ../../../storage/storage import StorageServer, node, repoStore
from ../../../storage/node import
  iterateManifests, fetchManifest, fetchDatasetAsyncTask, delete, hasLocalBlock,
  isAdvertised, setAdvertise
from libp2p import Cid, init, `$`

logScope:
  topics = "libstorage libstoragestorage"

type NodeStorageMsgType* = enum
  LIST
  DELETE
  FETCH
  SPACE
  EXISTS
  GET_ADVERTISE
  SET_ADVERTISE

type NodeStorageRequest* = object
  operation: NodeStorageMsgType
  cid: cstring
  advertise: bool

type StorageSpace = object
  totalBlocks* {.serialize.}: Natural
  quotaMaxBytes* {.serialize.}: NBytes
  quotaUsedBytes* {.serialize.}: NBytes
  quotaReservedBytes* {.serialize.}: NBytes

proc createShared*(
    T: type NodeStorageRequest,
    op: NodeStorageMsgType,
    cid: cstring = "",
    advertise: bool = true,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()
  ret[].advertise = advertise

  return ret

proc destroyShared*(self: ptr NodeStorageRequest) =
  deallocShared(self[].cid)
  deallocShared(self)

type ManifestWithCid = object
  cid {.serialize.}: string
  manifest {.serialize.}: Manifest

proc list(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  var manifests = newSeq[ManifestWithCid]()
  proc onManifest(cid: Cid, manifest: Manifest) {.raises: [], gcsafe.} =
    manifests.add(ManifestWithCid(cid: $cid, manifest: manifest))

  try:
    let node = storage[].node
    await node.iterateManifests(onManifest)
  except CancelledError:
    return err("Failed to list manifests: cancelled operation.")
  except CatchableError as err:
    return err("Failed to list manifest: : " & err.msg)

  return ok(serde.toJson(manifests))

proc delete(
    storage: ptr StorageServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to delete the data: cannot parse cid: " & $cCid)

  let node = storage[].node
  try:
    let res = await node.delete(cid.get())
    if res.isErr:
      return err("Failed to delete the data: " & res.error.msg)
  except CancelledError:
    return err("Failed to delete the data: cancelled operation.")
  except CatchableError as err:
    return err("Failed to delete the data: " & err.msg)

  return ok("")

proc fetch(
    storage: ptr StorageServer, cCid: cstring, advertise: bool
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to fetch the data: cannot parse cid: " & $cCid)

  try:
    let node = storage[].node
    let manifest = await node.fetchManifest(cid.get(), advertise)
    if manifest.isErr:
      return err("Failed to fetch the data: " & manifest.error.msg)

    node.fetchDatasetAsyncTask(
      ManifestDescriptor(manifest: manifest.get(), manifestCid: cid.get())
    )

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch the data: download cancelled.")

proc space(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let repoStore = storage[].repoStore
  let space = StorageSpace(
    totalBlocks: repoStore.totalBlocks,
    quotaMaxBytes: repoStore.quotaMaxBytes,
    quotaUsedBytes: repoStore.quotaUsedBytes,
    quotaReservedBytes: repoStore.quotaReservedBytes,
  )
  return ok(serde.toJson(space))

proc exists(
    storage: ptr StorageServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to check the data existence: cannot parse cid: " & $cCid)

  try:
    let node = storage[].node
    let exists = await node.hasLocalBlock(cid.get())
    return ok($exists)
  except CancelledError:
    return err("Failed to check the data existence: operation cancelled.")

proc getAdvertise(
    storage: ptr StorageServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to get the advertise state: cannot parse cid: " & $cCid)

  try:
    let node = storage[].node
    let advertised = await node.isAdvertised(cid.get())
    if advertised.isErr:
      return err("Failed to get the advertise state: " & advertised.error.msg)

    return ok($advertised.get())
  except CancelledError:
    return err("Failed to get the advertise state: operation cancelled.")

proc setAdvertise(
    storage: ptr StorageServer, cCid: cstring, advertise: bool
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to set the advertise state: cannot parse cid: " & $cCid)

  try:
    let node = storage[].node
    let res = await node.setAdvertise(cid.get(), advertise)
    if res.isErr:
      return err("Failed to set the advertise state: " & res.error.msg)

    return ok($advertise)
  except CancelledError:
    return err("Failed to set the advertise state: operation cancelled.")

proc process*(
    self: ptr NodeStorageRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  if storage[].isNil:
    const msg = "Failed to process: the node is not created."
    error msg
    return err(msg)

  case self.operation
  of NodeStorageMsgType.LIST:
    let res = (await list(storage))
    if res.isErr:
      error "Failed to LIST.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.DELETE:
    let res = (await delete(storage, self.cid))
    if res.isErr:
      error "Failed to DELETE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.FETCH:
    let res = (await fetch(storage, self.cid, self.advertise))
    if res.isErr:
      error "Failed to FETCH.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.SPACE:
    let res = (await space(storage))
    if res.isErr:
      error "Failed to SPACE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.EXISTS:
    let res = (await exists(storage, self.cid))
    if res.isErr:
      error "Failed to EXISTS.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.GET_ADVERTISE:
    let res = (await getAdvertise(storage, self.cid))
    if res.isErr:
      error "Failed to GET_ADVERTISE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.SET_ADVERTISE:
    let res = (await setAdvertise(storage, self.cid, self.advertise))
    if res.isErr:
      error "Failed to SET_ADVERTISE.", error = res.error
      return err($res.error)
    return res
