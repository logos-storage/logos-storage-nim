import ffi

from ../storage/storage import StorageServer

type Storage* = StorageServer
  ## The generated C types are named after this alias: `StorageCtx`, not `StorageServerCtx`.

declareLibrary("storage", Storage)
