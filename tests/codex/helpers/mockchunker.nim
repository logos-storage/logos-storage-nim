import pkg/chronos
import pkg/codex/chunker

export chunker

type MockChunker* = Chunker

proc new*(
    T: type MockChunker,
    dataset: openArray[byte],
    chunkSize: int | NBytes,
    pad: bool = false,
): MockChunker =
  ## Create a chunker that produces data
  ##

  let
    chunkSize = chunkSize.NBytes
    dataset = @dataset

  var consumed = 0
  proc reader(
      data: ChunkBuffer, len: int
  ): Future[int] {.async: (raises: [ChunkerError, CancelledError]).} =
    if consumed >= dataset.len:
      return 0

    var read = 0
    while read < len and read < chunkSize.int and (consumed + read) < dataset.len:
      data[read] = dataset[consumed + read]
      read.inc

    consumed += read
    return read

  Chunker.new(reader = reader, pad = pad, chunkSize = chunkSize)
