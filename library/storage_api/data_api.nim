import chronos
import chronicles
import results
import ffi
import serde/json as serde
import ../declare_lib
import ../../storage/units
import ../../storage/manifest
import ../../storage/stores/repostore

from ../../storage/storage import StorageServer, node, repoStore
from ../../storage/node import
  iterateManifests, fetchManifest, fetchDatasetAsyncTask, delete, hasLocalBlock,
  isAdvertised, setAdvertise
from libp2p import Cid, init, `$`

logScope:
  topics = "libstorage data"

type StorageSpace = object
  totalBlocks* {.serialize.}: Natural
  quotaMaxBytes* {.serialize.}: NBytes
  quotaUsedBytes* {.serialize.}: NBytes
  quotaReservedBytes* {.serialize.}: NBytes

type ManifestWithCid = object
  cid {.serialize.}: string
  manifest {.serialize.}: Manifest

proc storage_list(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns every manifest stored by the node, as JSON.
  var manifests = newSeq[ManifestWithCid]()
  proc onManifest(cid: Cid, manifest: Manifest) {.raises: [], gcsafe.} =
    manifests.add(ManifestWithCid(cid: $cid, manifest: manifest))

  try:
    await self.node.iterateManifests(onManifest)
  except CancelledError:
    return err("Failed to list manifests: cancelled operation.")
  except CatchableError as e:
    return err("Failed to list manifests: " & e.msg)

  return ok(serde.toJson(manifests))

proc storage_space(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the local store quota figures as JSON.
  let repoStore = self.repoStore
  let space = StorageSpace(
    totalBlocks: repoStore.totalBlocks,
    quotaMaxBytes: repoStore.quotaMaxBytes,
    quotaUsedBytes: repoStore.quotaUsedBytes,
    quotaReservedBytes: repoStore.quotaReservedBytes,
  )

  return ok(serde.toJson(space))

proc storage_delete(
    self: Storage, cid: string
): Future[Result[string, string]] {.ffi.} =
  ## Deletes a single block or a whole dataset from the local node.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to delete the data: cannot parse cid: " & cid)

  try:
    let res = await self.node.delete(parsed)
    if res.isErr:
      return err("Failed to delete the data: " & res.error.msg)
  except CancelledError:
    return err("Failed to delete the data: cancelled operation.")
  except CatchableError as e:
    return err("Failed to delete the data: " & e.msg)

  return ok("")

proc storage_fetch(
    self: Storage, cid: string, advertise: bool
): Future[Result[string, string]] {.ffi.} =
  ## Downloads a dataset from the network into the local store, in background.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to fetch the data: cannot parse cid: " & cid)

  try:
    let manifest = await self.node.fetchManifest(parsed, advertise)
    if manifest.isErr:
      return err("Failed to fetch the data: " & manifest.error.msg)

    self.node.fetchDatasetAsyncTask(
      ManifestDescriptor(manifest: manifest.get(), manifestCid: parsed)
    )

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch the data: download cancelled.")

proc storage_exists(
    self: Storage, cid: string
): Future[Result[string, string]] {.ffi.} =
  ## Reports whether the local store holds the block.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to check the data existence: cannot parse cid: " & cid)

  try:
    let exists = await self.node.hasLocalBlock(parsed)
    return ok($exists)
  except CancelledError:
    return err("Failed to check the data existence: operation cancelled.")

proc storage_get_advertise(
    self: Storage, cid: string
): Future[Result[string, string]] {.ffi.} =
  ## Reports whether the dataset is announced to the DHT and served to peers.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to get the advertise state: cannot parse cid: " & cid)

  try:
    let advertised = await self.node.isAdvertised(parsed)
    if advertised.isErr:
      return err("Failed to get the advertise state: " & advertised.error.msg)

    return ok($advertised.get())
  except CancelledError:
    return err("Failed to get the advertise state: operation cancelled.")

proc storage_set_advertise(
    self: Storage, cid: string, advertise: bool
): Future[Result[string, string]] {.ffi.} =
  ## Turns DHT announce and serving of the dataset on or off.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to set the advertise state: cannot parse cid: " & cid)

  try:
    let res = await self.node.setAdvertise(parsed, advertise)
    if res.isErr:
      return err("Failed to set the advertise state: " & res.error.msg)

    return ok($advertise)
  except CancelledError:
    return err("Failed to set the advertise state: operation cancelled.")
