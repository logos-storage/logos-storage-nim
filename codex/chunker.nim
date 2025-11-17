## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: This is super inneficient and needs a rewrite, but it'll do for now

{.push raises: [], gcsafe.}

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p except shuffle

import ./blocktype
import ./logutils

export blocktype

const DefaultChunkSize* = DefaultBlockSize

type
  # default reader type
  ChunkerError* = object of CatchableError
  ChunkBuffer* = ptr UncheckedArray[byte]
  Reader* = proc(data: ChunkBuffer, len: int): Future[int] {.
    async: (raises: [ChunkerError, CancelledError])
  .}

  # Reader that splits input data into fixed-size chunks
  Chunker* = ref object
    reader*: Reader # Procedure called to actually read the data
    offset*: int # Bytes read so far (position in the stream)
    chunkSize*: NBytes # Size of each chunk
    pad*: bool # Pad last chunk to chunkSize?

  FileChunker* = Chunker
  LPStreamChunker* = Chunker

proc getBytes*(c: Chunker): Future[seq[byte]] {.async.} =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var buff = newSeq[byte](c.chunkSize.int)
  let read = await c.reader(cast[ChunkBuffer](addr buff[0]), buff.len)

  if read <= 0:
    return @[]

  c.offset += read

  if not c.pad and buff.len > read:
    buff.setLen(read)

  return move buff

proc new*(
    T: type Chunker, reader: Reader, chunkSize = DefaultChunkSize, pad = true
): Chunker =
  ## create a new Chunker instance
  ##
  Chunker(reader: reader, offset: 0, chunkSize: chunkSize, pad: pad)

proc new*(
    T: type LPStreamChunker, stream: LPStream, chunkSize = DefaultChunkSize, pad = true
): LPStreamChunker =
  ## create the default File chunker
  ##

  proc reader(
      data: ChunkBuffer, len: int
  ): Future[int] {.async: (raises: [ChunkerError, CancelledError]).} =
    var res = 0
    try:
      while res < len:
        res += await stream.readOnce(addr data[res], len - res)
    except LPStreamEOFError as exc:
      trace "LPStreamChunker stream Eof", exc = exc.msg
    except CancelledError as error:
      raise error
    except LPStreamError as error:
      error "LPStream error", err = error.msg
      raise newException(ChunkerError, "LPStream error", error)
    except CatchableError as exc:
      error "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

    return res

  LPStreamChunker.new(reader = reader, chunkSize = chunkSize, pad = pad)

proc new*(
    T: type FileChunker, file: File, chunkSize = DefaultChunkSize, pad = true
): FileChunker =
  ## create the default File chunker
  ##

  proc reader(
      data: ChunkBuffer, len: int
  ): Future[int] {.async: (raises: [ChunkerError, CancelledError]).} =
    var total = 0
    try:
      while total < len:
        let res = file.readBuffer(addr data[total], len - total)
        if res <= 0:
          break

        total += res
    except IOError as exc:
      trace "Exception reading file", exc = exc.msg
    except CancelledError as error:
      raise error
    except CatchableError as exc:
      error "CatchableError exception", exc = exc.msg
      raise newException(Defect, exc.msg)

    return total

  FileChunker.new(reader = reader, chunkSize = chunkSize, pad = pad)
