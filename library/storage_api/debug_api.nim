import chronos
import chronicles
import results
import ffi
import ../declare_lib
import ../../storage/conf
import ../../storage/rest/json
import ../../storage/node
import ../../storage/discovery

from ../../storage/storage import StorageServer, node

logScope:
  topics = "libstorage debug"

proc storage_debug(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the P2P node information as JSON.
  let nodeInfo = %DebugInfo.init(
    self.node, self.autonatService, self.autoRelayService, self.natMapper
  )

  return ok($nodeInfo)

proc storage_peer_debug(
    self: Storage, peerId: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns a peer record as JSON. Needs the storage_enable_api_debug_peers flag.
  when storage_enable_api_debug_peers:
    let id = PeerId.init(peerId).valueOr:
      return err("Failed to get peer: invalid peer ID " & peerId & ": " & $error)

    try:
      let peerRecord = await self.node.findPeer(id)
      if peerRecord.isNone:
        return err("Failed to get peer: peer not found")

      return ok($ %RestPeerRecord.init(peerRecord.get()))
    except CancelledError:
      return err("Failed to get peer: operation cancelled")
    except CatchableError as e:
      return err("Failed to get peer: " & e.msg)
  else:
    return err("Failed to get peer: peer debug API is disabled")

proc storage_log_level(
    self: Storage, logLevel: string
): Future[Result[string, string]] {.ffi.} =
  ## Sets the log level at run time: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL.
  try:
    {.gcsafe.}:
      updateLogLevel(logLevel)
  except ValueError as e:
    return err("Failed to update log level: invalid value for log level: " & e.msg)

  return ok("")
