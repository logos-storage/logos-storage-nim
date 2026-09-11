import std/options

import pkg/chronos
import pkg/libp2p/multiaddress
import pkg/libp2p/peerinfo
import pkg/libp2p/routing_record
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/autonatv2/service except setup
import pkg/libp2p/protocols/connectivity/autonatv2/client except setup

import pkg/storage/rng
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

asyncchecksuite "Advertiser reachability":
  var
    blockDiscovery: MockDiscovery
    localStore: BlockStore
    advertiser: Advertiser
    advertised: seq[Cid]
    peerInfo: PeerInfo
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 123.NBytes, datasetSize = 234.NBytes
    )
    manifestBlk =
      Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
    publicAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    circuitAddr = MultiAddress
      .init("/ip4/1.2.3.4/tcp/4001/p2p/" & $PeerId.example & "/p2p-circuit")
      .expect("valid")

  proc autonatWith(reachability: NetworkReachability): AutonatV2Service =
    let rng = Rng.instance().libp2pRng
    result = AutonatV2Service.new(rng, AutonatV2Client.new(rng))
    result.networkReachability = reachability

  proc startAdvertiser(
      addrs: seq[MultiAddress], autonat: Option[AutonatV2Service]
  ) {.async.} =
    peerInfo.addrs = addrs
    advertiser =
      Advertiser.new(localStore, blockDiscovery, peerInfo = peerInfo, autonat = autonat)
    await advertiser.start()

  setup:
    blockDiscovery = MockDiscovery.new()
    localStore = CacheStore.new()
    peerInfo = examplePeerInfo()

    advertised = newSeq[Cid]()
    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ) {.async: (raises: [CancelledError]), gcsafe.} =
      advertised.add(cid)

  teardown:
    if not advertiser.isNil:
      await advertiser.stop()

  test "Should not advertise when AutoNAT reports NotReachable and there is no circuit":
    await startAdvertiser(
      @[publicAddr], some(autonatWith(NetworkReachability.NotReachable))
    )

    (await localStore.putBlock(manifestBlk)).tryGet()
    check eventually advertiser.advertiseQueue.len == 0

    check advertised.len == 0

  test "Should not advertise while AutoNAT reachability is still Unknown":
    await startAdvertiser(@[publicAddr], some(autonatWith(NetworkReachability.Unknown)))

    (await localStore.putBlock(manifestBlk)).tryGet()
    check eventually advertiser.advertiseQueue.len == 0

    check advertised.len == 0

  test "Should not advertise a circuit through a private relay":
    let privateCircuit = MultiAddress
      .init("/ip4/10.0.0.1/tcp/4001/p2p/" & $PeerId.example & "/p2p-circuit")
      .expect("valid")

    await startAdvertiser(
      @[privateCircuit], some(autonatWith(NetworkReachability.NotReachable))
    )

    (await localStore.putBlock(manifestBlk)).tryGet()
    check eventually advertiser.advertiseQueue.len == 0

    check advertised.len == 0

  test "Should advertise when AutoNAT reports Reachable":
    await startAdvertiser(
      @[publicAddr], some(autonatWith(NetworkReachability.Reachable))
    )

    (await localStore.putBlock(manifestBlk)).tryGet()

    check eventually manifestBlk.cid in advertised

  test "Should advertise over a circuit address even when NotReachable":
    await startAdvertiser(
      @[publicAddr, circuitAddr], some(autonatWith(NetworkReachability.NotReachable))
    )

    (await localStore.putBlock(manifestBlk)).tryGet()

    check eventually manifestBlk.cid in advertised

  test "Should advertise once AutoNAT flips to Reachable":
    let autonat = autonatWith(NetworkReachability.NotReachable)
    await startAdvertiser(@[publicAddr], some(autonat))

    (await localStore.putBlock(manifestBlk)).tryGet()
    check eventually advertiser.advertiseQueue.len == 0
    check advertised.len == 0

    autonat.networkReachability = NetworkReachability.Reachable
    advertiser.onAddrChange()

    check eventually manifestBlk.cid in advertised

  test "Should advertise when there is no AutoNAT service":
    await startAdvertiser(@[publicAddr], none(AutonatV2Service))

    (await localStore.putBlock(manifestBlk)).tryGet()

    check eventually manifestBlk.cid in advertised
