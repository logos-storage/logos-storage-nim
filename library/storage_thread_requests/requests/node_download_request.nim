{.push raises: [].}

## This file contains the download request.
## A session is created for each download identified by the CID,
## allowing to resume, pause and cancel the download (using chunks).
##
## There are two ways to download a file:
## 1. Via chunks: the cid parameter is the CID of the file to download. Steps are:
##    - INIT: initializes the download session
##    - CHUNK: downloads the next chunk of the file
##    - CANCEL: cancels the download session
## 2. Via stream.
##    - INIT: initializes the download session
##    - STREAM: downloads the file in a streaming manner, calling
## the onChunk handler for each chunk and / or writing to a file if filepath is set.
##    - CANCEL: cancels the download session

import chronos
import chronicles
import libp2p/stream/[lpstream]
import serde/json as serde
import ../../alloc
import ../../../storage/storagetypes
import ../../../storage/downloadtransport

from ../../../storage/storage import StorageServer, node
from ../../../storage/node import retrieve, fetchManifest
from ../../../storage/rest/json import `%`, RestContent
from libp2p import Cid, init, `$`

logScope:
  topics = "libstorage libstoragedownload"

type NodeDownloadMsgType* = enum
  INIT
  CHUNK
  STREAM
  CANCEL
  MANIFEST

type OnChunkHandler = proc(bytes: seq[byte]): void {.gcsafe, raises: [].}

type NodeDownloadRequest* = object
  operation: NodeDownloadMsgType
  cid: cstring
  chunkSize: csize_t
  local: bool
  isPrivate: bool
  filepath: cstring
  advertise: bool

type
  DownloadSessionId* = string
  DownloadSessionCount* = int
  DownloadSession* = object
    stream: LPStream
    chunkSize: int
    isPrivate: bool

var downloadSessions {.threadvar.}:
  tuple[lock: AsyncLock, sessions: Table[DownloadSessionId, DownloadSession]]

proc sessionTableLock(): AsyncLock =
  if downloadSessions.lock.isNil:
    downloadSessions.lock = newAsyncLock()
  downloadSessions.lock

