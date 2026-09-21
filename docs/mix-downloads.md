# Direct and Mix downloads

This walkthrough follows a download from the REST transport choice to manifest retrieval, provider selection, BlockExchange connections, and the stream returned to the caller. The connection-management sections explain the protocol instances that carry that work. File paths are relative to the Storage repository unless stated otherwise. Excerpts retain function signatures and identify omitted code; they are reading aids rather than standalone examples.

## Choosing how a download contacts providers

`mixEnabled` enables the node's Mix services. A download independently selects the connection type used for its manifest and blocks. The choice is represented by `DownloadTransport`, defined in `storage/downloadtransport.nim`:

```nim
type DownloadTransport* {.pure.} = enum
  Direct
  Mix
```

Direct is the default, including on a node with Mix enabled. The network download endpoints accept `?transport=direct` or `?transport=mix`:

- `POST /api/storage/v1/data/{cid}/network` starts a background download.
- `GET /api/storage/v1/data/{cid}/network/stream` streams the dataset.
- `GET /api/storage/v1/data/{cid}/network/manifest` fetches only the manifest.

The REST endpoints call the parser in `storage/downloadtransport.nim`:
```nim
func parseDownloadTransport*(value: string): Result[DownloadTransport, string] =
  case value
  of "direct":
    ok(DownloadTransport.Direct)
  of "mix":
    ok(DownloadTransport.Mix)
  else:
    err("transport must be 'direct' or 'mix'")
```

An unrecognized value produces HTTP 400. A Mix request fails if Mix is not enabled; the request does not fall back to direct dialing. Existing internal callers that omit the parameter select Direct. The C-library download API does not expose this parameter. Discovery's DHT proxy selection is configured independently.

## From the API to a download

### Parse once and use the same choice for manifest and blocks

The background-download route in `storage/rest/api.nim` first reads the query parameter, then fetches the manifest, and finally starts the block download. The route callback is registered through `router.api`, rather than being a named procedure. This excerpt includes that callback's declaration and the operations relevant to transport selection; CID validation, logging, CORS setup, and final response construction are omitted:

```nim
router.api(MethodPost, "/api/storage/v1/data/{cid}/network") do(
    cid: Cid, resp: HttpResponseRef
) -> RestApiResponse:
  # CORS setup omitted; headers is established there.
  let transport = parseDownloadTransport(
    request.query.getString("transport", "direct")
  ).valueOr:
    return RestApiResponse.error(Http400, error, headers = headers)

  # CID validation omitted.
  without manifest =? (await node.fetchManifest(cid.get(), transport)), err:
    return RestApiResponse.error(Http404, err.msg, headers = headers)

  let md = ManifestDescriptor(manifest: manifest, manifestCid: cid.get())
  without downloadId =? (
    await node.startBackgroundDownload(
      md, selectionPolicy = spRandomWindow, transport = transport
    )
  ), err:
    return RestApiResponse.error(Http409, err.msg, headers = headers)
  # Success response construction follows.
```

The `transport` variable is used in both calls. A successful Mix manifest fetch does not leave the block-download step to infer a transport from node configuration.

The node's manifest entry point delegates to `ManifestProtocol`:

```nim
proc fetchManifest*(
    self: StorageNodeRef,
    cid: Cid,
    transport: DownloadTransport = DownloadTransport.Direct,
): Future[?!Manifest] {.async: (raises: [CancelledError]).}
```

The provider-address section below follows the delegated manifest request through discovery and dialing. For now, the important output is the manifest: its descriptor tells the block-download engine which tree and blocks to fetch.

### Reuse only a background download with the same transport

The second call enters `startBackgroundDownload` in `storage/node.nim`:

```nim
proc startBackgroundDownload*(
    self: StorageNodeRef,
    md: ManifestDescriptor,
    selectionPolicy: SelectionPolicy = spSequential,
    transport: DownloadTransport = DownloadTransport.Direct,
): Future[?!uint64] {.async: (raises: [CancelledError]).} =
  let
    treeCid = md.manifest.treeCid
    existing = self.engine.downloadManager.getBackgroundDownload(treeCid, transport)

  if existing.isSome:
    return success(existing.get().id)

  let
    download = ?self.engine.startTreeDownloadOpaque(
      md, selectionPolicy = selectionPolicy, isBackground = true, transport = transport
    )
    downloadId = download.downloadId

  proc waitForCompleteTask(): Future[void] {.async: (raises: []).} =
    try:
      discard await download.waitForComplete()
    except CancelledError:
      trace "Background download cancelled", treeCid = treeCid, downloadId
    finally:
      self.engine.releaseDownload(download)

  self.trackedFutures.track(waitForCompleteTask())
  return success(downloadId)
```

Before creating a worker, the node asks `DownloadManager.getBackgroundDownload` whether an appropriate download is already running. The lookup examines both the tree CID and transport:

```nim
proc getBackgroundDownload*(
    self: DownloadManager,
    treeCid: Cid,
    transport: DownloadTransport = DownloadTransport.Direct,
): Option[ActiveDownload] =
  self.downloads.withValue(treeCid, innerTable):
    for _, download in innerTable[]:
      if download.isBackground and download.ctx.transport == transport:
        return some(download)
  return none(ActiveDownload)
```

Thus, another request for the same tree over Mix can reuse an existing Mix background download, but cannot reuse a Direct download of that tree. Both downloads still belong to one download manager and receive IDs from the same manager.

When a new download is necessary, `startTreeDownloadOpaque` creates it and returns a handle. The nested `waitForCompleteTask` owns the background wait and releases that handle when the wait ends, including cancellation. The REST caller receives the download ID without waiting for all blocks.

### Retain the transport choice in the download context

The engine's `toDownloadDesc` constructs a `DownloadDesc` containing the selected transport. `DownloadContext.new` then copies that field into the state retained for the download. The relevant constructor excerpt from `engine/downloadcontext.nim` is:

```nim
proc new*(
    T: type DownloadContext, desc: DownloadDesc, missingBlocks: seq[uint64] = @[]
): DownloadContext =
  # Manifest validation and block/window-size calculations omitted.
  result = DownloadContext(
    transport: desc.transport,
    md: desc.md,
    totalBlocks: totalBlocks,
    scheduler: Scheduler.new(),
    swarm: Swarm.new(),
  )
  # Availability-tracker initialization follows.
```

