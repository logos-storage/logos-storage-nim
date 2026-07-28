## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import std/tables
import std/cpuinfo
import std/net
import std/sequtils

import pkg/chronos
import pkg/taskpools
import pkg/presto
import pkg/libp2p
import pkg/libp2p/connmanager
import pkg/libp2p/protocols/connectivity/autonatv2/[service, client]
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/protocols/connectivity/relay/relay as relayModule
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/transports/tcptransport
import pkg/libp2p_mix
import pkg/confutils
import pkg/confutils/defs
import pkg/datastore

import ./node
import ./manifest/protocol
import ./conf
import ./rng as random
import ./rest/api
import ./stores
import ./blockexchange
import ./dht_proxy/handler
import ./utils/fileutils
import ./utils/mixidentity
import ./discovery
import ./utils/addrutils
import ./utils/spr
import ./namespaces
import ./storagetypes
import ./logutils
import ./nat
import ./utils/natutils

logScope:
  topics = "storage node"

type
  StorageServer* = ref object
    config: StorageConf
    logFile*: Option[IoHandle]
    restServer: RestServerRef
    storageNode: StorageNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    # Expose to make reachability accessible from rest api
    autonatService*: Option[AutonatV2Service]
    autoRelayService*: Option[AutoRelayService]
    natMapper*: Option[NatPortMapper]
    holePunchHandler: Option[connmanager.PeerEventHandler]
    bootstrapNodes: seq[SignedPeerRecord]
    isStarted: bool

  StoragePrivateKey* = libp2p.PrivateKey # alias

func config*(self: StorageServer): StorageConf =
  return self.config

func node*(self: StorageServer): StorageNodeRef =
  return self.storageNode

func repoStore*(self: StorageServer): RepoStore =
  return self.repoStore

proc start*(s: StorageServer) {.async.} =
  if s.isStarted:
    warn "Storage server already started, skipping"
    return

  trace "Starting Storage node", config = $s.config
  await s.repoStore.start()

  s.maintenance.start()

  # Activate SO_REUSEPORT for hole punching in tcptransport.nim.
  # Without that, hole punching would use an ephemeral port assigned by the OS.
  # NotReachable has nothing to do with AutoNAT Reachability
  if s.holePunchHandler.isSome:
    for t in s.storageNode.switch.transports:
      t.networkReachability = NetworkReachability.NotReachable

  await s.storageNode.switch.start()

  var realPort = Port(0)

  for listenAddr in s.storageNode.switch.peerInfo.listenAddrs:
    let maybePort = getTcpPort(listenAddr)
    if maybePort.isSome:
      realPort = maybePort.get
      break

  if realPort == Port(0):
    raise newException(StorageError, "Failed to determine the real TCP port")

  if s.config.nat.hasExtIp:
    # extip means that we assume the IP is reachable.
    let extIpAddr = getMultiAddrWithIpAndTcpPort(s.config.nat.extIp, realPort)

    # Feed switch.peerInfo.addrs with extIp value only.
    # For example, we want to make sure that relay servers will
    # contain only the extIp, no private addresses.
    let peerInfo = s.storageNode.switch.peerInfo
    peerInfo.announcedAddrs = @[extIpAddr]
    # We force the update to take in consideration the announcedAddrs
    await peerInfo.update()

  if s.config.mixEnabled:
    let
      switch = s.storageNode.switch
      (mixPub, mixPriv) = loadOrGenerateMixKeys(
        string(s.config.dataDir) / "mix-identity"
      ).valueOr:
        raise newException(
          StorageError, "Failed to load or generate Mix keys: " & error.msg
        )
      # We define a placeholder here.
      # For nat:extip, the address will be updated by `updateLocalMultiAddr` on node start.
      # For nat:auto, the node waits for AutoNAT to provide a reachable address or a relay address.
      # The Mix lookup will not be performed while the mixAddr value is mixUnsetMultiAddr().
      mixAddr = mixUnsetMultiAddr()
      mixNodeInfo = buildMixNodeInfo(
        mixPub, mixPriv, switch.peerInfo.peerId, mixAddr, switch.peerInfo.privateKey
      ).valueOr:
        raise newException(StorageError, "Failed to build Mix node info: " & error.msg)
      relayPool = (
        if s.config.mixPoolJson.len > 0:
          loadRelayPubInfoTableFromJson(s.config.mixPoolJson)
        else:
          loadRelayPubInfoTableFromFile(s.config.mixPool)
      ).valueOr:
        raise newException(StorageError, "Failed to load Mix relay pool: " & error.msg)
      mixProto = MixProtocol.new(mixNodeInfo, switch)

    info "Starting node with Mix relay pool", count = relayPool.len

    for info in relayPool.values:
      mixProto.nodePool.add(info)

    mixProto.registerDestReadBehavior(DhtProxyCodec, readLp(MaxLookupResponseBytes))
    await mixProto.start()
    switch.mount(mixProto)

    let dhtProxyProto =
      if cap =? s.config.dhtProxyMaxInFlight:
        DhtProxyProtocol.new(s.storageNode.discovery, maxInFlight = cap)
      else:
        DhtProxyProtocol.new(s.storageNode.discovery)
    await dhtProxyProto.start()
    switch.mount(dhtProxyProto)

    s.storageNode.discovery.mixProto = mixProto

    if s.config.dhtMixProxies.len > 0:
      discard s.storageNode.discovery.togglePrivateQueries(true).valueOr:
        raise
          newException(StorageError, "Failed to enable private queries: " & error.msg)

    s.storageNode.engine.network.excludeRelays(relayPool.keys.toSeq)

  if s.natMapper.isSome:
    s.natMapper.get.start()

  # When listenPort is 0 the OS assigns a random port.
  if s.natMapper.isSome and s.config.listenPort == Port(0):
    s.natMapper.get.tcpPort = realPort

  await s.storageNode.start()

  # Connect to the Autonat servers (currently bootsrap nodes) in order to
  # have connected peers for Autonat. The dials are run concurrently in case of
  # a dead autonat server that could timeout.
  proc connectAutonatServer(
      record: SignedPeerRecord
  ) {.async: (raises: [CancelledError]).} =
    try:
      let (peerId, addresses) = record.toPeerIdAndAddrs()
      await s.storageNode.switch.connect(peerId, addresses)
    except CancelledError as exc:
      raise exc
    except CatchableError as e:
      warn "Cannot connect to bootstrap node", error = e.msg

  # noCancel: cancelling allFutures does not cancel the
  # connectAutonatServer futures.
  await noCancel allFutures(
    findAutonatServers(s.bootstrapNodes).mapIt(connectAutonatServer(it))
  )

  # AutoNAT is not in switch.services because we want to start it
  # after the bootstrap connections to have connected peers for the first probe.
  if s.autonatService.isSome:
    await s.autonatService.get.start(s.storageNode.switch)

  if s.restServer != nil:
    s.restServer.start()

  s.isStarted = true

