## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/cpuinfo
import std/net
import std/os
import std/sequtils
import std/tables

import pkg/chronos
import pkg/confutils
import pkg/confutils/defs
import pkg/datastore
import pkg/libp2p
import pkg/libp2p/connmanager
import pkg/libp2p/multiaddress
import pkg/libp2p/protocols/connectivity/autonatv2/[service, client]
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/protocols/connectivity/relay/relay as relayModule
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/transports/tcptransport
import pkg/libp2p_mix
import pkg/libp2p_mix/pool
import pkg/presto
import pkg/taskpools

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
import ./systemclock
import ./naming/publisher
from ./naming/dht import NameRecordValidatorRef, NameRecordSelectorRef
import ./utils/addrutils
import ./utils/spr
import ./namespaces
import ./storagetypes
import ./logutils
import ./nat
import ./utils/natutils
import ./mix
import ./serviceproviders

logScope:
  topics = "storage node"

# A kad dial abandoned before stop can hold switch.stop for the whole dialer timeout.
const SwitchStopTimeout = 5.seconds

type
  StorageServer* = ref object
    config: StorageConf
    logFile*: Option[IoHandle]
    restServer: RestServerRef
    storageNode: StorageNodeRef
    repoStore: RepoStore
    namePublisher: NamePublisherRef
    maintenance: BlockMaintainer
    taskpool: Taskpool
    # Expose to make reachability accessible from rest api
    autonatService*: Option[AutonatV2Service]
    autoRelayService*: Option[AutoRelayService]
    natMapper*: Option[NatPortMapper]
    serviceProviders: Option[ServiceProviders]
    holePunchHandler: Option[connmanager.PeerEventHandler]
    bootstrapDials: Future[void].Raising([CancelledError])
    mixAddressObserver: PeerInfoObserver
    mixMapper: AddressMapper
    mixTransport: MixTransport
    isStarted: bool

  StoragePrivateKey* = libp2p.PrivateKey # alias

func config*(self: StorageServer): StorageConf =
  return self.config

func node*(self: StorageServer): StorageNodeRef =
  return self.storageNode

func repoStore*(self: StorageServer): RepoStore =
  return self.repoStore

func namePublisher*(self: StorageServer): NamePublisherRef =
  return self.namePublisher

proc enableMix(
    self: StorageServer
): Future[(MixProtocol, MixPool)] {.
    async: (raises: [CancelledError, StorageError, LPError])
.} =
  let
    switch = self.storageNode.switch
    (mixPub, mixPriv) = loadOrGenerateMixKeys(
      string(self.config.dataDir) / "mix-identity"
    ).valueOr:
      raise
        newException(StorageError, "Failed to load or generate Mix keys: " & error.msg)
    # We define a placeholder here.
    # The signed Mix address supplies the endpoint once the node publishes it.
    # For nat:auto, the node waits for AutoNAT to provide a reachable address or a relay address.
    # The Mix lookup will not be performed while the mixAddr value is mixUnsetMultiAddr().
    mixAddr = mixUnsetMultiAddr()
    mixNodeInfo = buildMixNodeInfo(
      mixPub, mixPriv, switch.peerInfo.peerId, mixAddr, switch.peerInfo.privateKey
    ).valueOr:
      raise newException(StorageError, "Failed to build Mix node info: " & error.msg)
    relayPool = (
      if self.config.mixPoolJson.len > 0:
        loadRelayPubInfoTableFromJson(self.config.mixPoolJson)
      else:
        loadRelayPubInfoTableFromFile(self.config.mixPool)
    ).valueOr:
      raise newException(StorageError, "Failed to load Mix relay pool: " & error.msg)
    mixProto = MixProtocol.new(mixNodeInfo, switch)

  info "Starting node with Mix relay pool", count = relayPool.len

  for info in relayPool.values:
    mixProto.nodePool.add(info)

  await mixProto.start()
  switch.mount(mixProto)

  (mixProto, relayPool)

proc startMixTransport*(
    s: StorageServer, mixProto: MixProtocol
) {.async: (raises: [CancelledError, StorageError]).} =
  if mixProto.isNil or not (s.config.mixEnabled or s.config.dhtProxyServer):
    return

  let mixTransport = newMixTransport(mixProto)
  (await mixTransport.start()).isOkOr:
    raise newException(StorageError, "Failed to start MixTransport: " & error)
  s.mixTransport = mixTransport

  if s.config.mixEnabled:
    let
      engine = s.storageNode.engine
      directNetwork = engine.contextFor(DownloadTransport.Direct).network
      mixPeerTransport = MixPeerTransport.new(mixTransport)
      mixNetwork = BlockExcNetwork.new(
        directNetwork.switch,
        mixPeerTransport,
        maxInflight = directNetwork.sendConcurrencyLimit,
      )
    engine.attach(
      BlockExcContext.new(mixNetwork, engine.localStore, engine.downloadManager)
    )
    s.storageNode.discovery.mixPeerTransport = mixPeerTransport