The worker later reads `download.ctx.transport` whenever it selects the protocol instance and scheduling state. The following sections explain those objects before returning to provider discovery and stream reads.

## Keeping peer connections separate

### Independent Direct and Mix protocol instances

`BlockExcNetwork` implements the BlockExchange libp2p protocol and inherits from `LPProtocol`. Each instance owns its peers, sending connections, message callbacks, and send-concurrency limit. The relevant declarations in `storage/blockexchange/network/network.nim` are:

```nim
BlockExcNetwork* = ref object of LPProtocol
  peers*: Table[PeerId, NetworkPeer]
  switch*: Switch
  handlers*: BlockExcHandlers
  # Other request, concurrency, and lifecycle fields omitted.
  mixTransport: MixTransport

BlockExcNetworks* = ref object
  direct*: BlockExcNetwork
  mix*: BlockExcNetwork
  dispatchProtocol*: LPProtocol
```

`BlockExcNetworks` is the shared holder passed to discovery and the engine. The `direct` field refers to the Direct protocol instance. The `mix` field is nil when Mix is disabled; startup creates a Mix instance only after MixTransport exists. Neither protocol instance owns the other. The holder's `dispatchProtocol` field is the single mounted entry point that selects which instance handles an incoming connection.

Separate peers are important even when both downloads contact the same provider. `NetworkPeer` retains a sending connection, so sharing one peer object would allow a Mix download to reuse a Direct connection, or the reverse:

```text
networks.direct.peers[providerId] -> Direct peer and sending connection
networks.mix.peers[providerId]    -> Mix peer and sending connection
```

### Construction before Mix startup

`StorageServer.new`, in `storage/storage.nim`, creates the Direct instance and the holder. The following excerpt omits Switch, store, and other service construction, but retains the declarations and calls that establish ownership:

```nim
proc new*(
    T: type StorageServer,
    config: StorageConf,
    privateKey: StoragePrivateKey,
    logFile: Option[IoHandle] = IoHandle.none,
): StorageServer =
  # Switch and other service construction omitted.
  let
    directNetwork = BlockExcNetwork.new(switch)
    networks = newBlockExcNetworks(directNetwork)
    # Store and supporting service construction omitted.
    blockDiscovery = DiscoveryEngine.new(peerStore, networks, discovery)
    engine = BlockExcEngine.new(
      repoStore, networks, blockDiscovery, advertiser, peerStore, downloadManager
    )
  # Other construction omitted.
  switch.mount(networks.dispatchProtocol)
```

Discovery and the engine retain the same holder, not copies of its fields. Adding the Mix instance during startup therefore makes that instance available to both consumers. With Mix disabled, the holder continues to contain only Direct.

The individual protocol constructor accepts the transport service at construction:

```nim
proc new*(
    T: type BlockExcNetwork,
    switch: Switch,
    connProvider: ConnProvider = nil,
    maxInflight = DefaultMaxInflight,
    mixTransport: MixTransport = nil,
): BlockExcNetwork
```

Without `mixTransport`, the constructor creates Direct and subscribes to Switch peer events. With a non-nil `mixTransport`, the constructor creates Mix and subscribes to that service's session events. A Mix instance therefore has its transport service from construction onward; there is no unattached Mix instance waiting to become usable.

Internal decisions use a small helper whose only source of truth is the service reference:

```nim
func isMixDownload*(self: BlockExcNetwork): bool =
  ## Whether this protocol instance handles downloads through MixTransport.
  not self.mixTransport.isNil
```

The helper describes the protocol instance, not a node-wide setting. `DownloadTransport` still represents each download's selected transport and is used by the engine and discovery to select an instance from the holder.

### Creating Mix and installing the engine callbacks

During startup, `StorageServer.start` creates the Mix protocol, then calls `startMixTransport`:

```nim
proc startMixTransport*(
    s: StorageServer, mixProto: MixProtocol
) {.async: (raises: [CancelledError, StorageError]).} =
  if not s.config.mixEnabled or mixProto.isNil:
    return

  let mixTransport = newMixTransport(mixProto)
  s.storageNode.engine.enableMixNetwork(mixTransport)
  s.storageNode.manifestProtocol.attachMixTransport(mixTransport)
  (await mixTransport.start()).isOkOr:
    await s.storageNode.engine.disableMixNetwork()
    s.storageNode.manifestProtocol.detachMixTransport()
    raise newException(StorageError, "Failed to start MixTransport: " & error)
  s.mixTransport = mixTransport
```

BlockExchange and Manifest receive the same MixTransport service. Manifest retains its own attachment API. For BlockExchange, `enableMixNetwork` in `storage/blockexchange/engine/engine.nim` constructs an independent protocol instance, installs its engine callbacks, and publishes that instance through the shared holder:

```nim
proc enableMixNetwork*(self: BlockExcEngine, mixTransport: MixTransport) =
  doAssert not mixTransport.isNil
  doAssert self.networks.mix.isNil, "Mix BlockExchange is already enabled"
  let network = BlockExcNetwork.new(
    self.networks.direct.switch,
    maxInflight = self.networks.direct.sendConcurrencyLimit,
    mixTransport = mixTransport,
  )
  self.configureNetwork(network, DownloadTransport.Mix)
  self.networks.mix = network
```

The `sendConcurrencyLimit` accessor returns the Direct instance's configured maximum number of concurrent sends. Passing that value to the Mix constructor preserves the same configured limit, but each instance has its own semaphore: Direct sends do not occupy Mix send slots.

`configureNetwork` binds message and peer-lifecycle callbacks to the chosen transport. The engine constructor calls the same helper for Direct. For example, the presence callback installed by the helper is:

```nim
proc configureNetwork(
    self: BlockExcEngine, network: BlockExcNetwork, transport: DownloadTransport
) =
  # Other callbacks omitted.
  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.blockPresenceHandler(peer, presence, transport)

  # network.handlers receives this callback and the other handlers.
```

The callback captures `transport`. A presence message decoded by the Mix instance consequently reaches the engine with `DownloadTransport.Mix`; the Direct instance's callback supplies `DownloadTransport.Direct`. No extra transport field is needed in the BlockExchange message.

