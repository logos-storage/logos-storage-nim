import std/[tables, times]

import pkg/libp2p
import pkg/chronos
import pkg/storage/storagetypes
import pkg/storage/chunker
import pkg/storage/stores

import ../../asynctest

type CountingStore* = ref object of NetworkStore
  lookups*: Table[Cid, int]

proc new*(
    T: type CountingStore, engine: BlockExcEngine, localStore: BlockStore
): CountingStore =
  # XXX this works cause NetworkStore.new is trivial
  result = CountingStore(engine: engine, localStore: localStore)

method getBlock*(
    self: CountingStore, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  self.lookups.mgetOrPut(address.treeCid, 0).inc
  await procCall getBlock(NetworkStore(self), address)

proc toTimesDuration*(d: chronos.Duration): times.Duration =
  initDuration(seconds = d.seconds)

proc drain*(
    stream: LPStream | Result[lpstream.LPStream, ref CatchableError]
): Future[seq[byte]] {.async.} =
  let stream =
    when typeof(stream) is Result[lpstream.LPStream, ref CatchableError]:
      stream.tryGet()
    else:
      stream

  defer:
    await stream.close()

  var data: seq[byte]
  while not stream.atEof:
    var
      buf = newSeq[byte](DefaultBlockSize.int)
      res = await stream.readOnce(addr buf[0], DefaultBlockSize.int)
    check res <= DefaultBlockSize.int
    buf.setLen(res)
    data &= buf

  data

proc pipeChunker*(stream: BufferStream, chunker: Chunker) {.async.} =
  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      await stream.pushData(chunk)
  finally:
    await stream.pushEof()
    await stream.close()

template setupAndTearDown*() {.dirty.} =
  var
    file: File
    chunker: Chunker
    switch: Switch
    network: BlockExcNetwork
    clock: Clock
    localStore: RepoStore
    localStoreRepoDs: Datastore
    localStoreMetaDs: Datastore
    engine: BlockExcEngine
    store: NetworkStore
    node: StorageNodeRef
    blockDiscovery: Discovery
    peerStore: PeerContextStore
    downloadManager: DownloadManager
    discovery: DiscoveryEngine
    advertiser: Advertiser

  let
    path = currentSourcePath().parentDir
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  setup:
    file = open(path /../ "" /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    network = BlockExcNetwork.new(switch)

    clock = SystemClock.new()
    localStoreMetaDs = metaTmp.newDb()
    localStoreRepoDs = repoTmp.newDb()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock = clock)
    await localStore.start()

    blockDiscovery = Discovery.new(switch)
    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery)
    advertiser = Advertiser.new(localStore, blockDiscovery, peerInfo = switch.peerInfo)
    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, downloadManager
    )
    store = NetworkStore.new(engine, localStore)
    let manifestProto = ManifestProtocol.new(switch, localStore, blockDiscovery)
    switch.mount(manifestProto)
    node = StorageNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = blockDiscovery,
      manifestProto = manifestProto,
      taskpool = Taskpool.new(),
    )

  teardown:
    file.close()
    await node.stop()
    await metaTmp.destroyDb()
    await repoTmp.destroyDb()
