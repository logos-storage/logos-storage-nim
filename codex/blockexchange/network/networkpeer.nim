## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p

import ../protobuf/blockexc
import ../protobuf/message
import ../../errors
import ../../logutils
import ../../utils/trackedfutures

logScope:
  topics = "codex blockexcnetworkpeer"

const DefaultYieldInterval = 50.millis

type
  ConnProvider* = proc(): Future[Connection] {.async: (raises: [CancelledError]).}

  RPCHandler* = proc(peer: NetworkPeer, msg: Message) {.async: (raises: []).}

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: ConnProvider
    yieldInterval*: Duration = DefaultYieldInterval
    trackedFutures: TrackedFutures

proc connected*(self: NetworkPeer): bool =
  not (isNil(self.sendConn)) and not (self.sendConn.closed or self.sendConn.atEof)

proc readLoop*(self: NetworkPeer, conn: Connection) {.async: (raises: []).} =
  if isNil(conn):
    trace "No connection to read from", peer = self.id
    return

  trace "Attaching read loop", peer = self.id, connId = conn.oid
  try:
    var nextYield = Moment.now() + self.yieldInterval
    while not conn.atEof or not conn.closed:
      if Moment.now() > nextYield:
        nextYield = Moment.now() + self.yieldInterval
        trace "Yielding in read loop",
          peer = self.id, nextYield = nextYield, interval = self.yieldInterval
        await sleepAsync(10.millis)

      let
        data = await conn.readLp(MaxMessageSize.int)
        msg = Message.protobufDecode(data).mapFailure().tryGet()
      trace "Received message", peer = self.id, connId = conn.oid
      await self.handler(self, msg)
  except CancelledError:
    trace "Read loop cancelled"
  except CatchableError as err:
    warn "Exception in blockexc read loop", msg = err.msg
  finally:
    warn "Detaching read loop", peer = self.id, connId = conn.oid
    if self.sendConn == conn:
      self.sendConn = nil
    await conn.close()

proc connect*(
    self: NetworkPeer
): Future[Connection] {.async: (raises: [CancelledError]).} =
  if self.connected:
    trace "Already connected", peer = self.id, connId = self.sendConn.oid
    return self.sendConn

  self.sendConn = await self.getConn()
  self.trackedFutures.track(self.readLoop(self.sendConn))
  return self.sendConn

proc send*(
    self: NetworkPeer, msg: Message
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let conn = await self.connect()

  if isNil(conn):
    warn "Unable to get send connection for peer message not sent", peer = self.id
    return

  trace "Sending message", peer = self.id, connId = conn.oid
  try:
    await conn.writeLp(protobufEncode(msg))
  except CatchableError as err:
    if self.sendConn == conn:
      self.sendConn = nil
    raise newException(LPStreamError, "Failed to send message: " & err.msg)

func new*(
    T: type NetworkPeer,
    peer: PeerId,
    connProvider: ConnProvider,
    rpcHandler: RPCHandler,
): NetworkPeer =
  doAssert(not isNil(connProvider), "should supply connection provider")

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler,
    trackedFutures: TrackedFutures(),
  )