There is no `await` between creating the Mix instance, configuring its callbacks, and assigning `networks.mix`. Startup completes this wiring before awaiting MixTransport startup. If startup fails, `disableMixNetwork` removes the instance from the holder, unregisters its session callback through `network.stop()`, and clears the engine's Mix peer state. Normal server shutdown stops MixTransport first, allowing session-closed events to run, then removes the Mix protocol instance.

### Mix session events and Direct peer events

The Mix protocol constructor calls `subscribeMixSessions` in `storage/blockexchange/network/network.nim`. That procedure installs a callback on the instance's MixTransport service:

```nim
proc subscribeMixSessions(self: BlockExcNetwork) =
  proc sessionEventHandler(
      event: SessionEvent
  ): Future[void] {.async: (raises: [CancelledError]).} =
    case event.kind
    of SessionEventKind.Established:
      await self.registerPeer(event.peerId)
    of SessionEventKind.Closed:
      await self.unregisterPeer(event.peerId)

  self.mixSessionEventHandler = sessionEventHandler
  self.mixTransport.addSessionEventHandler(sessionEventHandler)
```

Registration does not establish a session or add a remote peer. Later, an `Established` event creates or retrieves the Mix `NetworkPeer` and invokes the engine's Mix peer-joined callback. A `Closed` event removes the Mix peer and retained session entries and invokes the corresponding peer-departed callback.

This callback handles MixTransport session events on both endpoints. For a session that node A initiates with node B:

- On A, the event carries B's real peer ID. A registers B in its Mix peer table.
- On B, the event carries the anonymous session ID representing A. B registers that anonymous identity in its Mix peer table.

Direct membership follows a separate callback registered by the Direct instance's `init` method with the Switch. That callback receives Switch `Joined` and `Left` events. A physical Switch connection to a Mix relay does not therefore create a Mix BlockExchange peer: only a MixTransport application session produces that Mix peer-lifecycle notification.

### Dispatching incoming connections through one mounted codec

The holder constructor creates the mounted entry point. This entry point has no peer table of its own; its handler chooses a protocol instance:

```nim
proc newBlockExcNetworks*(direct: BlockExcNetwork): BlockExcNetworks =
  doAssert not direct.isMixDownload
  let self = BlockExcNetworks(direct: direct)
  proc dispatch(
      conn: Connection, codec: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    let network = if conn of TransportStream: self.mix else: self.direct
    if network.isNil:
      await conn.close()
      return
    await network.handleConnection(conn)

  self.dispatchProtocol = lp_protocol.new(
    LPProtocol, @[Codec], dispatch, maxIncomingStreamsTotal = direct.maxInflight
  )
  self
```

Ordinary libp2p protocol selection invokes this handler with an ordinary connection. MixTransport instead finds the BlockExchange codec in the Switch's protocol registry and invokes the same handler with a `TransportStream`. Both connection types satisfy the `Connection` parameter.

The type check selects Mix for a `TransportStream` and Direct otherwise. If Mix is absent, an incoming `TransportStream` is closed; the dispatcher does not pass that stream to Direct. Because Storage mounts only `networks.dispatchProtocol`, both incoming paths use that entry point's incoming-stream quota.

After dispatch, `handleConnection` selects a peer in the chosen instance and starts the peer's read loop:

```nim
proc handleConnection(
    self: BlockExcNetwork, conn: Connection
) {.async: (raises: [CancelledError]).} =
  if (conn of TransportStream) != self.isMixDownload:
    await conn.close()
    return
  let peer = self.getOrCreatePeer(conn.peerId)
  await peer.readLoop(conn)
```

The additional type check protects calls made through an individual instance's own protocol handler, outside the holder's dispatcher. The original connection is neither copied nor converted. On a Mix recipient, `conn.peerId` is the anonymous session identity; on the initiator, the identity is the real destination peer ID.

### From the selected peer to message processing

`handleConnection` calls `getOrCreatePeer`. For a new peer, that procedure creates callbacks bound to the owning protocol instance:

```nim
proc getOrCreatePeer(self: BlockExcNetwork, peer: PeerId): NetworkPeer =
  # Existing-peer lookup and connection-provider construction omitted.
  let rpcHandler = proc(p: NetworkPeer, msg: Message) {.async: (raises: []).} =
    await self.rpcHandler(p, msg)
  # Remaining callbacks and NetworkPeer construction omitted.
```

A peer created by the Mix instance sends decoded messages to that instance's `rpcHandler`. The handler then calls the engine callbacks installed by `configureNetwork`, which supply the Mix transport choice. Direct follows the corresponding Direct path.

### Selecting the protocol instance for outgoing work

For outgoing work, the download already contains its transport choice. The engine and discovery select from the shared holder using:

```nim
func networkFor*(
    self: BlockExcNetworks, transport: DownloadTransport
): BlockExcNetwork =
  case transport
  of DownloadTransport.Direct: self.direct
  of DownloadTransport.Mix: self.mix
```

A missing Mix instance returns nil, not Direct. The engine rejects a new Mix download when Mix is unavailable, and discovery skips provider dialing if the selected instance is absent.

Once an instance is selected, its peer's connection provider calls either `Switch.dial` or `MixTransport.dial`. The later section “Sending replies from the anonymous recipient” shows that callback and follows sending-connection reuse.

### Selecting engine peer state

The separation also extends to the BlockExchange engine, which keeps information used to schedule requests. A peer context contains the peer's performance statistics and a flag indicating whether a want-list operation is busy. An in-flight request tracker records unfinished requests for each peer so the engine can determine how many requests are already outstanding. The engine keeps separate Direct and Mix versions of both stores. Consequently, a slow Mix transfer to a provider does not alter the performance statistics or outstanding-request count used for a Direct transfer to that same provider.

The data structures make those responsibilities explicit. `peers/peercontext.nim` defines:

```nim
type PeerContext* = ref object of RootObj
  id*: PeerId
  stats*: PeerPerfStats
  wantListBusy*: bool
```

The request tracker in `engine/peertracker.nim` stores futures for outstanding work:

```nim
type PeerInFlightTracker* = ref object
  peerInFlight*: Table[PeerId, seq[Future[void]]]
```

