import ffi
import ./declare_lib

proc onDownloadChunk*(cid: string, data: seq[byte]) {.ffiEvent: "on_download_chunk".} =
  ## Fired by `storage_download_stream` for every chunk read off the wire.

proc onUploadProgress*(
    sessionId: string, storedBytes: int
) {.ffiEvent: "on_upload_progress".} =
  ## Fired by `storage_upload_file` each time a block reaches the local store.