proc createShared*(
    T: type NodeDownloadRequest,
    op: NodeDownloadMsgType,
    cid: cstring = "",
    chunkSize: csize_t = 0,
    local: bool = false,
    isPrivate: bool = false,
    filepath: cstring = "",
    advertise: bool = true,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()
  ret[].chunkSize = chunkSize
  ret[].local = local
  ret[].isPrivate = isPrivate
  ret[].filepath = filepath.alloc()
  ret[].advertise = advertise

  return ret

proc destroyShared*(self: ptr NodeDownloadRequest) =
  deallocShared(self[].cid)
  deallocShared(self[].filepath)
  deallocShared(self)

proc init(
    storage: ptr StorageServer,
    cCid: cstring = "",
    chunkSize: csize_t = 0,
    local: bool,
    isPrivate: bool,
    advertise: bool,
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Init a new session to download the file identified by cid.
  ##
  ## If the session already exists, do nothing and return ok.
  ## Meaning that a cid can only have one active download session.
  ## If the chunkSize is 0, the default block size will be used.
  ## If local is true, the file will be retrived from the local store.
  ## If isPrivate is true, uses mix to run queries and download the data.

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to download locally: cannot parse cid: " & $cCid)

  # Coarse lock which blocks two download sessions from being created concurrently.
  # Prevents a second caller from entering and creating another session while we're
  # blocked in node.retrieve.
  try:
    await sessionTableLock().acquire()
  except CancelledError as ex:
    return err("Could not acquire session table lock - cancelled")

  defer:
    try:
      sessionTableLock().release()
    except AsyncLockError:
      # shouldn't happen
      doAssert false, "lock released twice"

  downloadSessions.sessions.withValue($cid, session):
    if session.isPrivate != isPrivate:
      return err("Download privacy setting does not match the existing session.")
    return ok("Download session already exists.")

  let node = storage[].node
  var stream: LPStream

  try:
    let transport = if isPrivate: DownloadTransport.Mix else: DownloadTransport.Direct
    let res = await node.retrieve(cid.get(), local, advertise, transport)
    if res.isErr():
      return err("Failed to init the download: " & res.error.msg)
    stream = res.get()
  except CancelledError:
    downloadSessions.sessions.del($cid)
    return err("Failed to init the download: download cancelled.")

  let blockSize = if chunkSize.int > 0: chunkSize.int else: DefaultBlockSize.int
  downloadSessions.sessions[$cid] =
    DownloadSession(stream: stream, chunkSize: blockSize, isPrivate: isPrivate)

  return ok("")

proc chunk(
    storage: ptr StorageServer, cCid: cstring = "", onChunk: OnChunkHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Download the next chunk of the file identified by cid.
  ## The chunk is passed to the onChunk handler.
  ##
  ## If the stream is at EOF, return ok with empty string.
  ##
  ## If an error is raised while reading the stream, the session is deleted
  ## and an error is returned.

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to download locally: cannot parse cid: " & $cCid)

  if not downloadSessions.sessions.contains($cid):
    return err("Failed to download chunk: no session for cid " & $cid)

  var session: DownloadSession
  try:
    session = downloadSessions.sessions[$cid]
  except KeyError:
    return err("Failed to download chunk: no session for cid " & $cid)

  let stream = session.stream
  if stream.atEof:
    return ok("")

  let chunkSize = session.chunkSize
  var buf = newSeq[byte](chunkSize)

  try:
    let read = await stream.readOnce(addr buf[0], buf.len)
    buf.setLen(read)
  except LPStreamError as e:
    await stream.close()
    downloadSessions.sessions.del($cid)
    return err("Failed to download chunk: " & $e.msg)
  except CancelledError:
    await stream.close()
    downloadSessions.sessions.del($cid)
    return err("Failed to download chunk: download cancelled.")

  if buf.len <= 0:
    return err("Failed to download chunk: no data")

  onChunk(buf)

  return ok("")

proc streamData(
    storage: ptr StorageServer,
    stream: LPStream,
    onChunk: OnChunkHandler,
    chunkSize: csize_t,
    filepath: cstring,
): Future[Result[string, string]] {.
    async: (raises: [CancelledError, LPStreamError, IOError])
.} =
  let blockSize = if chunkSize.int > 0: chunkSize.int else: DefaultBlockSize.int
  var buf = newSeq[byte](blockSize)
  var read = 0
  var outputStream: OutputStreamHandle
  var filedest: string = $filepath

  try:
    if filepath != "":
      outputStream = filedest.fileOutput()

    while not stream.atEof:
      ## Yield immediately to the event loop
      ## It gives a chance to cancel request to be processed
      await sleepAsync(0.milliseconds)

      let read = await stream.readOnce(addr buf[0], buf.len)
      buf.setLen(read)

      if buf.len <= 0:
        break

      onChunk(buf)

      if outputStream != nil:
        outputStream.write(buf)

    if outputStream != nil:
      outputStream.close()
  finally:
    if outputStream != nil:
      outputStream.close()

  return ok("")

proc stream(
    storage: ptr StorageServer,
    cCid: cstring,
    chunkSize: csize_t,
    filepath: cstring,
    onChunk: OnChunkHandler,
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Stream the file identified by cid, calling the onChunk handler for each chunk
  ## and / or writing to a file if filepath is set.
  ##

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to stream: cannot parse cid: " & $cCid)

  if not downloadSessions.sessions.contains($cid):
    return err("Failed to stream: no session for cid " & $cid)

  var session: DownloadSession
  try:
    session = downloadSessions.sessions[$cid]
  except KeyError:
    return err("Failed to stream: no session for cid " & $cid)

  try:
    let res =
      await noCancel storage.streamData(session.stream, onChunk, chunkSize, filepath)
    if res.isErr:
      return err($res.error)
  except LPStreamError as e:
    return err("Failed to stream file: " & $e.msg)
  except IOError as e:
    return err("Failed to stream file: " & $e.msg)
  finally:
    if session.stream != nil:
      await session.stream.close()
    downloadSessions.sessions.del($cid)

  return ok("")

proc cancel(
    storage: ptr StorageServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Cancel the download session identified by cid.
  ## This operation is not supported when using the stream mode,
  ## because the worker will be busy downloading the file.

  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to cancel : cannot parse cid: " & $cCid)

  if not downloadSessions.sessions.contains($cid):
    # The session is already cancelled
    return ok("")

  var session: DownloadSession
  try:
    session = downloadSessions.sessions[$cid]
  except KeyError:
    # The session is already cancelled
    return ok("")

  let stream = session.stream
  await stream.close()
  downloadSessions.sessions.del($cid)

  return ok("")

proc manifest(
    storage: ptr StorageServer, cCid: cstring, isPrivate: bool, advertise: bool
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to fetch manifest: cannot parse cid: " & $cCid)

  try:
    let node = storage[].node
    let transport = if isPrivate: DownloadTransport.Mix else: DownloadTransport.Direct
    let manifest = await node.fetchManifest(cid.get(), advertise, transport)
    if manifest.isErr:
      return err("Failed to fetch manifest: " & manifest.error.msg)

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch manifest: download cancelled.")

proc process*(
    self: ptr NodeDownloadRequest, storage: ptr StorageServer, onChunk: OnChunkHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  if storage[].isNil:
    const msg = "Failed to process: the node is not created."
    error msg
    return err(msg)

  case self.operation
  of NodeDownloadMsgType.INIT:
    let res = (
      await init(
        storage, self.cid, self.chunkSize, self.local, self.isPrivate, self.advertise
      )
    )
    if res.isErr:
      error "Failed to INIT.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.CHUNK:
    let res = (await chunk(storage, self.cid, onChunk))
    if res.isErr:
      error "Failed to CHUNK.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.STREAM:
    let res = (await stream(storage, self.cid, self.chunkSize, self.filepath, onChunk))
    if res.isErr:
      error "Failed to STREAM.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.CANCEL:
    let res = (await cancel(storage, self.cid))
    if res.isErr:
      error "Failed to CANCEL.", error = res.error
      return err($res.error)
    return res
  of NodeDownloadMsgType.MANIFEST:
    let res = (await manifest(storage, self.cid, self.isPrivate, self.advertise))
    if res.isErr:
      error "Failed to MANIFEST.", error = res.error
      return err($res.error)
    return res