In `engine/engine.nim`, the engine selects the appropriate stores through these functions:

```nim
func peersFor*(self: BlockExcEngine, transport: DownloadTransport): PeerContextStore =
  if transport == DownloadTransport.Mix: self.mixPeers else: self.peers

func trackerFor(
    self: BlockExcEngine, transport: DownloadTransport
): PeerInFlightTracker =
  if transport == DownloadTransport.Mix:
    self.mixPeerTracker
  else:
    self.downloadManager.peerTracker
```

The Direct tracker lives in `downloadManager.peerTracker`; the Mix tracker lives in `mixPeerTracker`. Both implement the same tracking operations.

### Removing the departed peer's transport-specific state

MixTransport shuts down a session before publishing its `Closed` session event. In `libp2p_mix_transport/transport.nim`, the teardown operation has the following order:

```nim
proc removeAndShutdownSession(
    self: MixTransport, session: TransportSession
) {.async: (raises: [CancelledError]).} =
  self.addressDestinations.del(session.sessionId)
  discard self.sessions.remove(session.sessionId)
  discard self.replyCredentials.removeSession(session.sessionId)
  await session.shutdown()
  await self.publishSessionEvent(session, SessionEventKind.Closed)
```

`session.shutdown` closes the session's streams and waits for their transport-owned tasks and protocol handlers to finish. Closing those connections also causes BlockExchange's read loops to exit. The cleanup in `NetworkPeer.readLoop` completes pending block-request futures with a `ConnectionClosed` error, allowing their callers to handle the failed requests. A download can continue by requesting its missing blocks from other peers.

The Mix session-event callback then notifies the engine that the Mix peer has departed. The engine removes that peer's Mix context and request-tracker entries so subsequent scheduling no longer uses the departed peer's old state. Application tasks may still be handling the reported request failures; the tracker cleanup does not wait for that higher-level processing. The same provider's Direct context, request-tracker entries, and connection are unaffected.

The engine constructor installs `mixPeerDeparted` as the Mix protocol instance's `onPeerDeparted` callback:

```nim
proc mixPeerDeparted(peer: PeerId) {.async: (raises: [CancelledError]).} =
  self.evictPeer(peer, DownloadTransport.Mix)
```

The callback passes the transport choice explicitly to `evictPeer`. That procedure uses the selection functions above:

```nim
proc evictPeer(self: BlockExcEngine, peer: PeerId, transport: DownloadTransport) =
  trace "Evicting disconnected/departed peer", peer
  self.peersFor(transport).remove(peer)
  self.trackerFor(transport).clearPeer(peer)
```

The tracker's cleanup operation is simply:

```nim
proc clearPeer*(self: PeerInFlightTracker, peerId: PeerId) =
  self.peerInFlight.del(peerId)
```

None of these operations selects the Direct store when the callback supplies `DownloadTransport.Mix`.

### Connecting the download context to its swarm

A swarm is the set of peers selected for one download. The download already records whether it uses Direct or Mix, and the engine uses that choice to select the appropriate protocol instance, peer-context store, and request tracker. A Mix download therefore interprets every peer in its swarm as a Mix peer; a Direct download interprets every peer as a Direct peer.

The relevant fields of `DownloadContext`, declared in `engine/downloadcontext.nim`, are:

```nim
DownloadContext* = ref object
  transport*: DownloadTransport
  # Other download state omitted.
  swarm*: Swarm
```

At the start of `downloadWorker` in `engine/engine.nim`, the same context value selects all three objects used to communicate and schedule work. This excerpt shows the procedure's signature and initial selection; the scheduling loop follows in the implementation:

```nim
proc downloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).} =
  let
    treeCid = download.treeCid
    retryInterval = self.downloadManager.retryInterval
    peers = self.peersFor(download.ctx.transport)
    network = self.networks.networkFor(download.ctx.transport)
    peerTracker = self.trackerFor(download.ctx.transport)
  # Logging and the scheduling loop follow.
```

The swarm itself, declared in `engine/swarm.nim`, therefore needs no separate transport component in its peer-table keys:

```nim
Swarm* = ref object
  config*: SwarmConfig
  peers: Table[PeerId, SwarmPeer]
  removedPeers: HashSet[PeerId]
```

For example, two downloads may both include provider P: the Direct download uses P's Direct connection and context, while the Mix download uses P's Mix connection and context. Each swarm can store P using its `PeerId` alone, because the owning download supplies the transport choice. There is no need to store a `(PeerId, transport)` pair for every swarm member.

There is one shared limit to distinguish from this separate state: both incoming paths use the mounted `networks.dispatchProtocol` entry point's incoming-stream reservations. The independent protocol instances do not create separate mounted quotas.

## Sending replies from the anonymous recipient

BlockExchange uses a retained outgoing connection for presence messages. This is now the same policy for Direct and Mix peers. An incoming stream runs the protocol's read loop; it is not automatically adopted as the peer's outgoing connection.

### Installing the peer's connection provider

The default Direct/Mix dialing choice is made inside `getOrCreatePeer` in `storage/blockexchange/network/network.nim`:

```nim
proc getOrCreatePeer(self: BlockExcNetwork, peer: PeerId): NetworkPeer
```

If the peer already exists in this protocol instance's table, the procedure returns that peer. For a new peer, the procedure creates the following `getConn` callback. `ConnProvider` is the callback type through which `NetworkPeer` asks for a connection; the callback captures the owning protocol instance as `self` and the remote identity as `peer`.

```nim
var getConn: ConnProvider = proc(): Future[Connection] {.
    async: (raises: [CancelledError])
.} =
  if self.isMixDownload:
    trace "Opening block exchange stream via MixTransport", peer
    let stream = (await self.mixTransport.dial(peer, Codec)).valueOr:
      trace "Unable to open MixTransport block exchange stream", peer, error
      return nil
    return stream

  else:
    try:
      trace "Getting new connection stream", peer
      return await self.switch.dial(peer, Codec)
    except CancelledError as error:
      raise error
    except CatchableError as exc:
      trace "Unable to connect to blockexc peer", exc = exc.msg
```

