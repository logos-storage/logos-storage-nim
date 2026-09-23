## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sequtils
import std/sets

import pkg/chronos

import pkg/libp2p
import pkg/libp2p/connmanager as lp_connmanager
import pkg/libp2p/protocols/protocol as lp_protocol
import pkg/questionable
import pkg/questionable/results

import ../../blocktype as bt
import ../../logutils
import ../types
import ../protocol/message
import ../../utils/trackedfutures

import ./networkpeer
import ../protocol/wantblocks

import ../../mix

export networkpeer, wantblocks

logScope:
  topics = "storage blockexcnetwork"

const
  Codec* = "/storage/blockexc/1.0.0"
  DefaultMaxInflight* = 100

type
  WantListHandler* = proc(peer: PeerId, wantList: WantList) {.async: (raises: []).}
  BlockPresenceHandler* =
    proc(peer: PeerId, precense: seq[BlockPresence]) {.async: (raises: []).}
  PeerEventHandler* = proc(peer: PeerId) {.async: (raises: [CancelledError]).}
  WantBlocksRequestHandlerProc* = proc(
    peer: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onPresence*: BlockPresenceHandler
    onWantBlocksRequest*: WantBlocksRequestHandlerProc
    onPeerJoined*: PeerEventHandler
    onPeerDeparted*: PeerEventHandler

  WantListSender* = proc(
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
    rangeCount: uint64 = 0,
    downloadId: uint64 = 0,
  ) {.async: (raises: [CancelledError]).}
  PresenceSender* = proc(peer: PeerId, presence: seq[BlockPresence]) {.
    async: (raises: [CancelledError])
  .}

  BlockExcRequest* = object
    sendWantList*: WantListSender
    sendPresence*: PresenceSender

  BlockExcNetwork* = ref object of LPProtocol
    peers*: Table[PeerId, NetworkPeer]
    excludedPeers: HashSet[PeerId]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider
    inflightSema: AsyncSemaphore
    maxInflight: int = DefaultMaxInflight
    trackedFutures*: TrackedFutures = TrackedFutures()
    mixTransport: MixTransport
    mixSessions: Table[PeerId, TransportSession]
    switchPeerEventHandler: lp_connmanager.PeerEventHandler
    mixSessionEventHandler: SessionEventHandler

  BlockExcNetworks* = ref object
    ## Independent protocol instances. Mix is absent until enabled at startup.
    direct*: BlockExcNetwork
    mix*: BlockExcNetwork
    ## Mount this entry point, not the individual instances, when using the holder.
    dispatchProtocol*: LPProtocol

proc peerId*(b: BlockExcNetwork): PeerId =
  ## Return peer id
  ##

  return b.switch.peerInfo.peerId

func sendConcurrencyLimit*(self: BlockExcNetwork): int =
  self.maxInflight

func isMixDownload*(self: BlockExcNetwork): bool =
  ## Whether this protocol instance handles downloads through MixTransport.
  not self.mixTransport.isNil

func networkFor*(
    self: BlockExcNetworks, transport: DownloadTransport
): BlockExcNetwork =
  case transport
  of DownloadTransport.Direct: self.direct
  of DownloadTransport.Mix: self.mix

proc isSelf*(b: BlockExcNetwork, peer: PeerId): bool =
  ## Check if peer is self
  ##

  return b.peerId == peer

proc send*(
    b: BlockExcNetwork, id: PeerId, msg: Message
) {.async: (raises: [CancelledError]).} =
  ## Send message to peer
  ##

  if not (id in b.peers):
    trace "Unable to send protobuf, peer not in network.peers",
      peerId = id, hasWantList = msg.wantList.entries.len > 0
    return

  var acquired = false
  try:
    let peer = b.peers[id]

    await b.inflightSema.acquire()
    acquired = true
    await peer.send(msg)
  except CancelledError as error:
    raise error
  except CatchableError as err:
    error "Error sending message", peer = id, msg = err.msg
  finally:
    if acquired:
      try:
        b.inflightSema.release()
      except AsyncSemaphoreError as err:
        error "Error releasing inflight semaphore", msg = err.msg

proc handleWantList(
    b: BlockExcNetwork, peer: NetworkPeer, list: WantList
) {.async: (raises: []).} =
  ## Handle incoming want list
  ##

  if not b.handlers.onWantList.isNil:
    await b.handlers.onWantList(peer.id, list)

proc sendWantList*(
    b: BlockExcNetwork,
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
    rangeCount: uint64 = 0,
    downloadId: uint64 = 0,
) {.async: (raw: true, raises: [CancelledError]).} =
  ## Send a want message to peer
  ##

  let msg = WantList(
    entries: addresses.mapIt(
      WantListEntry(
        address: it,
        priority: priority,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave,
        rangeCount: rangeCount,
        downloadId: downloadId,
      )
    ),
    full: full,
  )

  b.send(id, Message(wantlist: msg))

proc handleBlockPresence(
    b: BlockExcNetwork, peer: NetworkPeer, presence: seq[BlockPresence]
) {.async: (raises: []).} =
  ## Handle block presence
  ##

  if not b.handlers.onPresence.isNil:
    await b.handlers.onPresence(peer.id, presence)

proc sendBlockPresence*(
    b: BlockExcNetwork, id: PeerId, presence: seq[BlockPresence]
) {.async: (raw: true, raises: [CancelledError]).} =
  ## Send presence to remote
  ##

  b.send(id, Message(blockPresences: @presence))

proc rpcHandler(
    self: BlockExcNetwork, peer: NetworkPeer, msg: Message
) {.async: (raises: []).} =
  ## handle rpc messages
  ##
  if msg.wantList.entries.len > 0:
    self.trackedFutures.track(self.handleWantList(peer, msg.wantList))

  if msg.blockPresences.len > 0:
    self.trackedFutures.track(self.handleBlockPresence(peer, msg.blockPresences))

proc getOrCreatePeer(self: BlockExcNetwork, peer: PeerId): NetworkPeer =
  ## Creates or retrieves a BlockExcNetwork Peer
  ##

  if peer in self.peers:
    return self.peers.getOrDefault(peer, nil)

  var getConn: ConnProvider =
    if self.isMixDownload:
      proc(): Future[Connection] {.async: (raises: [CancelledError]).} =
        trace "Opening block exchange stream via MixTransport", peer
        (await self.mixTransport.dial(peer, Codec)).valueOr:
          trace "Unable to open MixTransport block exchange stream", peer, error
          nil
    else:
      proc(): Future[Connection] {.async: (raises: [CancelledError]).} =
        try:
          trace "Getting new connection stream", peer
          return await self.switch.dial(peer, Codec)
        except CancelledError as error:
          raise error
        except CatchableError as exc:
          trace "Unable to connect to blockexc peer", exc = exc.msg

  if not isNil(self.getConn):
    getConn = self.getConn

  let rpcHandler = proc(p: NetworkPeer, msg: Message) {.async: (raises: []).} =
    await self.rpcHandler(p, msg)

  let wantBlocksHandler = proc(
      peerId: PeerId, req: WantBlocksRequest
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).} =
    return await self.handlers.onWantBlocksRequest(peerId, req)

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(peer, getConn, rpcHandler, wantBlocksHandler)
  debug "Created new blockexc peer", peer

  self.peers[peer] = blockExcPeer

  return blockExcPeer

