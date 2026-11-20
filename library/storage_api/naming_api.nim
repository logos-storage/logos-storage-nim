import chronos
import chronicles
import results
import ffi
import libp2p
import ../declare_lib
import ../../storage/naming/dht
import ../../storage/naming/publisher

from ../../storage/storage import StorageServer, node, namePublisher
from ../../storage/node import discovery

logScope:
  topics = "libstorage naming"

proc parseName(nameKey: string): Result[Name, string] =
  ## The name of a DHT key encoded as a CID string.
  let cid = Cid.init(nameKey).valueOr:
    return err("invalid name key: " & $error)

  let parsed = nameFromNameKey(cid.data.buffer).valueOr:
    return err("invalid name key: " & error.msg)

  return ok(parsed)

proc parsePublicKey(peerId: string): Result[PublicKey, string] =
  ## The public key of a peer ID string.
  let id = PeerId.init(peerId).valueOr:
    return err("invalid peer ID: " & $error)

  var publicKey: PublicKey

  if not id.extractPublicKey(publicKey):
    return err("the peer ID has no public key")

  return ok(publicKey)

proc storage_name_publish(
    self: Storage, label: string, cid: string, seqnum: uint64
): Future[Result[string, string]] {.ffi.} =
  ## Publishes a name record for the label and returns the name key.
  ## A seqnum of 0 means the current time.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to publish the name: invalid CID: " & $error)

  let sequence =
    if seqnum == 0:
      Opt.none(uint64)
    else:
      Opt.some(seqnum)

  try:
    let signed = (await self.namePublisher.publish(label, parsed, sequence)).valueOr:
      return err("Failed to publish the name: " & error.msg)

    let
      name = signed.name().expect(
          "The publisher built the name record from its own key and a checked label"
        )
      nameCid = Cid.init(nameKey(name)).expect("nameKey builds a valid CID")

    return ok($nameCid)
  except CancelledError:
    return err("Failed to publish the name: operation cancelled.")

proc storage_name_unpublish(
    self: Storage, label: string
): Future[Result[string, string]] {.ffi.} =
  ## Deletes the stored name record of the label.
  try:
    (await self.namePublisher.unpublish(label)).isOkOr:
      return err("Failed to unpublish the name: " & error.msg)
  except CancelledError:
    return err("Failed to unpublish the name: operation cancelled.")

  return ok("")

proc storage_name_refresh(
    self: Storage, nameKey: string
): Future[Result[string, string]] {.ffi.} =
  ## Advertises the name record of the name key in the DHT again.
  let name = parseName(nameKey).valueOr:
    return err("Failed to refresh the name: " & error)

  try:
    (await self.node.discovery.refresh(name)).isOkOr:
      return err("Failed to refresh the name: " & error.msg)
  except CancelledError:
    return err("Failed to refresh the name: operation cancelled.")

  return ok("")

proc storage_name_resolve(
    self: Storage, nameKey: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the CID of the name key, or an empty string when the DHT has no
  ## name record.
  let name = parseName(nameKey).valueOr:
    return err("Failed to resolve the name: " & error)

  try:
    let cid = (await self.node.discovery.resolve(name)).valueOr:
      return err("Failed to resolve the name: " & error.msg)

    if cid.isNone:
      return ok("")

    return ok($cid.get())
  except CancelledError:
    return err("Failed to resolve the name: operation cancelled.")

proc storage_name_resolve_key(
    self: Storage, peerId: string, label: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the CID of the name that the peer publishes for the label, or an
  ## empty string when the DHT has no name record.
  let publicKey = parsePublicKey(peerId).valueOr:
    return err("Failed to resolve the name: " & error)

  try:
    let cid = (await self.node.discovery.resolve(publicKey, label)).valueOr:
      return err("Failed to resolve the name: " & error.msg)

    if cid.isNone:
      return ok("")

    return ok($cid.get())
  except CancelledError:
    return err("Failed to resolve the name: operation cancelled.")
