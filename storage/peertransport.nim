## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sequtils, tables]

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ./errors
import ./logutils
import ./mix

export mix

logScope:
  topics = "storage peertransport"

type
  PeerTransportEventHandler* =
    proc(peer: PeerId): Future[void] {.async: (raises: [CancelledError]).}

  PeerTransport* = ref object of RootObj

  DirectPeerTransport* = ref object of PeerTransport
    switch: Switch

  MixPeerTransport* = ref object of PeerTransport
    mixTransport: MixTransport
    sessions: Table[PeerId, TransportSession]
    sessionEventHandler: SessionEventHandler
    onLeft: PeerTransportEventHandler

method kind*(self: PeerTransport): DownloadTransport {.base, gcsafe.} =
  raiseAssert "kind is not implemented"

method accepts*(self: PeerTransport, conn: Connection): bool {.base, gcsafe.} =
  raiseAssert "accepts is not implemented"

method connect*(
    self: PeerTransport, peer: PeerRecord
) {.base, async: (raises: [CatchableError]), gcsafe.} =
  raiseAssert "connect is not implemented"

method dial*(
    self: PeerTransport, peer: PeerId, codec: string
): Future[?!Connection] {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "dial is not implemented"

method dial*(
    self: PeerTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.base, async: (raises: [CatchableError]), gcsafe.} =
  raiseAssert "dial is not implemented"

method drop*(
    self: PeerTransport, peer: PeerId
) {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "drop is not implemented"

method setPeerEventHandler*(
    self: PeerTransport, onJoined, onLeft: PeerTransportEventHandler
) {.base, gcsafe.} =
  raiseAssert "setPeerEventHandler is not implemented"

method stop*(self: PeerTransport) {.base, gcsafe.} =
  raiseAssert "stop is not implemented"

method kind*(self: DirectPeerTransport): DownloadTransport =
  DownloadTransport.Direct

method accepts*(self: DirectPeerTransport, conn: Connection): bool =
  not (conn of TransportStream)

method connect*(
    self: DirectPeerTransport, peer: PeerRecord
) {.async: (raises: [CatchableError]).} =
  await self.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

method dial*(
    self: DirectPeerTransport, peer: PeerId, codec: string
): Future[?!Connection] {.async: (raises: [CancelledError]).} =
  try:
    trace "Getting new connection stream", peer
    return success(await self.switch.dial(peer, codec))
  except CancelledError as error:
    raise error
  except CatchableError as exc:
    trace "Unable to connect to blockexc peer", exc = exc.msg
    return failure(exc.msg)

method dial*(
    self: DirectPeerTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  return success(
    await self.switch.dial(peer.peerId, peer.addresses.mapIt(it.address), codec)
  )

method drop*(
    self: DirectPeerTransport, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  try:
    if not self.switch.isNil:
      await self.switch.disconnect(peer)
  except CatchableError as error:
    warn "Error attempting to disconnect from peer", peer = peer, error = error.msg

method setPeerEventHandler*(
    self: DirectPeerTransport, onJoined, onLeft: PeerTransportEventHandler
) =
  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      await onJoined(peerId)
    elif event.kind == PeerEventKind.Left:
      await onLeft(peerId)
    else:
      warn "Unknown peer event", event

  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

method stop*(self: DirectPeerTransport) =
  discard

method kind*(self: MixPeerTransport): DownloadTransport =
  DownloadTransport.Mix

method accepts*(self: MixPeerTransport, conn: Connection): bool =
  conn of TransportStream

method connect*(
    self: MixPeerTransport, peer: PeerRecord
) {.async: (raises: [CatchableError]).} =
  trace "Connecting to peer via MixTransport", peer = peer.peerId
  let addresses = mixAddresses(peer.peerId, peer.addresses.mapIt(it.address))
  if addresses.len == 0:
    raise newException(StorageError, "Provider has no usable Mix address")
  let session = (await self.mixTransport.connect(peer.peerId, addresses)).valueOr:
    raise newException(StorageError, "Failed to connect over MixTransport: " & error)
  self.sessions[peer.peerId] = session

method dial*(
    self: MixPeerTransport, peer: PeerId, codec: string
): Future[?!Connection] {.async: (raises: [CancelledError]).} =
  trace "Opening block exchange stream via MixTransport", peer
  let stream = (await self.mixTransport.dial(peer, codec)).valueOr:
    trace "Unable to open MixTransport block exchange stream", peer, error
    return failure(error)
  return success(Connection(stream))

method dial*(
    self: MixPeerTransport, peer: PeerRecord, codec: string
): Future[?!Connection] {.async: (raises: [CatchableError]).} =
  let addresses = mixAddresses(peer.peerId, peer.addresses.mapIt(it.address))
  if addresses.len == 0:
    return failure("Provider has no usable Mix address")
  let stream = (await self.mixTransport.dial(peer.peerId, addresses, codec)).valueOr:
    return
      failure("Error opening MixTransport stream to " & $peer.peerId & ": " & error)
  return success(Connection(stream))

method drop*(
    self: MixPeerTransport, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  let session = self.sessions.getOrDefault(peer)
  if not session.isNil:
    await self.mixTransport.resetSession(session)
    return

  # This protocol instance retains session objects obtained through provider dialing,
  # but not recipient sessions introduced by session events.
  warn "Removing MixTransport peer without resetting its recipient session", peer
  if not self.onLeft.isNil:
    await self.onLeft(peer)

method setPeerEventHandler*(
    self: MixPeerTransport, onJoined, onLeft: PeerTransportEventHandler
) =
  ## Use MixTransport sessions, rather than physical Switch connections, as
  ## the peer lifecycle observed by BlockExchange.
  proc sessionEventHandler(
      event: SessionEvent
  ): Future[void] {.async: (raises: [CancelledError]).} =
    case event.kind
    of SessionEventKind.Established:
      await onJoined(event.peerId)
    of SessionEventKind.Closed:
      self.sessions.del(event.peerId)
      await onLeft(event.peerId)

  self.onLeft = onLeft
  self.sessionEventHandler = sessionEventHandler
  self.mixTransport.addSessionEventHandler(sessionEventHandler)

method stop*(self: MixPeerTransport) =
  if not self.sessionEventHandler.isNil:
    self.mixTransport.removeSessionEventHandler(self.sessionEventHandler)
  self.sessionEventHandler = nil
  self.onLeft = nil
  self.sessions.clear()

proc new*(T: type DirectPeerTransport, switch: Switch): DirectPeerTransport =
  DirectPeerTransport(switch: switch)

proc new*(T: type MixPeerTransport, mixTransport: MixTransport): MixPeerTransport =
  MixPeerTransport(
    mixTransport: mixTransport, sessions: initTable[PeerId, TransportSession]()
  )
