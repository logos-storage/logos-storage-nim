## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

{.push raises: [], gcsafe.}

import pkg/chronos
import pkg/stew/ptrops

import ../stores
import ../manifest
import ../blocktype
import ../logutils
import ../utils

import ./seekablestream

export stores, blocktype, manifest, chronos

logScope:
  topics = "codex storestream"

const StoreStreamTrackerName* = "StoreStream"

type
  # Make SeekableStream from a sequence of blocks stored in Manifest
  # (only original file data - see StoreStream.size)
  StoreStream* = ref object of SeekableStream
    store*: BlockStore # Store where to lookup block contents
    manifest*: Manifest # List of block CIDs

method initStream*(s: StoreStream) =
  if s.objName.len == 0:
    s.objName = StoreStreamTrackerName

  procCall SeekableStream(s).initStream()

proc new*(
    T: type StoreStream, store: BlockStore, manifest: Manifest, pad = true
): StoreStream =
  ## Create a new StoreStream instance for a given store and manifest
  ##
  result = StoreStream(store: store, manifest: manifest, offset: 0)

  result.initStream()

method `size`*(self: StoreStream): int =
  ## The size of a StoreStream is the size of the original dataset, without
  ## padding or parity blocks.
  let m = self.manifest
  (if m.protected: m.originalDatasetSize else: m.datasetSize).int

proc `size=`*(self: StoreStream, size: int) {.error: "Setting the size is forbidden".} =
  discard

method atEof*(self: StoreStream): bool =
  self.offset >= self.size

type LPStreamReadError* = object of LPStreamError

proc newLPStreamReadError*(p: ref CatchableError): ref LPStreamReadError =
  newException(LPStreamReadError, "Read stream failed", p)

method readOnce*(
    self: StoreStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Read `nbytes` from current position in the StoreStream into output buffer pointed by `pbytes`.
  ## Return how many bytes were actually read before EOF was encountered.
  ## Raise exception if we are already at EOF.
  ##

  if self.atEof:
    raise newLPStreamEOFError()

  # The loop iterates over blocks in the StoreStream,
  # reading them and copying their data into outbuf
  var read = 0 # Bytes read so far, and thus write offset in the outbuf
  while read < nbytes and not self.atEof:
    # Compute from the current stream position `self.offset` the block num/offset to read
    # Compute how many bytes to read from this block
    let
      blockNum = self.offset div self.manifest.blockSize.int
      blockOffset = self.offset mod self.manifest.blockSize.int
      readBytes = min(
        [
          self.size - self.offset,
          nbytes - read,
          self.manifest.blockSize.int - blockOffset,
        ]
      )
      address =
        BlockAddress(leaf: true, treeCid: self.manifest.treeCid, index: blockNum)

    # Read contents of block `blockNum`
    without blk =? (await self.store.getBlock(address)).tryGet.catch, error:
      raise newLPStreamReadError(error)

    trace "Reading bytes from store stream",
      manifestCid = self.manifest.treeCid,
      numBlocks = self.manifest.blocksCount,
      blockNum,
      blkCid = blk.cid,
      bytes = readBytes,
      blockOffset

    # Copy `readBytes` bytes starting at `blockOffset` from the block into the outbuf
    if blk.isEmpty:
      zeroMem(pbytes.offset(read), readBytes)
    else:
      copyMem(pbytes.offset(read), blk.data[blockOffset].unsafeAddr, readBytes)

    # Update current positions in the stream and outbuf
    self.offset += readBytes
    read += readBytes

  return read

method closeImpl*(self: StoreStream) {.async: (raises: []).} =
  trace "Closing StoreStream"
  self.offset = self.size # set Eof
  await procCall LPStream(self).closeImpl()
