import std/sets

import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import pkg/storage/stores
import pkg/storage/blocktype as bt
import pkg/storage/manifest

import ../../asynctest
import ../helpers
import ../examples

type FailingStore = ref object of BlockStore
  notAdvertised: HashSet[Cid]

method putBlock*(
    self: FailingStore, blk: bt.Block, ttl = Duration.none
): Future[?!void] {.async: (raises: [CancelledError]).} =
  failure("Block could not be stored")

method setAdvertise*(
    self: FailingStore, cid: Cid, advertise: bool
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if advertise:
    self.notAdvertised.excl(cid)
  else:
    self.notAdvertised.incl(cid)

  success()

method isAdvertised*(
    self: FailingStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  success(cid notin self.notAdvertised)

asyncchecksuite "Manifest store":
  var
    localStore: BlockStore
    failingStore: FailingStore
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 123.NBytes, datasetSize = 234.NBytes
    )
    manifestBlk =
      bt.Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    localStore = CacheStore.new()
    failingStore = FailingStore()

  test "Should store the manifest and keep advertising it":
    discard
      (await storeManifestBlock(localStore, manifestBlk, advertise = true)).tryGet()

    check:
      (await localStore.hasBlock(manifestBlk.cid)).tryGet()
      (await localStore.isAdvertised(manifestBlk.cid)).tryGet()
      (await localStore.isAdvertised(manifest.treeCid)).tryGet()

  test "Should store the manifest and stop advertising the manifest and tree cid":
    discard
      (await storeManifestBlock(localStore, manifestBlk, advertise = false)).tryGet()

    check:
      (await localStore.hasBlock(manifestBlk.cid)).tryGet()
      not (await localStore.isAdvertised(manifestBlk.cid)).tryGet()
      not (await localStore.isAdvertised(manifest.treeCid)).tryGet()

  test "Should revert the advertise state when the block cannot be stored":
    let res = await storeManifestBlock(failingStore, manifestBlk, advertise = false)

    check:
      res.isErr
      (await failingStore.isAdvertised(manifestBlk.cid)).tryGet()
      (await failingStore.isAdvertised(manifest.treeCid)).tryGet()

  test "Should keep an already disabled cid disabled when the block cannot be stored":
    (await failingStore.setAdvertise(manifest.treeCid, false)).tryGet()

    let res = await storeManifestBlock(failingStore, manifestBlk, advertise = false)

    check:
      res.isErr
      (await failingStore.isAdvertised(manifestBlk.cid)).tryGet()
      not (await failingStore.isAdvertised(manifest.treeCid)).tryGet()
