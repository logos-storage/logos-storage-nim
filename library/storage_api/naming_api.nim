import chronos
import chronicles
import results
import ffi
import libp2p
import ../declare_lib
import ../../storage/naming/dht
import ../../storage/naming/publisher
import ../../storage/utils/nameutils

from ../../storage/storage import StorageServer, node, namePublisher
from ../../storage/node import discovery

logScope:
  topics = "libstorage naming"

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

    return ok(nameKeyString(signed))
  except CancelledError:
    return err("Failed to publish the name: operation cancelled.")

proc storage_name_stop_publishing(
    self: Storage, label: string
): Future[Result[string, string]] {.ffi.} =
  ## Deletes the stored name record of the label.
  try:
    (await self.namePublisher.stopPublishing(label)).isOkOr:
      return err("Failed to stop publishing the name: " & error.msg)
  except CancelledError:
    return err("Failed to stop publishing the name: operation cancelled.")

  return ok("")

proc storage_name_refresh(
    self: Storage, nameKey: string, record: string
): Future[Result[string, string]] {.ffi.} =
  ## Advertises the signed name record, in base64url, in the DHT.
  let name = parseName(nameKey).valueOr:
    return err("Failed to refresh the name: " & error.msg)

  try:
    (await self.node.discovery.refreshName(name, record)).isOkOr:
      return err("Failed to refresh the name: " & error.msg)
  except CancelledError:
    return err("Failed to refresh the name: operation cancelled.")

  return ok("")

proc storage_name_resolve(
    self: Storage, nameKey: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the CID of the name key, or an empty string when the DHT doesn't
  ## have a name record.
  let name = parseName(nameKey).valueOr:
    return err("Failed to resolve the name: " & error.msg)

  try:
    let cid = (await self.node.discovery.resolve(name)).valueOr:
      return err("Failed to resolve the name: " & error.msg)

    if cid.isNone:
      return ok("")

    return ok($cid.get())
  except CancelledError:
    return err("Failed to resolve the name: operation cancelled.")

proc storage_name_is_key(
    self: Storage, nameKey: string
): Future[Result[string, string]] {.ffi.} =
  ## Reports whether the string is a name key.
  let isKey = parseName(nameKey).isOk

  return ok($isKey)

proc storage_name_resolve_key(
    self: Storage, peerId: string, label: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the CID of the name that the peer publishes for the label, or an
  ## empty string when the DHT doesn't have a name record.
  let publicKey = parsePublicKey(peerId).valueOr:
    return err("Failed to resolve the name: " & error.msg)

  try:
    let cid = (await self.node.discovery.resolve(publicKey, label)).valueOr:
      return err("Failed to resolve the name: " & error.msg)

    if cid.isNone:
      return ok("")

    return ok($cid.get())
  except CancelledError:
    return err("Failed to resolve the name: operation cancelled.")
