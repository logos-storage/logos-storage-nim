import std/[options, sequtils]
import chronos
import chronicles
import results
import ffi
import libp2p
import ../declare_lib
import ../../storage/node

from ../../storage/storage import StorageServer, node

logScope:
  topics = "libstorage p2p"

proc resolveAddresses(
    self: Storage, id: PeerId, peerAddresses: seq[string]
): Future[Result[seq[MultiAddress], string]] {.async: (raises: []).} =
  if peerAddresses.len > 0:
    var addrs: seq[MultiAddress]
    for addrStr in peerAddresses:
      let parsed = MultiAddress.init(addrStr).valueOr:
        return err("Failed to connect to peer: invalid address: " & addrStr)
      addrs.add(parsed)
    return ok(addrs)

  try:
    let peerRecord = await self.node.findPeer(id)
    if peerRecord.isNone:
      return err("Failed to connect to peer: peer not found.")

    return ok(peerRecord.get().addresses.mapIt(it.address))
  except CancelledError:
    return err("Failed to connect to peer: operation cancelled.")
  except CatchableError as e:
    return err("Failed to connect to peer: " & e.msg)

proc storage_connect(
    self: Storage, peerId: string, peerAddresses: seq[string]
): Future[Result[string, string]] {.ffi.} =
  ## Connects over `peerAddresses`, or looks them up in the DHT when the list is empty.
  let id = PeerId.init(peerId).valueOr:
    return err("Failed to connect to peer: invalid peer ID: " & $error)

  let addresses = (await self.resolveAddresses(id, peerAddresses)).valueOr:
    return err(error)

  try:
    await self.node.connect(id, addresses)
  except CancelledError:
    return err("Failed to connect to peer: operation cancelled.")
  except CatchableError as e:
    return err("Failed to connect to peer: " & e.msg)

  return ok("")
