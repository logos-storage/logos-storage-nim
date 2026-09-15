import chronos
import chronicles
import results
import ffi
import confutils
import metrics
import ../declare_lib
import ../logosmetrics
import ../../storage/conf
import ../../storage/node
import ../../storage/discovery

from ../../storage/storage import StorageServer, config, node

logScope:
  topics = "libstorage info"

proc storage_version(): string {.ffi.} =
  ## Synchronous. The buffer is thread-local and lives until the next call, so copy it.
  conf.storageVersion

proc storage_revision(): string {.ffi.} =
  ## Synchronous, same buffer contract as `storage_version`.
  conf.storageRevision

proc storage_repo(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the data directory the node stores into.
  return ok($(self.config.dataDir))

proc storage_spr(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the node's Signed Peer Record as a URI.
  let spr = self.node.discovery.getSpr().valueOr:
    return err(error.msg)

  return ok(spr)

proc storage_peer_id(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the node's libp2p peer identity.
  return ok($self.node.switch.peerInfo.peerId)

proc storage_network(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the name of the configured network preset, such as "logos.test".
  return ok(self.config.network.name)

proc storage_get_metrics(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Returns the process metrics registry as JSON.
  # nim_runtime_info is excluded: dumpHeapInstances returns an endless object count here.
  {.cast(gcsafe).}:
    return ok($defaultRegistry.toJson(exclude = @["nim_runtime_info"], prefix = true))