proc removeMixMapper(self: StorageServer) =
  let p = self.storageNode.switch.peerInfo
  if not self.mixMapper.isNil:
    p.addressMappers.keepItIf(it != self.mixMapper)
    self.mixMapper = nil

proc start*(self: StorageServer) {.async.} =
  if self.isStarted:
    warn "Storage server already started, skipping"
    return

  trace "Starting Storage node", config = $self.config
  await self.repoStore.start()

  self.maintenance.start()

  # Activate SO_REUSEPORT for hole punching in tcptransport.nim.
  # Without that, hole punching would use an ephemeral port assigned by the OS.
  # NotReachable has nothing to do with AutoNAT Reachability
  if self.holePunchHandler.isSome:
    for t in self.storageNode.switch.transports:
      t.networkReachability = NetworkReachability.NotReachable

  # Set the announcedAddrs BEFORE the switch starts so the Identity
  # push the correct address.
  if self.config.nat.hasExtIp and self.config.listenPort != Port(0):
    self.storageNode.switch.peerInfo.announcedAddrs =
      @[getMultiAddrWithIpAndTcpPort(self.config.nat.extIp, self.config.listenPort)]

  defer:
    if not self.isStarted:
      self.removeMixMapper()

  await self.storageNode.switch.start()

  var realPort = Port(0)

  for listenAddr in self.storageNode.switch.peerInfo.listenAddrs:
    let maybePort = getTcpPort(listenAddr)
    if maybePort.isSome:
      realPort = maybePort.get
      break

  if realPort == Port(0):
    raise newException(StorageError, "Failed to determine the real TCP port")

  let peerInfo = self.storageNode.switch.peerInfo
  if self.config.nat.hasExtIp:
    # extip means that we assume the IP is reachable.
    let extIpAddr = getMultiAddrWithIpAndTcpPort(self.config.nat.extIp, realPort)
    # Feed switch.peerInfo.addrs with extIp value only.
    # For example, we want to make sure that relay servers will
    # contain only the extIp, no private addresses.
    peerInfo.announcedAddrs = @[extIpAddr]
    # We force the update to take in consideration the announcedAddrs
    await peerInfo.update()

  if self.config.dhtProxyServer:
    let
      switch = self.storageNode.switch
      dhtProxyProto =
        if cap =? self.config.dhtProxyMaxInFlight:
          DhtProxyProtocol.new(self.storageNode.discovery, maxInFlight = cap)
        else:
          DhtProxyProtocol.new(self.storageNode.discovery)

    await dhtProxyProto.start()
    switch.mount(dhtProxyProto)

  if self.config.mixEnabled or self.config.dhtProxyServer:
    let (mixProto, relayPool) = await self.enableMix()

    self.storageNode.discovery.mixProto = mixProto
    self.storageNode.discovery.staticMixRelays = relayPool.keys.toSeq.toHashSet
    self.storageNode.engine.contextFor(DownloadTransport.Direct).network.excludeRelays(
      relayPool.keys.toSeq
    )

    if self.config.nat.hasExtIp:
      peerInfo.announcedAddrs =
        peerInfo.announcedAddrs.withMixAddress(mixProto, peerInfo.addressPolicy)
    else:
      self.mixMapper = mixProto.addressMapper(peerInfo.addressPolicy)
      peerInfo.addressMappers.add(self.mixMapper)
    await peerInfo.update()
    await self.startMixTransport(mixProto)

  if self.natMapper.isSome:
    self.natMapper.get.start()

  # When listenPort is 0 the OS assigns a random port.
  if self.natMapper.isSome and self.config.listenPort == Port(0):
    self.natMapper.get.tcpPort = realPort

  await self.storageNode.start()

  if self.config.nat.hasExtIp:
    self.storageNode.discovery.startAdvertisingServices()

  # Dial bootstrap and discovered AutoNAT servers without delaying startup.
  proc connectAutonatServer(record: PeerRecord) {.async: (raises: []).} =
    try:
      await self.storageNode.switch.connect(
        record.peerId, record.addresses.mapIt(it.address)
      )
    except CancelledError:
      discard
    except CatchableError as e:
      warn "Cannot connect to AutoNAT server", error = e.msg

  proc connectBootstrapPeers() {.async: (raises: [CancelledError]).} =
    let dials =
      self.storageNode.discovery.autonatServers().mapIt(connectAutonatServer(it))
    try:
      await allFutures(dials)
    except CancelledError as exc:
      await noCancel allFutures(dials.mapIt(it.cancelAndWait()))
      raise exc

    # The provider check can force a second outbound dial to an unconnected peer.
    if self.serviceProviders.isSome:
      self.serviceProviders.get.start()

  self.bootstrapDials = connectBootstrapPeers()

  try:
    # AutoNAT is not in switch.services because we want to start it
    # after starting the bootstrap connections for the first probe.
    if self.autonatService.isSome:
      await self.autonatService.get.start(self.storageNode.switch)

    self.namePublisher.start()

    if self.restServer != nil:
      self.restServer.start()

    self.isStarted = true
  finally:
    if not self.isStarted:
      await noCancel self.bootstrapDials.cancelAndWait()
      if self.serviceProviders.isSome:
        await noCancel self.serviceProviders.get.stop()

