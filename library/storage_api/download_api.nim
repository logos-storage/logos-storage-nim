import std/tables
import chronos
import chronicles
import results
import ffi
import libp2p/stream/[lpstream]
import serde/json as serde
import ../declare_lib
import ../events
import ../../storage/storagetypes
import ../../storage/downloadtransport

from ../../storage/storage import StorageServer, node
from ../../storage/node import retrieve, fetchManifest
from libp2p import Cid, init, `$`

logScope:
  topics = "libstorage download"

type
  DownloadSessionId = string
  DownloadSession = object
    stream: LPStream
    chunkSize: int
    isPrivate: bool

var downloadSessions {.threadvar.}: Table[DownloadSessionId, DownloadSession]
var downloadSessionsLock {.threadvar.}: AsyncLock

proc resetDownloadSessions*() =
  ## The ctor calls this: nim-ffi hands a recycled FFI thread to the next context.
  downloadSessions.clear()
  downloadSessionsLock = newAsyncLock()

proc openDownload(
    self: Storage,
    cid: Cid,
    chunkSize: uint64,
    local: bool,
    isPrivate: bool,
    advertise: bool,
): Future[Result[DownloadSession, string]] {.async: (raises: []).} =
  # Held across retrieve, so a second caller cannot open a duplicate session meanwhile.
  try:
    await downloadSessionsLock.acquire()
  except CancelledError:
    return err("Failed to init the download: download cancelled.")
  defer:
    try:
      downloadSessionsLock.release()
    except AsyncLockError:
      raiseAssert "download session lock released twice"

  downloadSessions.withValue($cid, session):
    if session.isPrivate != isPrivate:
      return err("Download privacy setting does not match the existing session.")
    return ok(session[])

  let transport = if isPrivate: DownloadTransport.Mix else: DownloadTransport.Direct
  var stream: LPStream
  try:
    let res = await self.node.retrieve(cid, local, advertise, transport)
    if res.isErr():
      return err("Failed to init the download: " & res.error.msg)
    stream = res.get()
  except CancelledError:
    return err("Failed to init the download: download cancelled.")

  let blockSize = if chunkSize.int > 0: chunkSize.int else: DefaultBlockSize.int
  let session =
    DownloadSession(stream: stream, chunkSize: blockSize, isPrivate: isPrivate)
  downloadSessions[$cid] = session

  return ok(session)

proc storage_download_init(
    self: Storage,
    cid: string,
    chunkSize: uint64,
    local: bool,
    isPrivate: bool,
    advertise: bool,
): Future[Result[string, string]] {.ffi.} =
  ## Opens the single download session for `cid`. `local` reads the local store only.
  ## `isPrivate` downloads over Mix and must match an open session for `cid`.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to init the download: cannot parse cid: " & cid)

  (await self.openDownload(parsed, chunkSize, local, isPrivate, advertise)).isOkOr:
    return err(error)

  return ok("")

proc storage_download_chunk(
    self: Storage, cid: string
): Future[Result[seq[byte], string]] {.ffi.} =
  ## Reads the next chunk of `cid`. An empty reply means the stream is at EOF.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to download chunk: cannot parse cid: " & cid)

  var session: DownloadSession
  try:
    session = downloadSessions[$parsed]
  except KeyError:
    return err("Failed to download chunk: no session for cid " & $parsed)

  let stream = session.stream
  if stream.atEof:
    return ok(newSeq[byte]())

  var buf = newSeq[byte](session.chunkSize)

  try:
    let read = await stream.readOnce(addr buf[0], buf.len)
    buf.setLen(read)
  except LPStreamError as e:
    await stream.close()
    downloadSessions.del($parsed)
    return err("Failed to download chunk: " & e.msg)
  except CancelledError:
    await stream.close()
    downloadSessions.del($parsed)
    return err("Failed to download chunk: download cancelled.")

  return ok(buf)

proc streamData(
    cid: string, stream: LPStream, chunkSize: int, filepath: string
) {.async: (raises: [CancelledError, LPStreamError, IOError]).} =
  var buf = newSeq[byte](chunkSize)
  var outputStream: OutputStreamHandle

  defer:
    if not outputStream.isNil():
      outputStream.close()

  if filepath != "":
    outputStream = filepath.fileOutput()

  while not stream.atEof:
    # Yield to the event loop so a pending cancel request gets a chance to run.
    await sleepAsync(0.milliseconds)

    let read = await stream.readOnce(addr buf[0], buf.len)
    if read == 0:
      break

    let chunk = buf[0 ..< read]
    onDownloadChunk(cid, chunk)

    if not outputStream.isNil():
      outputStream.write(chunk)

proc storage_download_stream(
    self: Storage, cid: string, chunkSize: uint64, filepath: string
): Future[Result[string, string]] {.ffi.} =
  ## Streams `cid` to `on_download_chunk`, and to `filepath` when it is set.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to stream: cannot parse cid: " & cid)

  let session = (
    await self.openDownload(
      parsed, chunkSize, local = false, isPrivate = false, advertise = true
    )
  ).valueOr:
    return err(error)

  try:
    await noCancel streamData(cid, session.stream, session.chunkSize, filepath)
  except LPStreamError as e:
    return err("Failed to stream file: " & e.msg)
  except IOError as e:
    return err("Failed to stream file: " & e.msg)
  finally:
    await session.stream.close()
    downloadSessions.del($parsed)

  return ok("")

proc storage_download_cancel(
    self: Storage, cid: string
): Future[Result[string, string]] {.ffi.} =
  ## Closes the download session of `cid`, which also stops a running stream.
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to cancel: cannot parse cid: " & cid)

  var session: DownloadSession
  try:
    session = downloadSessions[$parsed]
  except KeyError:
    return ok("")

  await session.stream.close()
  downloadSessions.del($parsed)

  return ok("")

proc storage_download_manifest(
    self: Storage, cid: string, isPrivate: bool, advertise: bool
): Future[Result[string, string]] {.ffi.} =
  ## Returns the manifest of `cid` as JSON. `isPrivate` fetches it over Mix.
  let transport = if isPrivate: DownloadTransport.Mix else: DownloadTransport.Direct
  let parsed = Cid.init(cid).valueOr:
    return err("Failed to fetch manifest: cannot parse cid: " & cid)

  try:
    let manifest = await self.node.fetchManifest(parsed, advertise, transport)
    if manifest.isErr:
      return err("Failed to fetch manifest: " & manifest.error.msg)

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch manifest: download cancelled.")
