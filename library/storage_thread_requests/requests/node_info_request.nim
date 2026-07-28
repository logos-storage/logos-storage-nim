## This file contains the lifecycle request type that will be handled.

import chronos
import chronicles
import confutils
import metrics
import ../../logosmetrics
import ../../../storage/conf
import ../../../storage/rest/json
import ../../../storage/node

from ../../../storage/storage import StorageServer, config, node
import ../../../storage/discovery

logScope:
  topics = "libstorage libstorageinfo"

type NodeInfoMsgType* = enum
  REPO
  SPR
  PEERID
  # Not sure this belongs here but for now OK.
  METRICS

type NodeInfoRequest* = object
  operation: NodeInfoMsgType

proc createShared*(T: type NodeInfoRequest, op: NodeInfoMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared*(self: ptr NodeInfoRequest) =
  deallocShared(self)

proc getRepo(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($(storage[].config.dataDir))

proc getSpr(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  let spr = storage[].node.discovery.getSpr()
  if spr.isErr:
    return err(spr.error.msg)
  return ok(spr.get())

proc getPeerId(
    storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  return ok($storage[].node.switch.peerInfo.peerId)

proc process*(
    self: ptr NodeInfoRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  # METRICS does not need a node.
  if storage[].isNil and self.operation != METRICS:
    const msg = "Failed to process: the node is not created."
    error msg
    return err(msg)

  case self.operation
  of REPO:
    let res = (await getRepo(storage))
    if res.isErr:
      error "Failed to get REPO.", error = res.error
      return err($res.error)
    return res
  of SPR:
    let res = (await getSpr(storage))
    if res.isErr:
      error "Failed to get SPR.", error = res.error
      return err($res.error)
    return res
  of PEERID:
    let res = (await getPeerId(storage))
    if res.isErr:
      error "Failed to get PEERID.", error = res.error
      return err($res.error)
    return res
  of METRICS:
    # We're making a few assumptions here, which need to be double-checked:
    # 1. That defaultRegistry and all collectors we're using were
    #    created on the host thread that called libstorageNimMain as globals
    #    were initialized.
    # 2. That collectors themselves are thread-safe.
    # 3. That reading from defaultRegistry from this (worker) thread is safe.
    #
    # For (3) in particular, we lean on chronos_httpserver which does the exact
    # thing we are doing here: reading defaultRegistry and its collectors and
    # metrics from another thread.
    #
    # TODO double-check these assumptions.
    {.cast(gcsafe).}:
      # Excludes nim_runtime_info as dumpHeapInstances seems to be returning
      # an infinite number of objects (could be related to some assumption
      # failure above).
      # FIXME figure out what's going on and add this back.
      return ok($defaultRegistry.toJson(exclude = @["nim_runtime_info"], prefix = true))
