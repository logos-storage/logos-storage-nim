import ffi

from ../storage/storage import StorageServer

type Storage* = StorageServer
  ## The generated C types take their names from this alias: `StorageCtx`, not `StorageServerCtx`.

declareLibrary("storage", Storage)