`isMixDownload` selects the dialing branch by checking the protocol instance's service reference. A Mix instance receives a non-nil `mixTransport` at construction and retains that reference. If Mix dialing fails, the callback returns nil without trying Direct. The Direct branch uses `Switch.dial`. When Mix is disabled, there is no Mix instance to select in the first place.

Both successful branches return a `Connection`. A `TransportStream` satisfies that type through inheritance, so `NetworkPeer` can use the same read, write, and connection-reuse logic for either transport.

The enclosing `getOrCreatePeer` passes this callback as the connection-provider argument to `NetworkPeer.new`, alongside the message callbacks described earlier. The constructor also supports an explicitly supplied `ConnProvider`, which replaces this default callback; normal Storage startup supplies none.

### Reusing or replacing the sending connection

When the recipient sends presence, `NetworkPeer.send` asks `connect` for the sending connection:

```nim
proc connect*(
    self: NetworkPeer
): Future[Connection] {.async: (raises: [CancelledError]).} =
  if self.connected:
    trace "Already connected", peer = self.id, connId = self.sendConn.oid
    return self.sendConn

  self.sendConn = await self.getConn()
  self.trackedFutures.track(self.readLoop(self.sendConn))
  return self.sendConn
```

The Mix protocol instance installs `getConn` in `BlockExcNetwork.getOrCreatePeer`. That callback calls `mixTransport.dial(peer, Codec)`. For a session recipient, `peer` is the anonymous session ID. MixTransport finds the existing session and opens a new stream within it; the recipient does not discover the initiator's real address or establish a replacement session.

The requester must have the BlockExchange protocol mounted, because this new stream invokes its protocol handler. The resulting stream is retained as `sendConn`, so subsequent presence messages reuse it rather than paying another opening handshake each time. If that stream closes while the session remains healthy, the next send can open a replacement without waiting for a new incoming stream.

Mix session events govern peer membership, while the retained sending connection belongs to `NetworkPeer`. Opening a replacement stream does not create a replacement session.

Block responses continue to use the stream carrying their request. Each BlockExchange message or block response is submitted as one connection write; MixTransport serializes writes before fragmenting them.

The transport walkthrough, **Mix Transport Implementation Walk Through - Recipient-Originated Streams**, explains the direction-specific opening handshake and shared duplicate-opening history.

## Using provider addresses

Manifest discovery and block-provider discovery both return `PeerRecord` values. A record can contain ordinary addresses and Mix advertisements. For a Mix request, `mixAddresses` decodes each advertisement and checks its embedded public key against the record's peer ID:

```nim
func mixAddresses*(
    peer: PeerId, addresses: openArray[MultiAddress]
): seq[MultiAddress] =
  for address in addresses:
    if MixPubInfo.fromMixAddress(address, Opt.some(peer)).isOk:
      result.add(address)
```

The Mix connection path rejects a provider if no validated Mix address remains. Otherwise, BlockExchange calls the address-aware `MixTransport.connect`, and manifest fetching calls the address-aware `MixTransport.dial`. The explicit destination supplies the final Mix hop; it does not have to be added to the relay pool. Subsequent streams can reuse the established session through the peer-ID overload.

The Direct path passes the complete provider address list to the Switch, leaving address support and connection reuse to libp2p. An advertisement is contact information, not a guarantee of reachability or support for the requested application protocol; connection and stream establishment still report those failures.

### Fetching the manifest through the selected connection

`ManifestProtocol.fetchManifest` checks for locally available content and otherwise calls discovery to obtain providers. For each attempted provider, it calls `fetchManifestFromPeer` with the download's transport choice. The complete per-provider operation in `storage/manifest/protocol.nim` shows where transport-specific dialing ends and ordinary protocol I/O begins:

```nim
proc fetchManifestFromPeer(
    self: ManifestProtocol, peer: PeerRecord, cid: Cid, transport: DownloadTransport
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  var conn: Connection
  try:
    if transport == DownloadTransport.Mix:
      if self.mixTransport.isNil:
        return failure("Mix transport is not enabled")
      let addresses = mixAddresses(peer.peerId, peer.addresses.mapIt(it.address))
      if addresses.len == 0:
        return failure("Provider has no usable Mix address")
      conn = (
        await self.mixTransport.dial(peer.peerId, addresses, ManifestProtocolCodec)
      ).valueOr:
        return failure(
          "Error opening MixTransport manifest stream to " & $peer.peerId & ": " & error
        )
    else:
      conn = await self.switch.dial(
        peer.peerId, peer.addresses.mapIt(it.address), ManifestProtocolCodec
      )

    let cidBytes = cid.data.buffer
    var reqBuf = newSeqUninit[byte](2 + cidBytes.len)
    let cidLenLE = cidBytes.len.uint16.toLE
    copyMem(addr reqBuf[0], unsafeAddr cidLenLE, 2)
    if cidBytes.len > 0:
      copyMem(addr reqBuf[2], unsafeAddr cidBytes[0], cidBytes.len)
    await conn.write(reqBuf)

    without (status, data) =? await readManifestResponse(conn), err:
      return failure(err)

    if status == ManifestFetchStatus.NotFound:
      return failure(
        newException(BlockNotFoundError, "Manifest not found on peer " & $peer.peerId)
      )

    without blk =? bt.Block.new(cid, data, verify = true), err:
      return failure("Manifest CID verification failed: " & err.msg)

    return success blk
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error fetching manifest from peer " & $peer.peerId & ": " & exc.msg)
  finally:
    if not conn.isNil:
      await conn.close()
```

Only the connection-establishment branch differs. Both paths then encode the same manifest request, read the same response format, and verify the returned bytes against the requested CID. The `finally` block closes the manifest stream, not the whole Mix session. That session can subsequently carry BlockExchange streams to the same provider.

A Mix dialing failure returns from the Mix branch. Execution does not continue into the Direct branch. Retrying another provider therefore retains the selected transport.

### Establishing a BlockExchange provider session

Block-provider discovery uses `BlockExcNetwork.dialPeer` rather than the Manifest helper. The procedure is declared in `storage/blockexchange/network/network.nim`:

```nim
proc dialPeer*(self: BlockExcNetwork, peer: PeerRecord) {.async.}
```

After checking availability, self-dialing, and any reusable Direct peer, its Mix branch performs:

