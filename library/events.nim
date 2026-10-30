import ffi
import ./declare_lib

proc onDownloadChunk*(cid: string, data: seq[byte]) {.ffiEvent: "on_download_chunk".} =
  ## `storage_download_stream` fires this for each chunk that it reads.

proc onDownloadDone*(cid: string, error: string) {.ffiEvent: "on_download_done".} =
  ## `storage_download_stream` fires this last. An empty `error` means success.

proc onUploadProgress*(
    sessionId: string, storedBytes: int
) {.ffiEvent: "on_upload_progress".} =
  ## `storage_upload_file` fires this each time a block reaches the local store.