proc stop*(s: StorageServer) {.async.} =
  if not s.isStarted:
    warn "Storage is not started"
    return

  notice "Stopping Storage node"

  if s.natMapper.isSome:
    s.natMapper.get.stop()

  if s.holePunchHandler.isSome:
    s.storageNode.switch.removePeerEventHandler(
      s.holePunchHandler.get, PeerEventKind.Joined
    )

  var futures = @[
    s.storageNode.switch.stop(),
    s.storageNode.stop(),
    s.repoStore.stop(),
    s.maintenance.stop(),
  ]

  if s.autoRelayService.isSome and s.autoRelayService.get.isRunning:
    proc stopAutoRelay(): Future[void] {.async: (raises: []).} =
      await noCancel s.autoRelayService.get.stop(s.storageNode.switch)

    futures.add(stopAutoRelay())

  if s.autonatService.isSome:
    futures.add(s.autonatService.get.stop(s.storageNode.switch))

  if s.restServer != nil:
    futures.add(s.restServer.stop())

  let res = await noCancel allDone[void](futures)

  s.isStarted = false

  if res.failed.len > 0:
    error "Failed to stop Storage node", failures = res.failed.len
    raise newException(
      StorageError,
      "Failed to stop Storage node: " & res.failed.mapIt(it.error.msg).join(", "),
    )
  if res.cancelled.len > 0:
    warn "Storage node stop was cancelled due to child stop routine(s) being cancelled, child routines cancelled: ",
      cancellations = res.cancelled.len
    raise newException(
      CancelledError,
      "Storage node stop was cancelled due to child stop routine(s) being cancelled, child routines cancelled: " &
        $res.cancelled.len,
    )