proc sendWantBlocksRequest*(
    self: BlockExcNetwork, peer: PeerId, blockRange: BlockRange
): Future[WantBlocksResult[WantBlocksResponse]] {.async: (raises: [CancelledError]).} =
  let networkPeer = self.getOrCreatePeer(peer)
  return await networkPeer.sendWantBlocksRequest(blockRange)

proc unregisterPeer(
  self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).}

proc registerPeer(
  self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).}

proc dialPeer*(self: BlockExcNetwork, peer: PeerRecord) {.async.} =
  ## Dial a peer
  ##

  if self.isSelf(peer.peerId):
    trace "Skipping dialing self", peer = peer.peerId
    return

  if peer.peerId in self.peers and not self.isMixDownload:
    trace "Already connected to peer", peer = peer.peerId
    return

  if self.isMixDownload:
    let mixTransport = self.mixTransport
    trace "Connecting to peer via MixTransport", peer = peer.peerId
    let addresses = mixAddresses(peer.peerId, peer.addresses.mapIt(it.address))
    if addresses.len == 0:
      raise newException(StorageError, "Provider has no usable Mix address")
    let session = (await mixTransport.connect(peer.peerId, addresses)).valueOr:
      raise newException(StorageError, "Failed to connect over MixTransport: " & error)
    self.mixSessions[peer.peerId] = session
  else:
    await self.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

