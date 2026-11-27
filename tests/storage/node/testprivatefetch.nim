import pkg/chronos
import pkg/questionable/results

import pkg/storage/stores
import pkg/storage/blockexchange
import pkg/storage/manifest
import pkg/storage/discovery
import pkg/storage/blocktype as bt
import pkg/storage/node

import ../../asynctest
import ../helpers
import ../helpers/mockdiscovery
import ./helpers

type LookupCounter = ref object
  lookups: int

proc countingDiscovery(counter: LookupCounter): MockDiscovery =
  let discovery = MockDiscovery.new()
  discovery.findBlockProvidersHandler = proc(
      d: MockDiscovery, cid: Cid, useMix: bool = false
  ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
    inc counter.lookups
    return @[]
  discovery

asyncchecksuite "Private fetch - connected peers first":
  var
    cluster: NodesCluster
    holder: NodesComponents
    reader: NodesComponents
    other: NodesComponents
    dataset: TestDataset
    counter: LookupCounter

  setup:
    cluster = await generateNodes(
      3, config = NodeConfig(findFreePorts: true, createFullNode: true)
    )
    holder = cluster.components[0]
    reader = cluster.components[1]
    other = cluster.components[2]

    let blocks = await makeRandomBlocks(4 * 4096, 4096.NBytes)
    dataset = makeDataset(blocks).tryGet()
    await holder.assignBlocks(dataset)
    let manifestBlock = bt.Block
      .new(dataset.manifestCid, dataset.manifest.encode().tryGet(), verify = true)
      .tryGet()
    # Stored as advertised: a holder only serves advertised datasets.
    check (await storeManifestBlock(holder.localStore, manifestBlock, advertise = true)).isOk

    # Every lookup the reader makes is counted; a private fetch over connected
    # peers must make none.
    counter = LookupCounter()
    let discovery = countingDiscovery(counter)
    reader.discovery.discovery = discovery
    reader.node.manifestProtocol.discovery = discovery

  teardown:
    await cluster.cleanup()

  proc expectedData(): seq[byte] =
    for blk in dataset.blocks:
      result &= blk.data[]
    result.setLen(dataset.manifest.datasetSize.int)

  test "A private retrieve uses a peer the user connected to, with no lookup":
    await reader.node.connect(
      holder.switch.peerInfo.peerId, holder.switch.peerInfo.addrs
    )

    let
      started = Moment.now()
      data = await (
        await reader.node.retrieve(
          dataset.manifestCid,
          local = false,
          advertise = false,
          transport = DownloadTransport.Mix,
        )
      ).drain()

    check data == expectedData()
    check Moment.now() - started < PrivateConnectedPeersTimeout
    check counter.lookups == 0

  test "A private dataset fetch uses a peer the user connected to":
    await reader.node.connect(
      holder.switch.peerInfo.peerId, holder.switch.peerInfo.addrs
    )

    check (
      await reader.node.fetchDatasetAsync(
        dataset.manifestDesc, fetchLocal = false, transport = DownloadTransport.Mix
      )
    ).isOk
    for blk in dataset.blocks:
      check (await blk.cid in reader.localStore)
    check counter.lookups == 0

  test "A private fetch does not ask a peer the user did not connect to":
    # Connected, but not through `connect`: for example a DHT neighbour.
    await reader.switch.connect(
      holder.switch.peerInfo.peerId, holder.switch.peerInfo.addrs
    )

    let res = await reader.node.retrieve(
      dataset.manifestCid,
      local = false,
      advertise = false,
      transport = DownloadTransport.Mix,
    )

    check res.isErr
    check not (await dataset.manifestCid in reader.localStore)

  test "A private manifest fetch falls back to Mix when no connected peer has it":
    await reader.node.connect(other.switch.peerInfo.peerId, other.switch.peerInfo.addrs)

    let
      started = Moment.now()
      res = await reader.node.fetchManifest(
        dataset.manifestCid, advertise = false, transport = DownloadTransport.Mix
      )

    # Mix is not enabled on these nodes, so reaching it fails at once.
    check res.isErr
    check "Mix" in res.error.msg
    check Moment.now() - started <= PrivateConnectedPeersTimeout + 1.seconds

  test "A private dataset fetch falls back to Mix when no connected peer has the tree":
    await reader.node.connect(other.switch.peerInfo.peerId, other.switch.peerInfo.addrs)

    let res = await reader.node.fetchDatasetAsync(
      dataset.manifestDesc, fetchLocal = false, transport = DownloadTransport.Mix
    )

    check res.isErr
    check "Mix" in res.error.msg
    # The connected-peer phase never looks for providers.
    check counter.lookups == 0
