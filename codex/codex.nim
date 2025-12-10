## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/strutils
import std/os
import std/tables
import std/cpuinfo
import std/net

import pkg/chronos
import pkg/taskpools
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/nitro
import pkg/stew/io2
import pkg/datastore
import pkg/ethers except Rng
import pkg/stew/io2

import ./node
import ./conf
import ./rng as random
import ./rest/api
import ./stores
import ./slots
import ./blockexchange
import ./utils/fileutils
import ./erasure
import ./discovery
import ./contracts
import ./systemclock
import ./contracts/clock
import ./contracts/deployment
import ./utils/addrutils
import ./namespaces
import ./codextypes
import ./logutils
import ./nat

logScope:
  topics = "codex node"

type
  CodexServer* = ref object
    config: CodexConf
    restServer: RestServerRef
    codexNode: CodexNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    isStarted: bool

  CodexPrivateKey* = libp2p.PrivateKey # alias
  EthWallet = ethers.Wallet

func config*(self: CodexServer): CodexConf =
  return self.config

func node*(self: CodexServer): CodexNodeRef =
  return self.codexNode

func repoStore*(self: CodexServer): RepoStore =
  return self.repoStore

proc waitForSync(provider: Provider): Future[void] {.async.} =
  var sleepTime = 1
  trace "Checking sync state of Ethereum provider..."
  while await provider.isSyncing:
    notice "Waiting for Ethereum provider to sync..."
    await sleepAsync(sleepTime.seconds)
    if sleepTime < 10:
      inc sleepTime
  trace "Ethereum provider is synced."

proc bootstrapInteractions(s: CodexServer): Future[void] {.async.} =
  ## bootstrap interactions and return contracts
  ## using clients, hosts, validators pairings
  ##
  let
    config = s.config
    repo = s.repoStore

  if config.persistence:
    if not config.ethAccount.isSome and not config.ethPrivateKey.isSome:
      error "Persistence enabled, but no Ethereum account was set"
      quit QuitFailure

    let provider = JsonRpcProvider.new(
      config.ethProvider, maxPriorityFeePerGas = config.maxPriorityFeePerGas.u256
    )
    await waitForSync(provider)
    var signer: Signer
    if account =? config.ethAccount:
      signer = provider.getSigner(account)
    elif keyFile =? config.ethPrivateKey:
      without isSecure =? checkSecureFile(keyFile):
        error "Could not check file permissions: does Ethereum private key file exist?"
        quit QuitFailure
      if not isSecure:
        error "Ethereum private key file does not have safe file permissions"
        quit QuitFailure
      without key =? keyFile.readAllChars():
        error "Unable to read Ethereum private key file"
        quit QuitFailure
      without wallet =? EthWallet.new(key.strip(), provider):
        error "Invalid Ethereum private key in file"
        quit QuitFailure
      signer = wallet

    let deploy = Deployment.new(provider, config.marketplaceAddress)
    without marketplaceAddress =? await deploy.address(Marketplace):
      error "No Marketplace address was specified or there is no known address for the current network"
      quit QuitFailure

    let marketplace = Marketplace.new(marketplaceAddress, signer)
    let market = OnChainMarket.new(
      marketplace, config.rewardRecipient, config.marketplaceRequestCacheSize
    )
    let clock = OnChainClock.new(provider)

    var client: ?ClientInteractions
    var host: ?HostInteractions
    var validator: ?ValidatorInteractions

    if config.validator or config.persistence:
      s.codexNode.clock = clock
    else:
      s.codexNode.clock = SystemClock()

    # This is used for simulation purposes. Normal nodes won't be compiled with this flag
    # and hence the proof failure will always be 0.
    when codex_enable_proof_failures:
      let proofFailures = config.simulateProofFailures
      if proofFailures > 0:
        warn "Enabling proof failure simulation!"
    else:
      let proofFailures = 0
      if config.simulateProofFailures > 0:
        warn "Proof failure simulation is not enabled for this build! Configuration ignored"

    if error =? (await market.loadConfig()).errorOption:
      fatal "Cannot load market configuration", error = error.msg
      quit QuitFailure

    let purchasing = Purchasing.new(market, clock)
    let sales = Sales.new(market, clock, repo, proofFailures)
    client = some ClientInteractions.new(clock, purchasing)
    host = some HostInteractions.new(clock, sales)

    if config.validator:
      without validationConfig =?
        ValidationConfig.init(
          config.validatorMaxSlots, config.validatorGroups, config.validatorGroupIndex
        ), err:
        error "Invalid validation parameters", err = err.msg
        quit QuitFailure
      let validation = Validation.new(clock, market, validationConfig)
      validator = some ValidatorInteractions.new(clock, validation)

    s.codexNode.contracts = (client, host, validator)