proc close*(s: StorageServer) {.async.} =
  var futures = @[s.storageNode.close(), s.repoStore.close()]

  let res = await noCancel allDone[void](futures)

  if not s.taskpool.isNil:
    s.taskpool.shutdown()

  when defaultChroniclesStream.outputs.type.arity >= 3:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    defaultChroniclesStream.outputs[2].writer = noOutput

  if s.logFile.isSome:
    if error =? closeFile(s.logFile.get()).errorOption:
      error "Failed to close log file", errorCode = $error

  if res.failed.len > 0:
    error "Failed to close Storage node", failures = res.failed.len
    raise newException(
      StorageError,
      "Failed to close Storage node: " & res.failed.mapIt(it.error.msg).join(", "),
    )
  if res.cancelled.len > 0:
    warn "Storage node close was cancelled due to child close routine(s) being cancelled, child routines cancelled: ",
      cancellations = res.cancelled.len
    raise newException(
      CancelledError,
      "Storage node close was cancelled due to child close routine(s) being cancelled, child routines cancelled: " &
        $res.cancelled.len,
    )

proc shutdown*(server: StorageServer) {.async.} =
  await server.stop()
  await server.close()

proc new*(
    T: type StorageServer,
    config: StorageConf,
    privateKey: StoragePrivateKey,
    logFile: Option[IoHandle] = IoHandle.none,
): StorageServer =
  ## create StorageServer including setting up datastore, repostore, etc.

  if err =? config.validateAutonatConfig().errorOption:
    raise newException(StorageError, err.msg)

  # Switch
  let listenMultiAddr = getMultiAddrWithIpAndTcpPort(config.listenIp, config.listenPort)

  let relayClient = RelayClient.new()
  let relay: Relay =
    if config.isRelayServer:
      Relay.new()
    else:
      relayClient

  var switchBuilder = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(@[listenMultiAddr])
    .withWildcardResolver(true)
    .withIdentifyPusher(false)
    .withRng(random.Rng.instance().libp2pRng)
    .withNoise()
    .withYamux()
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withCircuitRelay(relay)

  let bootstrapNodes =
    if config.noBootstrapNode:
      # Sanity checks that the user isn't doing anything funny.
      if config.bootstrapNodes.len > 0:
        error "Cannot specify bootstrap nodes when using no-bootstrap flag"
        raise newException(
          ValueError, "Cannot specify bootstrap nodes when using no-bootstrap flag"
        )

      warn "Node has been marked with --no-bootstrap-node and will NOT be bootstrapped"
      seq[SignedPeerRecord](@[])
    elif config.bootstrapNodes.len > 0:
      warn "Overriding network preset using custom bootstrap nodes",
        nodes = config.bootstrapNodes
      config.bootstrapNodes
    else:
      info "Bootstrapping node using a predefined network", network = $config.network
      config.network.bootstrapNodes

  var autonatConfig = none(AutonatV2ServiceConfig)
  if config.autonatServer:
    info "AutoNAT server enabled"
    switchBuilder = switchBuilder.withAutonatV2Server()
  elif not config.nat.hasExtIp:
    info "AutoNAT client enabled",
      scheduleInterval = config.natScheduleInterval,
      numPeersToAsk = config.natNumPeersToAsk,
      maxQueueSize = config.natMaxQueueSize,
      minConfidence = config.natMinConfidence
    autonatConfig = some(
      AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(config.natScheduleInterval),
        askNewConnectedPeers = false,
        numPeersToAsk = config.natNumPeersToAsk,
        maxQueueSize = config.natMaxQueueSize,
        minConfidence = config.natMinConfidence,
        enableDialableCandidates = true,
      )
    )

    let observedAddrMinCount = min(config.natObservedAddrMinCount, bootstrapNodes.len)
    switchBuilder = switchBuilder.withObservedAddrManager(
      ObservedAddrManager.new(minCount = observedAddrMinCount)
    )
    # libp2p keeps the private address in peerInfo.addrs.
    # Since Autonat V2 uses the observed public address,
    # we can filter the private addresses to keep only the dialable
    # addresses.
    switchBuilder = switchBuilder.withAddressPolicy(dialableAddressPolicy)

  let switch = switchBuilder
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  var taskPool: Taskpool

  # AutoNAT's first reachability probe fires immediately on start.
  # Wired via withAutonatV2 it lands in switch.services and runs at switch.start,
  # before bootstrap, on an empty peer set.
  # We build and own it here so we can start it ourselves after bootstrap,
  # with the bootstrap peers connected.
  let autonatService: Option[AutonatV2Service] =
    if autonatConfig.isSome:
      let client = AutonatV2Client.new(switch.rng)
      client.setup(switch)
      switch.mount(client)
      let service = AutonatV2Service.new(switch.rng, client, autonatConfig.get)
      service.setup(switch)
      some(service)
    else:
      none(AutonatV2Service)

  # Storage infrastructure

  try:
    if config.numThreads == ThreadCount(0):
      taskPool = Taskpool.new(numThreads = min(countProcessors(), 16))
    else:
      taskPool = Taskpool.new(numThreads = int(config.numThreads))
    info "Threadpool started", numThreads = taskPool.numThreads
  except CatchableError as exc:
    raiseAssert("Failure in taskPool initialization:" & exc.msg)

  let
    discovery = Discovery.new(
      switch,
      bootstrapNodes = bootstrapNodes.mapIt(it.toPeerIdAndAddrs()),
      dhtMixProxies = config.dhtMixProxies,
      isServer = config.nat.hasExtIp or config.autonatServer,
    )

    network = BlockExcNetwork.new(switch)

    repoData =
      case config.repoKind
      of repoFS:
        Datastore(
          FSDatastore.new($config.dataDir, depth = 5).expect(
            "Should create repo file data store!"
          )
        )
      of repoSQLite:
        Datastore(
          SQLiteDatastore.new($config.dataDir).expect(
            "Should create repo SQLite data store!"
          )
        )
      of repoLevelDb:
        Datastore(
          LevelDbDatastore.new($config.dataDir).expect(
            "Should create repo LevelDB data store!"
          )
        )

    repoStore = RepoStore.new(
      repoDs = repoData,
      metaDs = LevelDbDatastore.new(config.dataDir / StorageMetaNamespace).expect(
          "Should create metadata store!"
        ),
      quotaMaxBytes = config.storageQuota,
      blockTtl = config.blockTtl,
    )

    maintenance = BlockMaintainer.new(
      repoStore,
      interval = config.blockMaintenanceInterval,
      numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks,
    )

    peerStore = PeerContextStore.new()
    downloadManager = DownloadManager.new(retries = config.blockRetries)
    advertiser = Advertiser.new(repoStore, discovery, peerInfo = switch.peerInfo)
    blockDiscovery = DiscoveryEngine.new(repoStore, peerStore, network, discovery)
    engine = BlockExcEngine.new(
      repoStore, network, blockDiscovery, advertiser, peerStore, downloadManager
    )
    store = NetworkStore.new(engine, repoStore)
    manifestProto = ManifestProtocol.new(switch, repoStore, discovery)

    storageNode = StorageNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      manifestProto = manifestProto,
      taskPool = taskPool,
    )

  switch.mount(network)
  switch.mount(manifestProto)
  switch.mount(discovery.kad)

  # NAT services
  var natMapper: Option[NatPortMapper]
  var autoRelayService: Option[AutoRelayService]
  var holePunchHandler: Option[connmanager.PeerEventHandler]

  if autonatService.isSome:
    let relayService = AutoRelayService.new(
      maxNumRelays = config.natMaxRelays,
      client = relayClient,
      onReservation = nil,
      rng = random.Rng.instance().libp2pRng,
    )

    relayService.setup(switch)
    autoRelayService = some(relayService)

    natMapper = some(
      NatPortMapper(
        natConfig: config.nat,
        tcpPort: config.listenPort,
        discoverTimeout: config.natPortMappingDiscoverTimeout,
        mappingTimeout: config.natPortMappingTimeout,
        recheckPeriod: config.natPortMappingRecheckPeriod,
      )
    )

    autonatService.get.setStatusAndConfidenceHandler(
      proc(
          networkReachability: NetworkReachability,
          confidence: Opt[float],
          addrs: Opt[MultiAddress],
      ) {.async: (raises: [CancelledError]).} =
        debug "AutoNAT status", reachability = networkReachability, confidence
        await natMapper.get.handleNatStatus(
          networkReachability, addrs, discovery, switch, relayService
        )
    )

    holePunchHandler = some(setupHolePunching(switch))

  # REST server
  var restServer: RestServerRef = nil

  if config.apiBindAddress.isSome:
    restServer = RestServerRef
      .new(
        storageNode.initRestApi(
          config, repoStore, autonatService, autoRelayService, natMapper,
          config.apiCorsAllowedOrigin,
        ),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskPool: taskPool,
    logFile: logFile,
    autonatService: autonatService,
    autoRelayService: autoRelayService,
    natMapper: natMapper,
    holePunchHandler: holePunchHandler,
    bootstrapNodes: bootstrapNodes,
  )