```nim
if self.isMixDownload:
  let mixTransport = self.mixTransport
  trace "Connecting to peer via MixTransport", peer = peer.peerId
  let addresses = mixAddresses(peer.peerId, peer.addresses.mapIt(it.address))
  if addresses.len == 0:
    raise newException(StorageError, "Provider has no usable Mix address")
  let session = (await mixTransport.connect(peer.peerId, addresses)).valueOr:
    raise newException(StorageError, "Failed to connect over MixTransport: " & error)
  self.mixSessions[peer.peerId] = session
```

This step obtains a session. A later BlockExchange send obtains an application stream through the connection provider described earlier. Keeping these steps separate lets discovery supply and validate the provider's addresses while subsequent sends reuse the established session.

For Direct providers, the same procedure asks the Switch to establish a physical connection. This excerpt shows the Direct branch; the self/already-connected checks and Mix branch are omitted:

```nim
proc dialPeer*(self: BlockExcNetwork, peer: PeerRecord) {.async.} =
  # Earlier checks and Mix branch omitted.
  # Direct branch:
  await self.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))
```

Both Direct paths pass the provider's complete address list to libp2p in its original order. Libp2p can reuse an existing connection; when a new connection is needed, the dialer tries address candidates using transports that recognize them. TCP and QUIC require a full address-pattern match, and relay transport requires a terminal circuit-relay component, so a normal Mix advertisement is not an ordinary transport candidate. Direct dialing does not depend on the Mix advertisement being last. Connection reuse and failure handling remain libp2p's responsibility, including when the supplied list is empty.

Direct peer registration comes from the Switch's `Joined` event, not from an additional registration call after `connect`. The event handler installed by `BlockExcNetwork.init` calls:

```nim
proc handlePeerJoined*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  if peer in self.excludedPeers:
    return
  await self.registerPeer(peer)
```

This check excludes configured relay identities from Direct BlockExchange registration. For an allowed peer, `registerPeer` creates or reuses the protocol's peer object and invokes `onPeerJoined`; the engine's callback creates a peer context if one does not already exist. An existing physical connection does not necessarily produce another `Joined` event when reused. Provider dialing therefore relies on the existing event-managed peer state rather than promising a new registration notification on every call.

Mix uses its separate session-event callback for the corresponding registration. Establishing a physical connection to a Mix relay is not a Mix application-peer event.

## Discovery and swarm admission

Discovery requests are keyed by `(CID, transport)`. Requests for the same CID over different transports can therefore both establish their intended connection type. This key controls provider dialing, not the DHT lookup mechanism itself.

Before queueing discovery, `BlockExcEngine.searchForNewPeers` applies one shared
three-second cooldown across Direct and Mix downloads. The timestamp records the
last submission through this helper, regardless of CID or transport:

```nim
proc searchForNewPeers(self: BlockExcEngine, cid: Cid, transport: DownloadTransport) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    trace "Searching for new peers for", cid = cid
    storage_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now()
    self.discovery.queueFindBlocksReq(@[cid], transport)
```

A call during the cooldown does not enqueue a request; the download worker must
try again later. This restores the original shared submission limit. It is not a
global limiter for all DHT operations, such as independent manifest lookups.
The queued request still retains its transport so the discovery worker selects
the appropriate protocol instance when dialing providers.

The queued request type and insertion operation in `engine/discovery.nim` are:

```nim
type DiscoveryKey = tuple[cid: Cid, transport: DownloadTransport]

proc queueFindBlocksReq*(
    b: DiscoveryEngine,
    cids: seq[Cid],
    transport: DownloadTransport = DownloadTransport.Direct,
) =
  for cid in cids:
    let key = (cid, transport)
    if key notin b.discoveryQueue:
      try:
        b.discoveryQueue.putNoWait(key)
      except CatchableError as exc:
        warn "Exception queueing discovery request", exc = exc.msg
```

The background consumer has this signature:

```nim
proc discoveryTaskLoop(b: DiscoveryEngine) {.async: (raises: []).}
```

For each queued key, the loop calls `b.discovery.find(key.cid)`. Once provider records arrive, the loop chooses `b.networks.networkFor(key.transport)` for their `dialPeer` calls and waits for those attempts to finish. The underlying discovery call does not receive `key.transport`: direct versus private DHT queries remain governed by discovery's own configuration.

### Selecting peers for presence queries

The engine uses a `PresencePeerSelectionPolicy` to choose which connected peers to ask about content availability. The policy receives the peer store already selected for the download's transport. The policy does not choose a transport, dial a connection, or change the swarm's admission rules.

`BlockExcEngine.new` accepts one policy for Direct and one for Mix. Both default to the original selection procedure. These parameters are separate from `selectionPolicy`, which controls block scheduling rather than peer selection:

```nim
proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    networks: BlockExcNetworks,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerContextStore,
    downloadManager: DownloadManager,
    selectionPolicy = spSequential,
    directPeerSelectionPolicy: PresencePeerSelectionPolicy =
      newPresencePeerSelectionPolicy(),
    mixPeerSelectionPolicy: PresencePeerSelectionPolicy =
      newPresencePeerSelectionPolicy(),
    directPresenceQueryPolicy: PresenceQueryPolicy = PresenceQueryPolicy.QuerySelectedPeers,
    mixPresenceQueryPolicy: PresenceQueryPolicy = PresenceQueryPolicy.QuerySelectedPeers,
): BlockExcEngine
```

Normal Storage construction omits both peer-policy arguments. An experiment can supply `mixPeerSelectionPolicy = newProviderPriorityPolicy()` without changing the Direct policy. The arguments are constructor configuration, not additional REST query parameters.

The default implementation is in `engine/peerselection.nim`. Its initial-query operation collects all peers in the supplied store. Only an oversized list is shuffled and truncated:

```nim
method selectInitialPresencePeers*(
    policy: PresencePeerSelectionPolicy,
    peers: PeerContextStore,
    providers: HashSet[PeerId],
    limit: int,
): seq[PeerContext] {.base, gcsafe, raises: [].} =
  result = peers.toSeq()
  if result.len > limit:
    shuffle(result)
    result.setLen(limit)
```

