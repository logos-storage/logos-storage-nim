import pkg/chronos
import pkg/libp2p/routing_record

import pkg/storage/blockexchange
import pkg/storage/stores
import pkg/storage/chunker
import pkg/storage/discovery
import pkg/storage/blocktype as bt
import pkg/storage/manifest

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

asyncchecksuite "Advertiser":
  var
    blockDiscovery: MockDiscovery
    localStore: BlockStore
    advertiser: Advertiser
    advertised: seq[Cid]
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 123.NBytes, datasetSize = 234.NBytes
    )
    manifestBlk =
      Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    blockDiscovery = MockDiscovery.new()
    localStore = CacheStore.new()

    advertised = newSeq[Cid]()
    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ) {.async: (raises: [CancelledError]), gcsafe.} =
      advertised.add(cid)

    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = examplePeerInfo())

    await advertiser.start()

  teardown:
    await advertiser.stop()

  proc waitTillQueueEmpty() {.async.} =
    check eventually advertiser.advertiseQueue.len == 0

  test "blockStored should queue manifest Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check:
      manifestBlk.cid in advertised

  test "blockStored should not queue tree Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check:
      manifest.treeCid notin advertised

  test "blockStored should not queue non-manifest CIDs for discovery":
    let blk = bt.Block.example

    (await localStore.putBlock(blk)).tryGet()

    await waitTillQueueEmpty()

    check:
      blk.cid notin advertised

  test "Should not queue if there is already an inflight advertise request":
    (await localStore.putBlock(manifestBlk)).tryGet()
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check eventually advertised.len == 1
    check manifestBlk.cid in advertised

  test "Should advertise existing manifests":
    let newStore = CacheStore.new([manifestBlk])

    await advertiser.stop()
    advertiser = Advertiser.new(newStore, blockDiscovery, peerInfo = examplePeerInfo())
    await advertiser.start()

    check eventually manifestBlk.cid in advertised
    check manifest.treeCid notin advertised

  test "Stop should clear onBlockStored callback":
    await advertiser.stop()

    check:
      localStore.onBlockStored.isNone()
