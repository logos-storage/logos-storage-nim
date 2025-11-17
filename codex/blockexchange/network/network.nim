## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sequtils

import pkg/chronos

import pkg/libp2p
import pkg/libp2p/utils/semaphore
import pkg/questionable
import pkg/questionable/results

import ../../blocktype as bt
import ../../logutils
import ../protobuf/blockexc as pb
import ../protobuf/payments
import ../../utils/trackedfutures

import ./networkpeer

export networkpeer, payments

logScope:
  topics = "codex blockexcnetwork"

const
  Codec* = "/codex/blockexc/1.0.0"
  DefaultMaxInflight* = 100

type
  WantListHandler* = proc(peer: PeerId, wantList: WantList) {.async: (raises: []).}
  BlocksDeliveryHandler* =
    proc(peer: PeerId, blocks: seq[BlockDelivery]) {.async: (raises: []).}
  BlockPresenceHandler* =
    proc(peer: PeerId, precense: seq[BlockPresence]) {.async: (raises: []).}
  AccountHandler* = proc(peer: PeerId, account: Account) {.async: (raises: []).}
  PaymentHandler* = proc(peer: PeerId, payment: SignedState) {.async: (raises: []).}
  PeerEventHandler* = proc(peer: PeerId) {.async: (raises: [CancelledError]).}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onBlocksDelivery*: BlocksDeliveryHandler
    onPresence*: BlockPresenceHandler
    onAccount*: AccountHandler
    onPayment*: PaymentHandler
    onPeerJoined*: PeerEventHandler
    onPeerDeparted*: PeerEventHandler
    onPeerDropped*: PeerEventHandler

  WantListSender* = proc(
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
  ) {.async: (raises: [CancelledError]).}
  WantCancellationSender* = proc(peer: PeerId, addresses: seq[BlockAddress]) {.
    async: (raises: [CancelledError])
  .}
  BlocksDeliverySender* = proc(peer: PeerId, blocksDelivery: seq[BlockDelivery]) {.
    async: (raises: [CancelledError])
  .}
  PresenceSender* = proc(peer: PeerId, presence: seq[BlockPresence]) {.
    async: (raises: [CancelledError])
  .}
  AccountSender* =
    proc(peer: PeerId, account: Account) {.async: (raises: [CancelledError]).}
  PaymentSender* =
    proc(peer: PeerId, payment: SignedState) {.async: (raises: [CancelledError]).}

  BlockExcRequest* = object
    sendWantList*: WantListSender
    sendWantCancellations*: WantCancellationSender
    sendBlocksDelivery*: BlocksDeliverySender
    sendPresence*: PresenceSender
    sendAccount*: AccountSender
    sendPayment*: PaymentSender

  BlockExcNetwork* = ref object of LPProtocol
    peers*: Table[PeerId, NetworkPeer]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider
    inflightSema: AsyncSemaphore
    maxInflight: int = DefaultMaxInflight
    trackedFutures*: TrackedFutures = TrackedFutures()

proc peerId*(b: BlockExcNetwork): PeerId =
  ## Return peer id
  ##

  return b.switch.peerInfo.peerId

proc isSelf*(b: BlockExcNetwork, peer: PeerId): bool =
  ## Check if peer is self
  ##

  return b.peerId == peer

proc send*(
    b: BlockExcNetwork, id: PeerId, msg: pb.Message
) {.async: (raises: [CancelledError]).} =
  ## Send message to peer
  ##

  if not (id in b.peers):
    trace "Unable to send, peer not found", peerId = id
    return

  try:
    let peer = b.peers[id]

    await b.inflightSema.acquire()
    await peer.send(msg)
  except CancelledError as error:
    raise error
  except CatchableError as err:
    error "Error sending message", peer = id, msg = err.msg
  finally:
    b.inflightSema.release()

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
      )
    ),
    full: full,
  )

  b.send(id, Message(wantlist: msg))

proc sendWantCancellations*(
    b: BlockExcNetwork, id: PeerId, addresses: seq[BlockAddress]
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Informs a remote peer that we're no longer interested in a set of blocks
  ##
  await b.sendWantList(id = id, addresses = addresses, cancel = true)

proc handleBlocksDelivery(
    b: BlockExcNetwork, peer: NetworkPeer, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: []).} =
  ## Handle incoming blocks
  ##

  if not b.handlers.onBlocksDelivery.isNil:
    await b.handlers.onBlocksDelivery(peer.id, blocksDelivery)

proc sendBlocksDelivery*(
    b: BlockExcNetwork, id: PeerId, blocksDelivery: seq[BlockDelivery]
) {.async: (raw: true, raises: [CancelledError]).} =
  ## Send blocks to remote
  ##

  b.send(id, pb.Message(payload: blocksDelivery))

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

proc handleAccount(
    network: BlockExcNetwork, peer: NetworkPeer, account: Account
) {.async: (raises: []).} =
  ## Handle account info
  ##

  if not network.handlers.onAccount.isNil:
    await network.handlers.onAccount(peer.id, account)