proc start*(s: CodexServer) {.async.} =
  if s.isStarted:
    warn "Codex server already started, skipping"
    return

  trace "Starting codex node", config = $s.config
  await s.repoStore.start()

  s.maintenance.start()

  await s.codexNode.switch.start()

  let (announceAddrs, discoveryAddrs) = nattedAddress(
    s.config.nat, s.codexNode.switch.peerInfo.addrs, s.config.discoveryPort
  )

  s.codexNode.discovery.updateAnnounceRecord(announceAddrs)
  s.codexNode.discovery.updateDhtRecord(discoveryAddrs)

  await s.bootstrapInteractions()
  await s.codexNode.start()

  if s.restServer != nil:
    s.restServer.start()

  s.isStarted = true

proc stop*(s: CodexServer) {.async.} =
  if not s.isStarted:
    warn "Codex is not started"
    return

  notice "Stopping codex node"

  var futures =
    @[
      s.codexNode.switch.stop(),
      s.codexNode.stop(),
      s.repoStore.stop(),
      s.maintenance.stop(),
    ]

  if s.restServer != nil:
    futures.add(s.restServer.stop())

  let res = await noCancel allFinishedFailed[void](futures)

  if res.failure.len > 0:
    error "Failed to stop codex node", failures = res.failure.len
    raiseAssert "Failed to stop codex node"

proc close*(s: CodexServer) {.async.} =
  var futures = @[s.codexNode.close(), s.repoStore.close()]

  let res = await noCancel allFinishedFailed[void](futures)

  if not s.taskpool.isNil:
    try:
      s.taskpool.shutdown()
    except Exception as exc:
      error "Failed to stop the taskpool", failures = res.failure.len
      raiseAssert("Failure in taskpool shutdown:" & exc.msg)

  if res.failure.len > 0:
    error "Failed to close codex node", failures = res.failure.len
    raiseAssert "Failed to close codex node"

proc shutdown*(server: CodexServer) {.async.} =
  await server.stop()
  await server.close()

proc new*(
    T: type CodexServer, config: CodexConf, privateKey: CodexPrivateKey
): CodexServer =
  ## create CodexServer including setting up datastore, repostore, etc
  let switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(config.listenAddrs)
    .withRng(random.Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  var
    cache: CacheStore = nil
    taskpool: Taskpool

  try:
    if config.numThreads == ThreadCount(0):
      taskpool = Taskpool.new(numThreads = min(countProcessors(), 16))
    else:
      taskpool = Taskpool.new(numThreads = int(config.numThreads))
    info "Threadpool started", numThreads = taskpool.numThreads
  except CatchableError as exc:
    raiseAssert("Failure in taskpool initialization:" & exc.msg)

  if config.cacheSize > 0'nb:
    cache = CacheStore.new(cacheSize = config.cacheSize)
    ## Is unused?

  let discoveryDir = config.dataDir / CodexDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    trace "Unable to create discovery directory for block store",
      discoveryDir = discoveryDir
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir
    )

  let
    discoveryStore = Datastore(
      LevelDbDatastore.new(config.dataDir / CodexDhtProvidersNamespace).expect(
        "Should create discovery datastore!"
      )
    )

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore,
    )

    wallet = WalletRef.new(EthPrivateKey.random())
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
      metaDs = LevelDbDatastore.new(config.dataDir / CodexMetaNamespace).expect(
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

    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new(retries = config.blockRetries)
    advertiser = Advertiser.new(repoStore, discovery)
    blockDiscovery =
      DiscoveryEngine.new(repoStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(
      repoStore, wallet, network, blockDiscovery, advertiser, peerStore, pendingBlocks
    )
    store = NetworkStore.new(engine, repoStore)
    prover =
      if config.prover:
        let backend =
          config.initializeBackend().expect("Unable to create prover backend.")
        some Prover.new(store, backend, config.numProofSamples)
      else:
        none Prover

    codexNode = CodexNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      prover = prover,
      taskPool = taskpool,
    )

  var restServer: RestServerRef = nil

  if config.apiBindAddress.isSome:
    restServer = RestServerRef
      .new(
        codexNode.initRestApi(config, repoStore, config.apiCorsAllowedOrigin),
        initTAddress(config.apiBindAddress.get(), config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  switch.mount(network)

  CodexServer(
    config: config,
    codexNode: codexNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskpool: taskpool,
  )
