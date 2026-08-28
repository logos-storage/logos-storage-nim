import chronos
import chronicles
import results
import ffi
import ../declare_lib
import ../node_factory
import ./upload_api
import ./download_api

from ../../storage/storage import StorageServer, start, stop, close

logScope:
  topics = "libstorage lifecycle"

proc storage_new(configJson: string): Future[Result[Storage, string]] {.ffiCtor.} =
  ## Creates a node from a JSON configuration that overrides the defaults.
  resetUploadSessions()
  resetDownloadSessions()

  let server = (await createStorage(configJson)).valueOr:
    error "Failed to create the node.", error = error
    return err(error)

  return ok(server)

proc storage_start(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Starts the node. Starting a running node is a no-op.
  try:
    await self.start()
  except Exception as e:
    error "Failed to start the node.", error = e.msg
    return err("Failed to start the node: " & e.msg)

  return ok("")

proc storage_stop(self: Storage): Future[Result[string, string]] {.ffi.} =
  ## Stops the node without releasing it. It can be started again.
  try:
    await self.stop()
  except Exception as e:
    error "Failed to stop the node.", error = e.msg
    return err("Failed to stop the node: " & e.msg)

  return ok("")

proc storage_destroy(self: Storage) {.ffiDtor.} =
  ## Stops the node, releases it and tears the FFI context down.
  try:
    await self.stop()
    await self.close()
  except Exception as e:
    error "Failed to close the node.", error = e.msg