proc stop*(s: StorageServer) {.async.} =
  if not s.isStarted:
    warn "Storage is not started"
    return

  notice "Stopping Storage node"

  await s.bootstrapDials.cancelAndWait()

  if s.natMapper.isSome:
    s.natMapper.get.stop()

  if s.holePunchHandler.isSome:
    s.storageNode.switch.removePeerEventHandler(
      s.holePunchHandler.get, PeerEventKind.Joined
    )

  await s.namePublisher.stop()

  s.storageNode.discovery.mixPeerTransport = nil
  if not s.mixTransport.isNil:
    try:
      await s.mixTransport.stop()
    finally:
      await s.storageNode.engine.detach(DownloadTransport.Mix)
      s.mixTransport = nil

  proc stopSwitch(): Future[void] {.async: (raises: [CancelledError]).} =
    # We can't use withTimeout as it waits for cancellation of the wrapped future,
    # and the part of switch.stop that takes time is blocked on a noCancel.
    let
      stop = s.storageNode.switch.stop()
      timeout = race(stop, sleepAsync(SwitchStopTimeout))

    discard await timeout
    if not stop.finished():
      # XXX not sure this doesn't have any ill effects.
      warn "Switch stop timed out, continuing", timeout = SwitchStopTimeout

  var futures =
    @[stopSwitch(), s.storageNode.stop(), s.repoStore.stop(), s.maintenance.stop()]

  if s.autoRelayService.isSome and s.autoRelayService.get.isRunning:
    proc stopAutoRelay(): Future[void] {.async: (raises: []).} =
      await noCancel s.autoRelayService.get.stop(s.storageNode.switch)

    futures.add(stopAutoRelay())

  if s.autonatService.isSome:
    futures.add(s.autonatService.get.stop(s.storageNode.switch))

  if s.serviceProviders.isSome:
    futures.add(s.serviceProviders.get.stop())

  if s.restServer != nil:
    futures.add(s.restServer.stop())

  let res = await noCancel allDone[void](futures)

  s.removeMixMapper()
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
  if not s.mixAddressObserver.isNil:
    s.storageNode.switch.peerInfo.removeObserver(s.mixAddressObserver)
    s.mixAddressObserver = nil
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

  let bootstrapNodes = config.bootstrapNodes
  if bootstrapNodes.len == 0:
    warn "Node has no bootstrap node and will NOT be bootstrapped"

  var autonatConfig = none(AutonatV2ServiceConfig)
  if config.autonatServer:
    info "AutoNAT server enabled"
    switchBuilder = switchBuilder.withAutonatV2Server()
  elif not config.nat.hasExtIp:
    info "AutoNAT client enabled", scheduleInterval = config.natScheduleInterval
    autonatConfig = some(
      AutonatV2ServiceConfig.new(
        scheduleInterval = Opt.some(config.natScheduleInterval),
        enableDialableCandidates = true,
      )
    )

    let observedAddrMinCount = min(config.natObservedAddrMinCount, bootstrapNodes.len)
    switchBuilder = switchBuilder.withAddressManager(
      AddressManagerConfig(minCount: observedAddrMinCount)
    )
    # libp2p keeps the private address in peerInfo.addrs.
    # Since Autonat V2 uses the observed public address,
    # we can filter the private addresses to keep only the dialable
    # addresses.
    switchBuilder = switchBuilder.withAddressPolicy(dialableMixAddressPolicy)

  let switch = switchBuilder
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  var taskPool: Taskpool

  # Own AutoNAT so it starts after bootstrap dials have been scheduled.
  # The AddressManager retries verification when peers are identified; startup
  # does not need to wait for unreachable bootstrap nodes.
  let autonatService: Option[AutonatV2Service] =
    if autonatConfig.isSome:
      let client = AutonatV2Client.new(switch.rng)
      client.setup(switch)
      switch.mount(client)
      let service = AutonatV2Service.new(switch.rng, client, autonatConfig.get)
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

  var networkAddrs = bootstrapNodes.mapIt(it.toPeerIdAndAddrs()[1]).concat()
  if config.nat.hasExtIp:
    networkAddrs.add(getMultiAddrWithIpAndTcpPort(config.nat.extIp, config.listenPort))

  var kadAddressPolicy: PeerAddressPolicy = defaultAddressPolicy

  # If the network is public, use dialable mix address policy to filter
  # out private addresses and UDP addresses.
  if isPublicNetwork(networkAddrs):
    kadAddressPolicy = dialableMixAddressPolicy

  let
    clock = SystemClock.new()
    discovery = Discovery.new(
      switch,
      bootstrapNodes = bootstrapNodes.mapIt(it.toPeerIdAndAddrs()),
      dhtMixProxies = config.dhtMixProxies,
      isServer = config.nat.hasExtIp or config.autonatServer,
      addressPolicy = kadAddressPolicy,
      providedServices = providedServices(
        config.autonatServer,
        config.isRelayServer,
        mixRelay = config.mixEnabled and config.nat.hasExtIp,
        dhtProxyServer = config.dhtProxyServer,
      ),
      serviceLookupInterval = config.natScheduleInterval,
      validator = NameRecordValidatorRef(clock: clock),
      selector = NameRecordSelectorRef(),
    )

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

    namePublisher =
      NamePublisherRef.new(discovery, repoStore.metaDs.ds, privateKey, clock)

    maintenance = BlockMaintainer.new(
      repoStore,
      interval = config.blockMaintenanceInterval,
      numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks,
    )

    downloadManager = DownloadManager.new(retries = config.blockRetries)
    advertiser = Advertiser.new(
      repoStore,
      discovery,
      peerInfo = switch.peerInfo,
      autonat = autonatService,
      advertiseContent = config.advertiseContent,
    )
    blockDiscovery = DiscoveryEngine.new(discovery)
    engine = BlockExcEngine.new(repoStore, blockDiscovery, advertiser, downloadManager)
    store = NetworkStore.new(engine, repoStore)
    manifestProto = ManifestProtocol.new(repoStore, discovery)

    storageNode = StorageNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      manifestProto = manifestProto,
      taskPool = taskPool,
    )

  engine.attach(
    BlockExcContext.new(
      BlockExcNetwork.new(switch, DirectPeerTransport.new(switch)),
      repoStore,
      downloadManager,
    )
  )
  switch.mount(engine.newBlockExcProtocol())
  switch.mount(manifestProto)
  switch.mount(discovery.kad)
  switch.mount(discovery.serviceDiscovery)

  # NAT services
  var natMapper: Option[NatPortMapper]
  var autoRelayService: Option[AutoRelayService]
  var holePunchHandler: Option[connmanager.PeerEventHandler]
  let serviceProviders = ServiceProviders.new(config.natScheduleInterval)

  if autonatService.isSome:
    let relayService = AutoRelayService.new(
      maxNumRelays = config.natMaxRelays,
      client = relayClient,
      onReservation = nil,
      rng = random.Rng.instance().libp2pRng,
    )

    autoRelayService = some(relayService)

    proc refreshAutonatServers() {.async: (raises: [CancelledError]).} =
      (await discovery.findServiceProviders(AutonatServiceId)).isOkOr:
        warn "Unable to find AutoNAT servers", err = error

      await connectMissing(
        discovery,
        switch,
        AutonatServiceId,
        discovery.autonatServers(),
        config.natNumPeersToAsk - switch.countAutonatHelpers(),
      )

    proc refreshCircuitRelayServers() {.async: (raises: [CancelledError]).} =
      (await discovery.findServiceProviders(CircuitRelayServiceId)).isOkOr:
        warn "Unable to find circuit relay servers", err = error

      await connectMissing(
        discovery,
        switch,
        CircuitRelayServiceId,
        discovery.circuitRelayServers(),
        config.natMaxRelays - relayPeers(relayService.getAddresses()).len,
      )

    serviceProviders.add(
      RequiredService.new(
        AutonatServiceId,
        proc(): bool =
          switch.countAutonatHelpers() < config.natNumPeersToAsk,
        refreshAutonatServers,
      )
    )
    serviceProviders.add(
      RequiredService.new(
        CircuitRelayServiceId,
        proc(): bool =
          relayService.isRunning and
            relayPeers(relayService.getAddresses()).len < config.natMaxRelays,
        refreshCircuitRelayServers,
      )
    )

    natMapper = some(
      NatPortMapper(
        natConfig: config.nat,
        tcpPort: config.listenPort,
        discoverTimeout: config.natPortMappingDiscoverTimeout,
        mappingTimeout: config.natPortMappingTimeout,
        recheckPeriod: config.natPortMappingRecheckPeriod,
      )
    )

    discard autonatService.get.reachabilityObservers.add(
      proc(
          networkReachability: NetworkReachability,
          confidence: Opt[float],
          addrs: Opt[MultiAddress],
      ) {.async: (raises: [CancelledError]).} =
        debug "AutoNAT status", reachability = networkReachability, confidence
        await natMapper.get.handleNatStatus(
          networkReachability, addrs, discovery, switch, relayService
        )
        engine.advertiser.onAddrChange()
        serviceProviders.check()
    )

    holePunchHandler = some(setupHolePunching(switch))

  if config.mixEnabled:
    let directNetwork = engine.contextFor(DownloadTransport.Direct).network

    proc refreshMixRelays() {.async: (raises: [CancelledError]).} =
      let relays = (await discovery.findMixRelays()).valueOr:
        warn "Unable to find Mix relays", err = error
        return

      let
        nodePool = discovery.mixProto.nodePool
        discovered = relays.mapIt(it.peerId)

      for peer in nodePool.peerIds:
        if peer notin discovery.staticMixRelays and peer notin discovered:
          discard nodePool.remove(peer)

      for relay in relays:
        if relay.peerId in discovery.staticMixRelays:
          continue

        let existing = nodePool.get(relay.peerId)
        if existing.isNone:
          nodePool.add(relay)
          # directNetwork.excludeRelays([relay.peerId])
        elif existing.get.multiAddr != relay.multiAddr or
            existing.get.mixPubKey != relay.mixPubKey:
          nodePool.add(relay)

      if nodePool.len < MinMixRelays:
        warn "Not enough Mix relays to build a path",
          relays = nodePool.len, min = MinMixRelays

    proc refreshDhtMixProxies() {.async: (raises: [CancelledError]).} =
      (await discovery.findServiceProviders(DhtProxyServiceId)).isOkOr:
        warn "Unable to find DHT Mix proxies", err = error

    serviceProviders.add(
      RequiredService.new(
        MixServiceId,
        proc(): bool =
          true,
        refreshMixRelays,
      )
    )
    serviceProviders.add(
      RequiredService.new(
        DhtProxyServiceId,
        proc(): bool =
          true,
        refreshDhtMixProxies,
      )
    )

  # REST server
  var restServer: RestServerRef = nil

  if config.apiBindAddress.isSome:
    restServer = RestServerRef
      .new(
        storageNode.initRestApi(
          config, repoStore, namePublisher, autonatService, autoRelayService, natMapper,
          config.apiCorsAllowedOrigin,
        ),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  result = StorageServer(
    config: config,
    storageNode: storageNode,
    restServer: restServer,
    repoStore: repoStore,
    namePublisher: namePublisher,
    maintenance: maintenance,
    taskPool: taskPool,
    logFile: logFile,
    autonatService: autonatService,
    autoRelayService: autoRelayService,
    natMapper: natMapper,
    serviceProviders:
      if serviceProviders.hasRequiredServices:
        some(serviceProviders)
      else:
        ServiceProviders.none,
    holePunchHandler: holePunchHandler,
    bootstrapDials: Future[void].Raising([CancelledError])(),
    mixTransport: nil,
  )

  # PeerInfo calls observers synchronously in registration order after signing.
  # Register before callers or switch services can subscribe to address changes.
  if config.mixEnabled or config.dhtProxyServer:
    result.mixAddressObserver = discovery.mixAddressObserver()
    switch.peerInfo.addObserver(result.mixAddressObserver)
