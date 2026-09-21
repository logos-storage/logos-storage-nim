## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Logos Storage Thread.

import results
import chronos
import ../ffi_types
import ./requests/node_lifecycle_request
import ./requests/node_info_request
import ./requests/node_debug_request
import ./requests/node_p2p_request
import ./requests/node_upload_request
import ./requests/node_download_request
import ./requests/node_storage_request
import ./requests/node_mix_request

from ../../storage/storage import StorageServer

type RequestType* {.pure.} = enum
  LIFECYCLE
  INFO
  DEBUG
  P2P
  UPLOAD
  DOWNLOAD
  STORAGE

type StorageThreadRequest* = object
  reqType: RequestType

  # Request payloed
  reqContent: pointer

  # Callback to notify the client thread of the result
  callback: StorageCallback

  # Custom state attached by the client to the request,
  # returned when its callback is invoked.
  userData: pointer

proc createShared*(
    T: type StorageThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: StorageCallback,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

proc destroy*(request: ptr StorageThreadRequest) =
  ## Frees the payload (reqContent) and the wrapper on error paths,
  ## when the request is not handed to the storage thread.
  ## On success paths, the storage thread frees the payload and the wrapper.
  case request[].reqType
  of LIFECYCLE:
    cast[ptr NodeLifecycleRequest](request[].reqContent).destroyShared()
  of INFO:
    cast[ptr NodeInfoRequest](request[].reqContent).destroyShared()
  of RequestType.DEBUG:
    cast[ptr NodeDebugRequest](request[].reqContent).destroyShared()
  of P2P:
    cast[ptr NodeP2PRequest](request[].reqContent).destroyShared()
  of UPLOAD:
    cast[ptr NodeUploadRequest](request[].reqContent).destroyShared()
  of DOWNLOAD:
    cast[ptr NodeDownloadRequest](request[].reqContent).destroyShared()
  of STORAGE:
    cast[ptr NodeStorageRequest](request[].reqContent).destroyShared()

  deallocShared(request)

# NOTE: User callbacks are executed on the working thread.
# They must be fast and non-blocking; otherwise this thread will be blocked
# and no further requests can be processed.
# We can improve this by dispatching the callbacks to a thread pool or
# moving to a MP channel.
# See: https://github.com/logos-storage/logos-storage-nim/pull/1322#discussion_r2340708316
proc handleRes(res: Result[string, string], request: ptr StorageThreadRequest) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].
  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = $res.error
      if msg == "":
        request[].callback(RET_ERR, nil, cast[csize_t](0), request[].userData)
      else:
        request[].callback(
          RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
        )
    return

  foreignThreadGc:
    let msg = res.get()
    if msg.len == 0:
      request[].callback(RET_OK, nil, cast[csize_t](0), request[].userData)
    else:
      request[].callback(
        RET_OK, unsafeAddr msg[0], cast[csize_t](msg.len), request[].userData
      )
  return

proc process*(
    T: type StorageThreadRequest,
    request: ptr StorageThreadRequest,
    storage: ptr StorageServer,
) {.async: (raises: []).} =
  ## Processes the request in the Logos Storage thread.
  ## Dispatch to the appropriate request handler based on reqType.
  let retFut =
    case request[].reqType
    of LIFECYCLE:
      cast[ptr NodeLifecycleRequest](request[].reqContent).process(storage)
    of INFO:
      cast[ptr NodeInfoRequest](request[].reqContent).process(storage)
    of RequestType.DEBUG:
      cast[ptr NodeDebugRequest](request[].reqContent).process(storage)
    of P2P:
      cast[ptr NodeP2PRequest](request[].reqContent).process(storage)
    of STORAGE:
      cast[ptr NodeStorageRequest](request[].reqContent).process(storage)
    of DOWNLOAD:
      let onChunk = proc(bytes: seq[byte]) =
        if bytes.len > 0:
          request[].callback(
            RET_PROGRESS,
            cast[ptr cchar](unsafeAddr bytes[0]),
            cast[csize_t](bytes.len),
            request[].userData,
          )

      cast[ptr NodeDownloadRequest](request[].reqContent).process(storage, onChunk)
    of UPLOAD:
      let onBlockReceived = proc(bytes: int) =
        request[].callback(RET_PROGRESS, nil, cast[csize_t](bytes), request[].userData)

      cast[ptr NodeUploadRequest](request[].reqContent).process(
        storage, onBlockReceived
      )

  handleRes(await retFut, request)

proc `$`*(self: StorageThreadRequest): string =
  return $self.reqType
