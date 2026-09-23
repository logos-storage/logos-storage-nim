import pkg/chronos
import pkg/questionable/results

import pkg/storage/stores
import pkg/storage/blocktype as bt
import pkg/storage/manifest

import ../../asynctest
import ../helpers
import ../helpers/mockdiscovery
import ../examples

asyncchecksuite "Manifest protocol":
  var
    serverSwitch: Switch
    clientSwitch: Switch
    serverStore: BlockStore
    clientStore: BlockStore
    clientProto: ManifestProtocol
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 123.NBytes, datasetSize = 234.NBytes
    )
    manifestBlk =
      bt.Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    serverSwitch = newStandardSwitch()
    clientSwitch = newStandardSwitch()
    serverStore = CacheStore.new()
    clientStore = CacheStore.new()

    let discovery = MockDiscovery.new()
    discovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid, useMix: bool = false
    ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
      return @[
        PeerRecord.init(
          serverSwitch.peerInfo.peerId, serverSwitch.peerInfo.addrs, seqNo = 0
        )
      ]

    serverSwitch.mount(ManifestProtocol.new(serverSwitch, serverStore, discovery))
    clientProto =
      ManifestProtocol.new(clientSwitch, clientStore, discovery, retries = 1)

    await serverSwitch.start()
    await clientSwitch.start()

    (await serverStore.putBlock(manifestBlk)).tryGet()

  teardown:
    await clientSwitch.stop()
    await serverSwitch.stop()

  test "Should serve an advertised manifest":
    let fetched =
      (await clientProto.fetchManifest(manifestBlk.cid, advertise = true)).tryGet()

    check fetched.treeCid == manifest.treeCid

  test "Should store a fetched manifest without advertising it":
    discard
      (await clientProto.fetchManifest(manifestBlk.cid, advertise = false)).tryGet()

    check:
      (await clientStore.hasBlock(manifestBlk.cid)).tryGet()
      not (await clientStore.isAdvertised(manifestBlk.cid)).tryGet()
      not (await clientStore.isAdvertised(manifest.treeCid)).tryGet()

  test "Should not serve a manifest that is not advertised":
    (await serverStore.setAdvertise(manifestBlk.cid, false)).tryGet()

    check (await clientProto.fetchManifest(manifestBlk.cid, advertise = true)).isErr
