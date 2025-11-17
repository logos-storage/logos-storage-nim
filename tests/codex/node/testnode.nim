import std/os
import std/options
import std/math
import std/importutils

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/taskpools

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/logutils
import pkg/codex/stores
import pkg/codex/clock
import pkg/codex/contracts
import pkg/codex/systemclock
import pkg/codex/blockexchange
import pkg/codex/chunker
import pkg/codex/slots
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/erasure
import pkg/codex/merkletree
import pkg/codex/blocktype as bt
import pkg/codex/rng

import pkg/codex/node {.all.}

import ../../asynctest
import ../examples
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock
import ../slots/helpers

import ./helpers

privateAccess(CodexNodeRef) # enable access to private fields

asyncchecksuite "Test Node - Basic":
  setupAndTearDown()

  setup:
    await node.start()

  test "Fetch Manifest":
    let
      manifest = await storeDataGetManifest(localStore, chunker)

      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched == manifest

  test "Block Batching":
    let manifest = await storeDataGetManifest(localStore, chunker)

    for batchSize in 1 .. 12:
      (
        await node.fetchBatched(
          manifest,
          batchSize = batchSize,
          proc(
              blocks: seq[bt.Block]
          ): Future[?!void] {.async: (raises: [CancelledError]).} =
            check blocks.len > 0 and blocks.len <= batchSize
            return success(),
        )
      ).tryGet()

  test "Block Batching with corrupted blocks":
    let blocks = await makeRandomBlocks(datasetSize = 65536, blockSize = 64.KiBs)
    assert blocks.len == 1

    let blk = blocks[0]

    # corrupt block
    let pos = rng.Rng.instance.rand(blk.data.len - 1)
    blk.data[pos] = byte 0

    let manifest = await storeDataGetManifest(localStore, blocks)

    let batchSize = manifest.blocksCount
    let res = (
      await node.fetchBatched(
        manifest,
        batchSize = batchSize,
        proc(
            blocks: seq[bt.Block]
        ): Future[?!void] {.async: (raises: [CancelledError]).} =
          return failure("Should not be called"),
      )
    )
    check res.isFailure
    check res.error of CatchableError
    check res.error.msg == "Some blocks failed (Result) to fetch (1)"

  test "Should store Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
        # Let's check that node.store can correctly rechunk these odd chunks
      oddChunker = FileChunker.new(file = file, chunkSize = 1024.NBytes, pad = false)
        # don't pad, so `node.store` gets the correct size

    var original: seq[byte]
    try:
      while (let chunk = await oddChunker.getBytes(); chunk.len > 0):
        original &= chunk
        await stream.pushData(chunk)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock).tryGet()

    var data: seq[byte]
    for i in 0 ..< localManifest.blocksCount:
      let blk = (await localStore.getBlock(localManifest.treeCid, i)).tryGet()
      data &= blk.data

    data.setLen(localManifest.datasetSize.int) # truncate data to original size
    check:
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Should retrieve a Data Stream":
    let
      manifest = await storeDataGetManifest(localStore, chunker)
      manifestBlk =
        bt.Block.new(data = manifest.encode().tryGet, codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlk)).tryGet()
    let data = await ((await node.retrieve(manifestBlk.cid)).tryGet()).drain()

    var storedData: seq[byte]
    for i in 0 ..< manifest.blocksCount:
      let blk = (await localStore.getBlock(manifest.treeCid, i)).tryGet()
      storedData &= blk.data

    storedData.setLen(manifest.datasetSize.int) # truncate data to original size
    check:
      storedData == data

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()
    defer:
      await stream.close()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString

  test "Setup purchase request":
    let
      erasure =
        Erasure.new(store, leoEncoderProvider, leoDecoderProvider, Taskpool.new())
      manifest = await storeDataGetManifest(localStore, chunker)
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      protected = (await erasure.encode(manifest, 3, 2)).tryGet()
      builder = Poseidon2Builder.new(localStore, protected).tryGet()
      verifiable = (await builder.buildManifest()).tryGet()
      verifiableBlock =
        bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let request = (
      await node.setupRequest(
        cid = manifestBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100.uint64,
        pricePerBytePerSecond = 1.u256,
        proofProbability = 3.u256,
        expiry = 200.uint64,
        collateralPerByte = 1.u256,
      )
    ).tryGet

    check:
      (await verifiableBlock.cid in localStore) == true
      request.content.cid == verifiableBlock.cid
      request.content.merkleRoot == builder.verifyRoot.get.toBytes

  test "Should delete a single block":
    let randomBlock = bt.Block.new("Random block".toBytes).tryGet()
    (await localStore.putBlock(randomBlock)).tryGet()
    check (await randomBlock.cid in localStore) == true

    (await node.delete(randomBlock.cid)).tryGet()
    check (await randomBlock.cid in localStore) == false

  test "Should delete an entire dataset":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      manifest = await storeDataGetManifest(localStore, blocks)
      manifestBlock = (await store.storeManifest(manifest)).tryGet()
      manifestCid = manifestBlock.cid

    check await manifestCid in localStore
    for blk in blocks:
      check await blk.cid in localStore

    (await node.delete(manifestCid)).tryGet()

    check not await manifestCid in localStore
    for blk in blocks:
      check not (await blk.cid in localStore)

  test "Should return true when a cid is already in the local store":
    let
      blocks = await makeRandomBlocks(datasetSize = 1024, blockSize = 256'nb)
      manifest = await storeDataGetManifest(localStore, blocks)
      manifestBlock = (await store.storeManifest(manifest)).tryGet()
      manifestCid = manifestBlock.cid

    check (await node.hasLocalBlock(manifestCid)) == true

  test "Should returns false when a cid is not in the local store":
    let randomBlock = bt.Block.new("Random block".toBytes).tryGet()

    check (await node.hasLocalBlock(randomBlock.cid)) == false
