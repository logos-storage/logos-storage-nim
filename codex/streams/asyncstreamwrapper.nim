## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import pkg/chronos
import pkg/libp2p

import ../logutils

logScope:
  topics = "libp2p asyncstreamwrapper"

const AsyncStreamWrapperName* = "AsyncStreamWrapper"

type AsyncStreamWrapper* = ref object of LPStream
  reader*: AsyncStreamReader
  writer*: AsyncStreamWriter

method initStream*(self: AsyncStreamWrapper) =
  if self.objName.len == 0:
    self.objName = AsyncStreamWrapperName

  procCall LPStream(self).initStream()

proc new*(
    C: type AsyncStreamWrapper,
    reader: AsyncStreamReader = nil,
    writer: AsyncStreamWriter = nil,
): AsyncStreamWrapper =
  ## Create new instance of an asynchronous stream wrapper
  ##
  let stream = C(reader: reader, writer: writer)

  stream.initStream()
  return stream

template withExceptions(body: untyped) =
  try:
    body
  except CancelledError as exc:
    raise exc
  except AsyncStreamIncompleteError:
    # for all intents and purposes this is an EOF
    raise newLPStreamIncompleteError()
  except AsyncStreamLimitError:
    raise newLPStreamLimitError()
  except AsyncStreamUseClosedError:
    raise newLPStreamEOFError()
  except AsyncStreamError as exc:
    raise newException(LPStreamError, exc.msg)
  except CatchableError as exc:
    raise newException(Defect, "Unexpected error in AsyncStreamWrapper", exc)

method readOnce*(
    self: AsyncStreamWrapper, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Reading bytes from reader", bytes = nbytes
  if isNil(self.reader):
    error "Async stream wrapper reader nil"
    raiseAssert("Async stream wrapper reader nil")

  if self.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    return await self.reader.readOnce(pbytes, nbytes)

proc completeWrite(
    self: AsyncStreamWrapper, fut: Future[void], msgLen: int
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  withExceptions:
    await fut

method write*(
    self: AsyncStreamWrapper, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  # Avoid a copy of msg being kept in the closure created by `{.async.}` as this
  # drives up memory usage

  trace "Writing bytes to writer", bytes = msg.len
  if isNil(self.writer):
    error "Async stream wrapper writer nil"
    raiseAssert("Async stream wrapper writer nil")

  if self.closed:
    let fut = newFuture[void]("asyncstreamwrapper.write.closed")
    fut.fail(newLPStreamClosedError())
    return fut

  self.completeWrite(self.writer.write(msg, msg.len), msg.len)

method closed*(self: AsyncStreamWrapper): bool =
  var
    readerClosed = true
    writerClosed = true

  if not isNil(self.reader):
    readerClosed = self.reader.closed

  if not isNil(self.writer):
    writerClosed = self.writer.closed

  return readerClosed and writerClosed

method atEof*(self: AsyncStreamWrapper): bool =
  self.reader.atEof()

method closeImpl*(self: AsyncStreamWrapper) {.async: (raises: []).} =
  try:
    trace "Shutting down async chronos stream"
    if not self.closed():
      if not isNil(self.reader) and not self.reader.closed():
        await self.reader.closeWait()

      if not isNil(self.writer) and not self.writer.closed():
        await self.writer.closeWait()

    trace "Shutdown async chronos stream"
  except CancelledError as exc:
    error "Error received cancelled error when closing chronos stream", msg = exc.msg
  except CatchableError as exc:
    trace "Error closing async chronos stream", msg = exc.msg

  await procCall LPStream(self).closeImpl()