The `providers` argument contains discovered provider identities when the configured policy requests that information. The default policy ignores that argument: a connected peer need not already be listed as a provider before BlockExchange asks whether the peer has content. With a Mix peer store, this includes peers reachable through established Mix sessions. Their content availability is still determined by presence responses.

The later-query operation deliberately has no initial-selection limit and performs no shuffle:

```nim
method selectPresencePeers*(
    policy: PresencePeerSelectionPolicy,
    peers: PeerContextStore,
    providers: HashSet[PeerId],
): seq[PeerContext] {.base, gcsafe, raises: [].} =
  peers.toSeq()
```

These are two distinct operations because the initial and later broadcasts have different selection behavior. Both return candidates; the engine retains responsibility for sending the queries.

### Where the worker invokes the policy

`downloadWorker` selects the policy once from the engine's transport-indexed policy array. The following excerpt shows the initial call and the later call in the batch loop; other scheduling operations are omitted:

```nim
proc downloadWorker(
    self: BlockExcEngine, download: ActiveDownload
) {.async: (raises: []).} =
  let
    peers = self.peersFor(download.ctx.transport)
    peerSelection = self.peerSelectionPolicies[download.ctx.transport]
  # Other worker state and logging omitted.
  try:
    let maxSwarmPeers = download.ctx.swarm.config.deltaMax
    let connectedPeers = peerSelection.selectInitialPresencePeers(
      peers, download.ctx.providerPeers, maxSwarmPeers
    )
    # Initial broadcast or discovery follows.
    # Inside the batch loop, when another presence broadcast is needed:
    if shouldBroadcast:
      let connectedPeers = peerSelection.selectPresencePeers(
        peers, download.ctx.providerPeers
      )
      # Broadcast or discovery/retry follows.
  # Exception handling omitted.
```

This keeps the download procedure shared. A policy changes the candidate list, while the existing worker controls when queries are needed and how their responses are used.

### Optional provider prioritization

`ProviderPriorityPolicy` derives from `PresencePeerSelectionPolicy` and overrides the selection operations. Its constructor is:

```nim
proc newProviderPriorityPolicy*(providersOnly = false): ProviderPriorityPolicy =
  ProviderPriorityPolicy(providersOnly: providersOnly)
```

With the default `providersOnly = false`, the policy puts discovered providers first and then appends other peers in store order. Passing `providersOnly = true` explicitly excludes those other peers. Neither setting is selected automatically for Mix.

The initial operation truncates the prioritized list without shuffling it, preserving provider priority. The later operation returns the entire eligible list. Prioritization and provider-only eligibility therefore remain available for experiments without modifying the default policy.

### Provider information is tracked only when needed

The policy also declares whether it needs discovery results:

```nim
method needsProviderTracking*(
    policy: PresencePeerSelectionPolicy
): bool {.base, gcsafe, raises: [].} =
  false

method needsProviderTracking*(
    policy: ProviderPriorityPolicy
): bool {.gcsafe, raises: [].} =
  true
```

After dialing discovered providers, discovery invokes `onProviders` only if a callback is installed. The engine constructor installs that callback only when at least one configured policy needs provider tracking. With both default policies, no callback is installed: discovery does not scan active downloads or populate their provider sets.

When a callback is needed, it first checks the policy for the transport that requested discovery. For example, enabling provider priority for Mix does not make Direct discovery populate provider sets. The callback then updates matching downloads:

```nim
# Nested callback installed by BlockExcEngine.new when tracking is needed.
discovery.onProviders = proc(
    cid: Cid, transport: DownloadTransport, providers: seq[PeerRecord]
) {.gcsafe, raises: [].} =
  if not self.peerSelectionPolicies[transport].needsProviderTracking:
    return
  for downloads in self.downloadManager.downloads.values:
    for download in downloads.values:
      if download.manifestCid == cid and download.ctx.transport == transport:
        download.ctx.providerPeers.clear()
        for provider in providers:
          if provider.peerId in self.peersFor(transport):
            download.ctx.providerPeers.incl(provider.peerId)
```

Only peers present in the selected engine peer store enter a download's recorded provider set. The provider policy uses that set to order or restrict candidates; the default policy does not depend on the set.

### Swarm admission after selection

After selecting candidates, `broadcastWantHave` attempts to add each candidate to the download's swarm before sending the presence query. Admission can fail because the swarm is full or because that swarm has banned the peer. Failure to admit a peer does not necessarily mean that asking about the peer's content is undesirable: admission and querying are separate decisions.

The engine constructor accepts `directPresenceQueryPolicy` and `mixPresenceQueryPolicy` independently of the candidate-selection policies. Both default to `PresenceQueryPolicy.QuerySelectedPeers`: attempt admission, but still query a new candidate if admission fails. An experiment can pass `mixPresenceQueryPolicy = PresenceQueryPolicy.QueryAdmittedPeers` to suppress those queries for Mix without changing Direct. This does not change swarm capacity or override bans.

`broadcastWantHave` in `engine/engine.nim` chooses the query policy for the download's transport. The excerpt below shows the decision before sending; the message fields and timeout handling are omitted:

```nim
proc broadcastWantHave(
    self: BlockExcEngine,
    download: ActiveDownload,
    start: uint64,
    count: uint64,
    peers: seq[PeerContext],
) {.async: (raises: [CancelledError]).} =
  # Resolve the range address and selected protocol instance.
  for peerCtx in peers:
    if not download.addPeerIfAbsent(
      peerCtx.id, BlockAvailability.unknown(),
      self.presenceQueryPolicies[download.ctx.transport],
    ):
      continue
    # Send the WantHave message through the selected protocol instance.
```

The helper in `engine/activedownload.nim` performs the admission attempt. Its Boolean result means whether to send the query, not whether admission succeeded:

```nim
proc addPeerIfAbsent*(
    download: ActiveDownload,
    peerId: PeerId,
    availability: BlockAvailability,
    queryPolicy: PresenceQueryPolicy = PresenceQueryPolicy.QuerySelectedPeers,
): bool =
  let existingPeer = download.ctx.swarm.getPeer(peerId)
  if existingPeer.isSome:
    # peer already tracked, skip if bakComplete
    return existingPeer.get().availability.kind != bakComplete

  let admitted = download.ctx.swarm.addPeer(peerId, availability)
  return queryPolicy == PresenceQueryPolicy.QuerySelectedPeers or admitted
```