proc sendAccount*(
    b: BlockExcNetwork, id: PeerId, account: Account
) {.async: (raw: true, raises: [CancelledError]).} =
  ## Send account info to remote
  ##

  b.send(id, Message(account: AccountMessage.init(account)))

proc sendPayment*(
    b: BlockExcNetwork, id: PeerId, payment: SignedState
) {.async: (raw: true, raises: [CancelledError]).} =
  ## Send payment to remote
  ##

  b.send(id, Message(payment: StateChannelUpdate.init(payment)))

proc handlePayment(
    network: BlockExcNetwork, peer: NetworkPeer, payment: SignedState
) {.async: (raises: []).} =
  ## Handle payment
  ##

  if not network.handlers.onPayment.isNil:
    await network.handlers.onPayment(peer.id, payment)

proc rpcHandler(
    self: BlockExcNetwork, peer: NetworkPeer, msg: Message
) {.async: (raises: []).} =
  ## handle rpc messages
  ##
  if msg.wantList.entries.len > 0:
    self.trackedFutures.track(self.handleWantList(peer, msg.wantList))

  if msg.payload.len > 0:
    self.trackedFutures.track(self.handleBlocksDelivery(peer, msg.payload))

  if msg.blockPresences.len > 0:
    self.trackedFutures.track(self.handleBlockPresence(peer, msg.blockPresences))

  if account =? Account.init(msg.account):
    self.trackedFutures.track(self.handleAccount(peer, account))

  if payment =? SignedState.init(msg.payment):
    self.trackedFutures.track(self.handlePayment(peer, payment))

proc getOrCreatePeer(self: BlockExcNetwork, peer: PeerId): NetworkPeer =
  ## Creates or retrieves a BlockExcNetwork Peer
  ##

  if peer in self.peers:
    return self.peers.getOrDefault(peer, nil)

  var getConn: ConnProvider = proc(): Future[Connection] {.
      async: (raises: [CancelledError])
  .} =
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

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(peer, getConn, rpcHandler)
  debug "Created new blockexc peer", peer

  self.peers[peer] = blockExcPeer

  return blockExcPeer

proc dialPeer*(self: BlockExcNetwork, peer: PeerRecord) {.async.} =
  ## Dial a peer
  ##

  if self.isSelf(peer.peerId):
    trace "Skipping dialing self", peer = peer.peerId
    return

  if peer.peerId in self.peers:
    trace "Already connected to peer", peer = peer.peerId
    return

  await self.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

proc dropPeer*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  trace "Dropping peer", peer

  try:
    if not self.switch.isNil:
      await self.switch.disconnect(peer)
  except CatchableError as error:
    warn "Error attempting to disconnect from peer", peer = peer, error = error.msg

  if not self.handlers.onPeerDropped.isNil:
    await self.handlers.onPeerDropped(peer)

proc handlePeerJoined*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  discard self.getOrCreatePeer(peer)
  if not self.handlers.onPeerJoined.isNil:
    await self.handlers.onPeerJoined(peer)

proc handlePeerDeparted*(
    self: BlockExcNetwork, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Cleanup disconnected peer
  ##

  trace "Cleaning up departed peer", peer
  self.peers.del(peer)
  if not self.handlers.onPeerDeparted.isNil:
    await self.handlers.onPeerDeparted(peer)

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

  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    let peerId = conn.peerId
    let blockexcPeer = self.getOrCreatePeer(peerId)
    await blockexcPeer.readLoop(conn) # attach read loop

  self.handler = handler
  self.codec = Codec

proc stop*(self: BlockExcNetwork) {.async: (raises: []).} =
  await self.trackedFutures.cancelTracked()

proc new*(
    T: type BlockExcNetwork,
    switch: Switch,
    connProvider: ConnProvider = nil,
    maxInflight = DefaultMaxInflight,
): BlockExcNetwork =
  ## Create a new BlockExcNetwork instance
  ##

  let self = BlockExcNetwork(
    switch: switch,
    getConn: connProvider,
    inflightSema: newAsyncSemaphore(maxInflight),
    maxInflight: maxInflight,
  )

  self.maxIncomingStreams = self.maxInflight

  proc sendWantList(
      id: PeerId,
      cids: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false,
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendWantList(id, cids, priority, cancel, wantType, full, sendDontHave)

  proc sendWantCancellations(
      id: PeerId, addresses: seq[BlockAddress]
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendWantCancellations(id, addresses)

  proc sendBlocksDelivery(
      id: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendBlocksDelivery(id, blocksDelivery)

  proc sendPresence(
      id: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendBlockPresence(id, presence)

  proc sendAccount(
      id: PeerId, account: Account
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendAccount(id, account)

  proc sendPayment(
      id: PeerId, payment: SignedState
  ): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendPayment(id, payment)

  self.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendWantCancellations: sendWantCancellations,
    sendBlocksDelivery: sendBlocksDelivery,
    sendPresence: sendPresence,
    sendAccount: sendAccount,
    sendPayment: sendPayment,
  )

  self.init()
  return self
