import std/sequtils

import pkg/chronos
import pkg/questionable/results

import pkg/storage/discovery
import pkg/storage/errors
import pkg/storage/stores
import pkg/storage/blocktype as bt
import pkg/storage/manifest
import pkg/storage/peertransport

import ../../asynctest
import ../helpers
import ../helpers/mockdiscovery
import ../examples

type
  BatchDiscovery = ref object of Discovery
    first, fallback: PeerRecord
    release, delivered, finish: AsyncEvent
    stopped: bool
    attempts: int

  GatedTransport = ref object of PeerTransport
    direct: PeerTransport
    first: PeerId
    started, release, ended: AsyncEvent
    calls: seq[PeerId]

  FailingStore = ref object of BlockStore

method getBlock(
    self: FailingStore, cid: Cid
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  return failure(newException(BlockNotFoundError, "missing manifest"))

method putBlock(
    self: FailingStore, blk: bt.Block, ttl = Duration.none
): Future[?!void] {.async: (raises: [CancelledError]).} =
  return failure("manifest write failed")

method findBatches(
    d: BatchDiscovery,
    cid: Cid,
    useMix: bool,
    deadline: Moment,
    deliver: ProviderBatchHandler,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  doAssert useMix
  inc d.attempts
  try:
    deliver(@[d.first])
    await d.release.wait()
    deliver(@[d.first, d.fallback, d.fallback])
    d.delivered.fire()
    await d.finish.wait()
    return success()
  finally:
    d.stopped = true

method kind(self: GatedTransport): DownloadTransport =
  DownloadTransport.Mix

method dial(
    self: GatedTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  self.calls.add(peer.peerId)
  if peer.peerId == self.first:
    self.started.fire()
    try:
      await self.release.wait()
      return failure("first peer unavailable")
    finally:
      self.ended.fire()
  return await self.direct.dial(peer, codec)

asyncchecksuite "Manifest protocol":
  var
    serverSwitch: Switch
    clientSwitch: Switch
    serverStore: BlockStore
    clientStore: BlockStore
    clientProto: ManifestProtocol
    clientTransport: PeerTransport
    batches: BatchDiscovery
    gated: GatedTransport
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 4096.NBytes, datasetSize = 8000.NBytes
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

    serverSwitch.mount(ManifestProtocol.new(serverStore, discovery))
    clientProto = ManifestProtocol.new(clientStore, discovery, retries = 1)
    clientTransport = DirectPeerTransport.new(clientSwitch)

    await serverSwitch.start()
    await clientSwitch.start()

    (await serverStore.putBlock(manifestBlk)).tryGet()

    batches = BatchDiscovery(
      first: PeerRecord.example,
      fallback:
        PeerRecord.init(serverSwitch.peerInfo.peerId, serverSwitch.peerInfo.addrs),
      release: newAsyncEvent(),
      delivered: newAsyncEvent(),
      finish: newAsyncEvent(),
    )
    gated = GatedTransport(
      direct: clientTransport,
      first: batches.first.peerId,
      started: newAsyncEvent(),
      release: newAsyncEvent(),
      ended: newAsyncEvent(),
    )

  teardown:
    await clientSwitch.stop()
    await serverSwitch.stop()

  test "Should serve an advertised manifest":
    let fetched = (
      await clientProto.fetchManifest(
        manifestBlk.cid, advertise = true, transport = clientTransport
      )
    ).tryGet()

    check fetched.treeCid == manifest.treeCid

  test "Should store a fetched manifest without advertising it":
    discard (
      await clientProto.fetchManifest(
        manifestBlk.cid, advertise = false, transport = clientTransport
      )
    ).tryGet()

    check:
      (await clientStore.hasBlock(manifestBlk.cid)).tryGet()
      not (await clientStore.isAdvertised(manifestBlk.cid)).tryGet()
      not (await clientStore.isAdvertised(manifest.treeCid)).tryGet()

  test "Should not serve a manifest that is not advertised":
    (await serverStore.setAdvertise(manifestBlk.cid, false)).tryGet()

    check (
      await clientProto.fetchManifest(
        manifestBlk.cid, advertise = true, transport = clientTransport
      )
    ).isErr

  test "Mix queues unique fallbacks while the first fetch is outstanding":
    clientProto.discovery = batches
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    await gated.started.wait().wait(5.seconds)
    batches.release.fire()
    await batches.delivered.wait().wait(5.seconds)
    check gated.calls == @[batches.first.peerId]
    gated.release.fire()
    check:
      (await fetch.wait(5.seconds)).tryGet().treeCid == manifest.treeCid
      gated.calls == @[batches.first.peerId, batches.fallback.peerId]
      batches.stopped

  test "Mix waits for another batch after the first peer times out":
    clientProto.discovery = batches
    clientProto.fetchTimeout = 1.seconds
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    await gated.ended.wait().wait(5.seconds)
    check not fetch.finished
    batches.release.fire()
    check:
      (await fetch.wait(5.seconds)).tryGet().treeCid == manifest.treeCid
      gated.calls == @[batches.first.peerId, batches.fallback.peerId]
      batches.stopped

  test "Mix finishes a queued fetch after discovery ends":
    clientProto.discovery = batches
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    await gated.started.wait().wait(5.seconds)
    batches.release.fire()
    batches.finish.fire()
    await batches.delivered.wait().wait(5.seconds)
    gated.release.fire()
    check:
      (await fetch.wait(5.seconds)).tryGet().treeCid == manifest.treeCid
      gated.calls == @[batches.first.peerId, batches.fallback.peerId]

  test "Caller cancellation cleans up the active fetch and discovery":
    clientProto.discovery = batches
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    await gated.started.wait().wait(5.seconds)
    await fetch.cancelAndWait()
    check:
      fetch.cancelled
      gated.ended.isSet
      batches.stopped

  test "Mix stops discovery after first peer succeeds":
    clientProto.discovery = batches
    batches.first = batches.fallback
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    check:
      (await fetch.wait(5.seconds)).tryGet().treeCid == manifest.treeCid
      gated.calls == @[batches.first.peerId]
      batches.stopped

  test "A local store write failure ends the manifest download":
    clientProto.discovery = batches
    clientProto.localStore = FailingStore()
    clientProto.retries = 2
    batches.first = batches.fallback
    let fetched =
      await clientProto.fetchManifest(manifestBlk.cid, true, gated).wait(5.seconds)
    check:
      fetched.isErr
      fetched.error.msg == "Unable to store manifest: manifest write failed"
      batches.attempts == 1
      batches.stopped

  test "Caller cancellation while waiting for more peers stops discovery":
    clientProto.discovery = batches
    let fetch = clientProto.fetchManifest(manifestBlk.cid, true, gated)
    await gated.started.wait().wait(5.seconds)
    gated.release.fire()
    await gated.ended.wait().wait(5.seconds)
    await sleepAsync(0.milliseconds)
    await fetch.cancelAndWait()
    check:
      fetch.cancelled
      batches.stopped
      gated.calls == @[batches.first.peerId]

  test "A CID-verified block with invalid manifest bytes is terminal":
    let invalid = bt.Block.new(data = @[0xff'u8], codec = ManifestCodec).tryGet()
    (await serverStore.putBlock(invalid)).tryGet()
    batches.first = batches.fallback
    clientProto.discovery = batches
    clientProto.retries = 2
    let fetched =
      await clientProto.fetchManifest(invalid.cid, true, gated).wait(5.seconds)
    check:
      fetched.isErr
      fetched.error.msg ==
        "Unable to store manifest: " & Manifest.decode(invalid).error.msg
      batches.stopped
      batches.attempts == 1
      gated.calls == @[batches.first.peerId]
      not (await clientStore.hasBlock(invalid.cid)).tryGet()

  test "A peer reporting NotFound leaves a later provider eligible":
    let emptyPeer = newStandardSwitch()
    emptyPeer.mount(ManifestProtocol.new(CacheStore.new(), MockDiscovery.new()))
    await emptyPeer.start()
    try:
      batches.first =
        PeerRecord.init(emptyPeer.peerInfo.peerId, emptyPeer.peerInfo.addrs)
      clientProto.discovery = batches
      batches.release.fire()
      let fetched =
        await clientProto.fetchManifest(manifestBlk.cid, true, gated).wait(5.seconds)
      check:
        fetched.tryGet().treeCid == manifest.treeCid
        gated.calls == @[batches.first.peerId, batches.fallback.peerId]
        batches.stopped
    finally:
      await emptyPeer.stop()

type CountingStore = ref object of BlockStore
  ## Counts manifest requests and holds nothing.
  requests: int

method isAdvertised*(
    self: CountingStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.requests
  success false

proc startPeerServing(store: BlockStore, client: Switch): Future[Switch] {.async.} =
  ## A peer that serves the manifests of `store`, connected to `client` and
  ## unknown to discovery.
  let switch = newStandardSwitch()
  switch.mount(ManifestProtocol.new(store, nullDiscovery()))
  await switch.start()
  await client.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
  switch

asyncchecksuite "Manifest protocol - connected peers":
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 4096.NBytes, datasetSize = 8000.NBytes
    )
    manifestBlk =
      bt.Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  var
    clientSwitch: Switch
    clientTransport: PeerTransport
    remoteSwitches: seq[Switch]

  setup:
    clientSwitch = newStandardSwitch()
    clientTransport = DirectPeerTransport.new(clientSwitch)
    remoteSwitches = @[]
    await clientSwitch.start()

  teardown:
    await clientSwitch.stop()
    for switch in remoteSwitches:
      await switch.stop()

  test "Should fetch a manifest from a connected peer that discovery did not find":
    let serverStore = CacheStore.new()
    (await serverStore.putBlock(manifestBlk)).tryGet()
    remoteSwitches.add(await startPeerServing(serverStore, clientSwitch))

    let
      clientProto = ManifestProtocol.new(CacheStore.new(), nullDiscovery(), retries = 1)
      fetched = (
        await clientProto.fetchManifest(
          manifestBlk.cid, advertise = true, transport = clientTransport
        )
      ).tryGet()

    check fetched.treeCid == manifest.treeCid

  test "Should ask at most maxConnectedPeers connected peers":
    var stores: seq[CountingStore]
    for _ in 0 ..< 5:
      let store = CountingStore()
      stores.add(store)
      remoteSwitches.add(await startPeerServing(store, clientSwitch))

    let clientProto = ManifestProtocol.new(
      CacheStore.new(), nullDiscovery(), retries = 1, maxConnectedPeers = 2
    )

    check (
      await clientProto.fetchManifest(
        manifestBlk.cid, advertise = true, transport = clientTransport
      )
    ).isErr
    check stores.mapIt(it.requests).foldl(a + b) == 2
