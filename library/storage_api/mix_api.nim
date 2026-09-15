import chronos
import chronicles
import results
import ffi
import ../declare_lib
import ../../storage/node

from ../../storage/storage import StorageServer, node

logScope:
  topics = "libstorage mix"

proc storage_toggle_private_queries(
    self: Storage, enabled: bool
): Future[Result[string, string]] {.ffi.} =
  ## Toggles mix-routed queries and returns the previous setting.
  let previous = self.node.togglePrivateQueries(enabled).valueOr:
    return err(error.msg)

  return ok($previous)