proc dropPeer*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  trace "Dropping peer", peer

  if self.isMixDownload:
    let session = self.mixSessions.getOrDefault(peer)
    if not session.isNil:
      await self.mixTransport.resetSession(session)
      return

    # This protocol instance retains session objects obtained through provider dialing,
    # but not recipient sessions introduced by session events.
    warn "Removing MixTransport peer without resetting its recipient session", peer
    await self.unregisterPeer(peer)
    return

  try:
    if not self.switch.isNil:
      await self.switch.disconnect(peer)
  except CatchableError as error:
    warn "Error attempting to disconnect from peer", peer = peer, error = error.msg

proc excludeRelays*(self: BlockExcNetwork, peers: openArray[PeerId]) =
  for p in peers:
    self.excludedPeers.incl(p)

proc registerPeer(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  discard self.getOrCreatePeer(peer)
  if not self.handlers.onPeerJoined.isNil:
    await self.handlers.onPeerJoined(peer)

proc unregisterPeer(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  trace "Cleaning up departed peer", peer
  self.mixSessions.del(peer)
  self.peers.del(peer)
  if not self.handlers.onPeerDeparted.isNil:
    await self.handlers.onPeerDeparted(peer)

proc handlePeerJoined*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  if peer in self.excludedPeers:
    return
  await self.registerPeer(peer)

proc handlePeerDeparted*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Cleanup disconnected peer
  ##

  if peer in self.excludedPeers:
    return
  await self.unregisterPeer(peer)

proc subscribeMixSessions(self: BlockExcNetwork) =
  ## Use MixTransport sessions, rather than physical Switch connections, as
  ## the peer lifecycle observed by BlockExchange.
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

proc unsubscribeMixSessions(self: BlockExcNetwork) =
  if not self.mixTransport.isNil and not self.mixSessionEventHandler.isNil:
    self.mixTransport.removeSessionEventHandler(self.mixSessionEventHandler)
  self.mixSessionEventHandler = nil
  self.mixSessions.clear()

proc handleConnection(
    self: BlockExcNetwork, conn: Connection
) {.async: (raises: [CancelledError]).} =
  if (conn of TransportStream) != self.isMixDownload:
    await conn.close()
    return
  let peer = self.getOrCreatePeer(conn.peerId)
  await peer.readLoop(conn)

method init*(self: BlockExcNetwork) {.raises: [].} =
  ## Perform protocol initialization
  ##

  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      await self.handlePeerJoined(peerId)
    elif event.kind == PeerEventKind.Left:
      await self.handlePeerDeparted(peerId)
    else:
      warn "Unknown peer event", event

  if not self.isMixDownload:
    self.switchPeerEventHandler = peerEventHandler
    self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.handleConnection(conn)

  self.handler = handler

proc stop*(self: BlockExcNetwork) {.async: (raises: []).} =
  self.unsubscribeMixSessions()
  await self.trackedFutures.cancelTracked()

proc new*(
    T: type BlockExcNetwork,
    switch: Switch,
    connProvider: ConnProvider = nil,
    maxInflight = DefaultMaxInflight,
    mixTransport: MixTransport = nil,
): BlockExcNetwork =
  ## Create a new BlockExcNetwork instance
  ##

  # libp2p now requires a non-nil handler at construction; the real one is set
  # by self.init() below. This nullHandler only exists until then.
  proc nullHandler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    discard

  let self = lp_protocol.new(
    BlockExcNetwork, @[Codec], nullHandler, maxIncomingStreamsTotal = maxInflight
  )
  self.switch = switch
  self.getConn = connProvider
  self.inflightSema = newAsyncSemaphore(max(maxInflight, 1))
  if maxInflight == 0:
    discard self.inflightSema.tryAcquire()

  self.maxInflight = maxInflight
  self.mixTransport = mixTransport

  proc sendWantList(
      id: PeerId,
      cids: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false,
      rangeCount: uint64 = 0,
      downloadId: uint64 = 0,
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendWantList(
      id, cids, priority, cancel, wantType, full, sendDontHave, rangeCount, downloadId
    )

  proc sendPresence(
      id: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendBlockPresence(id, presence)

  self.request = BlockExcRequest(sendWantList: sendWantList, sendPresence: sendPresence)

  self.init()
  if self.isMixDownload:
    self.subscribeMixSessions()
  return self

func isMixEnabled*(self: BlockExcNetworks): bool =
  not self.mix.isNil

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

  # Both transports use this one mounted codec and its incoming-stream quota.
  self.dispatchProtocol = lp_protocol.new(
    LPProtocol, @[Codec], dispatch, maxIncomingStreamsTotal = direct.maxInflight
  )
  self

proc stop*(self: BlockExcNetworks) {.async: (raises: []).} =
  if not self.mix.isNil:
    await self.mix.stop()
  await self.direct.stop()
