{.push raises: [].}

## This file contains the debug info available with Logos Storage.
## The DEBUG type will return info about the P2P node.
## The PEER type is available only with storage_enable_api_debug_peers flag.
## It will return info about a specific peer if available.

import chronos
import chronicles
import ../../alloc
import ../../../storage/conf
import ../../../storage/rest/json
import ../../../storage/node

from ../../../storage/storage import StorageServer, node, config
import ../../../storage/discovery

logScope:
  topics = "libstorage libstoragedebug"

type NodeDebugMsgType* = enum
  DEBUG
  PEER
  LOG_LEVEL

type NodeDebugRequest* = object
  operation: NodeDebugMsgType
  peerId: cstring
  logLevel: cstring

proc createShared*(
    T: type NodeDebugRequest,
    op: NodeDebugMsgType,
    peerId: cstring = "",
    logLevel: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].logLevel = logLevel.alloc()
  return ret

proc destroyShared*(self: ptr NodeDebugRequest) =
  deallocShared(self[].peerId)
  deallocShared(self[].logLevel)
  deallocShared(self)

proc getDebug(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let nodeInfo = %DebugInfo.init(
    storage[].node, storage[].autonatService, storage[].autoRelayService,
    storage[].natMapper,
  )
  return ok($nodeInfo)

proc getPeer(
    storage: ptr StorageServer, peerId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  when storage_enable_api_debug_peers:
    let node = storage[].node
    let res = PeerId.init($peerId)
    if res.isErr:
      return err("Failed to get peer: invalid peer ID " & $peerId & ": " & $res.error())

    let id = res.get()

    try:
      let peerRecord = await node.findPeer(id)
      if peerRecord.isNone:
        return err("Failed to get peer: peer not found")

      return ok($ %RestPeerRecord.init(peerRecord.get()))
    except CancelledError:
      return err("Failed to get peer: operation cancelled")
    except CatchableError as e:
      return err("Failed to get peer: " & e.msg)
  else:
    return err("Failed to get peer: peer debug API is disabled")

proc updateLogLevel(
    storage: ptr StorageServer, logLevel: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  try:
    {.gcsafe.}:
      updateLogLevel($logLevel)
  except ValueError as err:
    return err("Failed to update log level: invalid value for log level: " & err.msg)

  return ok("")

proc process*(
    self: ptr NodeDebugRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  # LOG_LEVEL does not require a node.
  if storage[].isNil and self.operation != NodeDebugMsgType.LOG_LEVEL:
    const msg = "Failed to process: the node is not created."
    error msg
    return err(msg)

  case self.operation
  of NodeDebugMsgType.DEBUG:
    let res = (await getDebug(storage))
    if res.isErr:
      error "Failed to get DEBUG.", error = res.error
      return err($res.error)
    return res
  of NodeDebugMsgType.PEER:
    let res = (await getPeer(storage, self.peerId))
    if res.isErr:
      error "Failed to get PEER.", error = res.error
      return err($res.error)
    return res
  of NodeDebugMsgType.LOG_LEVEL:
    let res = (await updateLogLevel(storage, self.logLevel))
    if res.isErr:
      error "Failed to update LOG_LEVEL.", error = res.error
      return err($res.error)
    return res
