import std/sequtils

import pkg/chronos

import pkg/storage/[streams, stores, manifest, blocktype as bt]

import ../asynctest
import ./examples
import ./helpers

asyncchecksuite "StoreStream":
  var
    manifest: Manifest
    store: BlockStore
    stream: StoreStream

  # Check that `buf` contains `size` bytes with values start, start+1...
  proc sequentialBytes(buf: seq[byte], size: int, start: int): bool =
    for i in 0 ..< size:
      if int(buf[i]) != start + i:
        return false
    return true

  let
    data = [
      byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
      22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41,
      42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61,
      62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81,
      82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99,
    ]
    chunkSize = 10

  teardown:
    await stream.close()

  setup:
    store = CacheStore.new()
    manifest = (
      await storeDataGetManifest(
        store, MockChunker.new(dataset = data, chunkSize = chunkSize)
      )
    ).manifest
    stream = StoreStream.new(store, manifest)

  test "Read all blocks < blockSize":
    var
      buf = newSeq[byte](8)
      n = 0

    while not stream.atEof:
      let read = (await stream.readOnce(addr buf[0], buf.len))

      if not stream.atEof:
        check read == 8
      else:
        check read == 4

      check sequentialBytes(buf, read, n)
      n += read

  test "Read all blocks == blockSize":
    var
      buf = newSeq[byte](10)
      n = 0

    while not stream.atEof:
      let read = (await stream.readOnce(addr buf[0], buf.len))
      check read == 10
      check sequentialBytes(buf, read, n)
      n += read

  test "Read all blocks > blockSize":
    var
      buf = newSeq[byte](11)
      n = 0

    while not stream.atEof:
      let read = (await stream.readOnce(addr buf[0], buf.len))

      if not stream.atEof:
        check read == 11
      else:
        check read == 1

      check sequentialBytes(buf, read, n)
      n += read

  test "Read exact bytes within block boundary":
    var buf = newSeq[byte](5)

    await stream.readExactly(addr buf[0], 5)
    check sequentialBytes(buf, 5, 0)

  test "Read exact bytes outside of block boundary":
    var buf = newSeq[byte](15)

    await stream.readExactly(addr buf[0], 15)
    check sequentialBytes(buf, 15, 0)

asyncchecksuite "StoreStream - Short Blocks":
  const blockSize = 10

  proc shortBlocksStream(
      lens: seq[int], datasetSize: int
  ): Future[StoreStream] {.async.} =
    let store = CacheStore.new()
    var blocks: seq[bt.Block]
    for i, len in lens:
      blocks.add(bt.Block.new(newSeqWith(len, byte(i + 1))).tryGet())
    let
      treeCid = (await storeDataGetManifest(store, blocks)).manifest.treeCid
      manifest = Manifest.new(
        treeCid = treeCid,
        blockSize = blockSize.NBytes,
        datasetSize = datasetSize.NBytes,
      )
    return StoreStream.new(store, manifest)

  test "Read of a short middle block fails":
    let stream = await shortBlocksStream(@[10, 3, 10], datasetSize = 30)
    var buf = newSeq[byte](blockSize)

    check (await stream.readOnce(addr buf[0], buf.len)) == blockSize
    expect LPStreamReadError:
      discard await stream.readOnce(addr buf[0], buf.len)
    await stream.close()

  test "Read of a short last block fails":
    let stream = await shortBlocksStream(@[10, 10, 3], datasetSize = 25)
    var buf = newSeq[byte](blockSize)

    check (await stream.readOnce(addr buf[0], buf.len)) == blockSize
    check (await stream.readOnce(addr buf[0], buf.len)) == blockSize
    expect LPStreamReadError:
      discard await stream.readOnce(addr buf[0], buf.len)
    await stream.close()

suite "StoreStream - Size Tests":
  var stream: StoreStream

  teardown:
    await stream.close()

  test "Should return dataset size as stream size":
    let manifest = Manifest.new(
      treeCid = Cid.example, datasetSize = 80.NBytes, blockSize = 10.NBytes
    )

    stream = StoreStream.new(CacheStore.new(), manifest)

    check stream.size == 80