For an existing peer, both policies query again unless availability is already complete. For a new peer, both policies attempt admission exactly once. `QuerySelectedPeers` then permits the query regardless of the admission result; `QueryAdmittedPeers` permits it only when admission succeeds. Sending a query does not itself insert a rejected peer into the swarm. A subsequent response goes through the normal availability-update path described next.

### Applying presence to the matching downloads

A presence response describes which blocks a peer can supply. The protocol-instance callbacks introduced earlier pass that response and the receiving transport to the engine's handler in `engine/engine.nim`:

```nim
proc blockPresenceHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    blocks: seq[BlockPresence],
    transport: DownloadTransport = DownloadTransport.Direct,
) {.async: (raises: []).}
```

The handler first obtains the peer context from `self.peersFor(transport)`. For each positive presence entry, it finds the addressed download using the response's download ID and tree CID. Updating availability is guarded by both existence and transport:

```nim
if downloadOpt.isSome and downloadOpt.get().ctx.transport == transport:
  # Convert the presence entry to BlockAvailability.
  # Then updatePeerAvailability applies that value to the download's swarm.
```

The same handler can share the resulting availability with other downloads of that tree, but only when `otherDownload.ctx.transport == transport`. Therefore, a directly received response cannot add availability to a Mix download's swarm, even when both downloads concern the same tree and provider.

## Streaming reads and shared local content

The streaming REST endpoint passes the transport choice through `StorageNodeRef.retrieve` to `streamEntireDataset`. The latter creates a download and returns a `StoreStream` that reads blocks as they become available. Each missing-block read waits on that particular download. This matters both for simultaneous Direct/Mix downloads and for two Direct downloads of the same tree: another download's cancellation must not cancel this reader's pending block handle.

The beginning of `streamEntireDataset` in `storage/node.nim` creates the download and a store view tied to its ID:

```nim
proc streamEntireDataset(
    self: StorageNodeRef,
    md: ManifestDescriptor,
    fetchLocal: bool = false,
    transport: DownloadTransport = DownloadTransport.Direct,
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  # Logging omitted.
  let
    treeCid = md.manifest.treeCid
    download = ?self.engine.startTreeDownloadOpaque(
      md, fetchLocal = fetchLocal, transport = transport
    )
    downloadStore = NetworkStore.new(
      self.engine, self.networkStore.localStore, downloadId = some(download.downloadId)
    )
    stream = LPStream(StoreStream.new(downloadStore, md.manifest, pad = false))
  # Completion and cancellation task setup follows.
```

The `NetworkStore` constructor in `storage/stores/networkstore.nim` retains the ID alongside the shared local store and engine references:

```nim
proc new*(
    T: type NetworkStore,
    engine: BlockExcEngine,
    localStore: BlockStore,
    downloadId: Option[uint64] = none(uint64),
): NetworkStore =
  NetworkStore(localStore: localStore, engine: engine, downloadId: downloadId)
```

When `StoreStream` asks for a block by tree address, the view executes:

```nim

method getBlock*(
    self: NetworkStore, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  let downloadOpt =
    if self.downloadId.isSome:
      self.engine.downloadManager.getDownload(self.downloadId.get(), address.treeCid)
    else:
      self.engine.downloadManager.getDownload(address.treeCid)
  if downloadOpt.isSome:
    let handle = downloadOpt.get().getWantHandle(address)
    without blk =? (await self.localStore.getBlock(address)), err:
      if not (err of BlockNotFoundError):
        handle.cancelSoon()
        return failure err
      return await handle
    discard downloadOpt.get().completeWantHandle(address, some(blk))
    return success blk

  return await self.localStore.getBlock(address)
```

The first branch selects the download by both ID and tree CID. The unscoped branch selects by tree CID alone. If a matching download exists, `getWantHandle` obtains the future through which that download supplies the requested block.

The local store is checked before waiting. A missing block causes a wait on the selected handle; another local-store error cancels that handle and returns the error. If no matching download remains, the operation only checks local content—it does not select a different download to replace the scoped one.

The scoped view therefore follows its own download's scheduler and cancellation state. Callers that omit `downloadId` use the tree-CID lookup shown in the other branch.

### Concurrent downloads and shared storage

Starting a foreground streaming download creates a new `ActiveDownload` with its own ID, scheduler, and pending handles; it does not reuse another foreground download simply because the tree CID matches. Background downloads have a different entry point: `StorageNodeRef.startBackgroundDownload` first calls `getBackgroundDownload(treeCid, transport)` and returns an existing background download's ID when one matches. A background request does not thereby reuse an arbitrary foreground download. Direct and Mix background requests do not reuse each other's operations.

The download-specific `NetworkStore` is a wrapper around the same local store, not a private cache. A block already present locally can satisfy either reader, regardless of which transport supplied it. The binding selects which download's future to await when the block is missing; it does not enforce the provenance of cached bytes.

Each download worker checks local storage before requesting its next batch. This can avoid fetching blocks another download has already stored, but does not coalesce requests already in flight. Two downloads can therefore receive and validate the same block. The batch-processing path stores the block by CID and then stores its proof and block-CID mapping under `(treeCid, index)`. The transport choice is not part of either storage key.

`RepoStore.storeBlock` reports `AlreadyInStore` for an existing block with matching size and retains the later expiry. `putLeafMetadata` retains existing metadata for the same tree position. `RepoStore.putBlock` updates storage accounting only for a newly stored block, and `putCidAndProof` increments the block reference count only for newly stored leaf metadata. These operations use the datastore's concurrency-aware `modifyGet` operation. Duplicate successful deliveries therefore reuse stored content; they can still incur network, validation, and metadata work.

Completing one download's block handle does not broadcast completion to every download of the same tree. Another worker can discover the stored block through its local checks. A reader already waiting on its own handle remains tied to that download's progress and cancellation. Coalescing downloads would require explicit ownership and cancellation rules; sharing the local store alone does not implement it.

Both transports still share the local content-addressed store. A verified block already available locally can satisfy either download without another network request. The selected transport governs network connections; it does not partition cached content by the route through which the content arrived.
