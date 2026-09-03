import std/os
import std/math
import std/importutils

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable/results
import pkg/taskpools

import pkg/storage/logutils
import pkg/storage/stores
import pkg/storage/clock
import pkg/storage/systemclock
import pkg/storage/blockexchange
import pkg/storage/chunker
import pkg/storage/manifest
import pkg/storage/discovery
import pkg/storage/blocktype as bt

import pkg/storage/node {.all.}

import ../../asynctest
import ../examples
import ../helpers
import ../helpers/mockclock

import ./helpers

privateAccess(StorageNodeRef) # enable access to private fields

asyncchecksuite "Test Node - Basic":
  setupAndTearDown()
  var taskPool: Taskpool

  setup:
    taskPool = Taskpool.new()
    await node.start()

  teardown:
    taskPool.shutdown()

  test "Fetch Manifest":
    let md = await storeDataGetManifest(localStore, chunker)

    let fetched = (await node.fetchManifest(md.manifestCid)).tryGet()

    check:
      fetched == md.manifest

  test "Fetch Dataset":
    let md = await storeDataGetManifest(localStore, chunker)

    # Fetch the dataset using the download manager
    (await node.fetchDatasetAsync(md, fetchLocal = true)).tryGet()

    # Verify all blocks are accessible from local store
    for i in 0 ..< md.manifest.blocksCount:
      let blk = (await localStore.getBlock(md.manifest.treeCid, i)).tryGet()
      check blk.data[].len > 0

  test "Fetch Dataset with fetchLocal fails when block missing":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      md = await storeDataGetManifest(localStore, blocks)

    # Delete one block so it's missing locally
    (await localStore.delBlock(md.manifest.treeCid, 0)).tryGet()

    let res = await node.fetchDatasetAsync(md, fetchLocal = true)
    check res.isErr
    check res.error of BlockNotFoundError

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
      data &= blk.data[]

    data.setLen(localManifest.datasetSize.int) # truncate data to original size
    check:
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Should retrieve a Data Stream":
    let md = await storeDataGetManifest(localStore, chunker)

    let data = await ((await node.retrieve(md.manifestCid)).tryGet()).drain()

    var storedData: seq[byte]
    for i in 0 ..< md.manifest.blocksCount:
      let blk = (await localStore.getBlock(md.manifest.treeCid, i)).tryGet()
      storedData &= blk.data[]

    storedData.setLen(md.manifest.datasetSize.int) # truncate data to original size
    check:
      storedData == data

  test "Stream blocks with fetchLocal succeeds when all local":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      md = await storeDataGetManifest(localStore, blocks)
      totalBlocks = md.manifest.blocksCount.uint64
      treeCid = md.manifest.treeCid
      handle = engine.startTreeDownload(md, fetchLocal = true).tryGet()

    defer:
      engine.releaseDownload(handle)

    var count = 0
    for i in 0 ..< totalBlocks.int:
      let blk = (await store.getBlock(treeCid, i.Natural)).tryGet()
      check blk.data[].len > 0
      count += 1
    check count.uint64 == totalBlocks

  test "Stream blocks with fetchLocal fails when block missing":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      md = await storeDataGetManifest(localStore, blocks)
      treeCid = md.manifest.treeCid

    # Delete one block so it's missing locally
    (await localStore.delBlock(treeCid, 0)).tryGet()

    let handle = engine.startTreeDownload(md, fetchLocal = true).tryGet()
    defer:
      engine.releaseDownload(handle)

    let res = await store.getBlock(treeCid, 0.Natural)
    check res.isErr
    check (res.error of BlockNotFoundError) or (res.error of DownloadTerminatedError)

    let completion = await handle.waitForComplete()
    check completion.isErr
    check completion.error of BlockNotFoundError

  test "Stream blocks with fetchLocal=false fails when retries exhausted":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      md = await storeDataGetManifest(localStore, blocks)
      treeCid = md.manifest.treeCid

    # Delete one block so it's missing locally
    (await localStore.delBlock(treeCid, 0)).tryGet()

    # Configure low retries so the test completes quickly (no peers to fetch from)
    downloadManager.maxBlockRetries = 1
    downloadManager.retryInterval = 10.milliseconds

    let handle = engine.startTreeDownload(md, fetchLocal = false).tryGet()
    defer:
      engine.releaseDownload(handle)

    let res = await store.getBlock(treeCid, 0.Natural)
    check res.isErr
    check (res.error of RetriesExhaustedError) or (res.error of DownloadTerminatedError)

    let completion = await handle.waitForComplete()
    check completion.isErr
    check completion.error of RetriesExhaustedError

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

  test "Should delete a single block":
    let randomBlock = bt.Block.new("Random block".toBytes).tryGet()
    (await localStore.putBlock(randomBlock)).tryGet()
    check (await randomBlock.cid in localStore) == true

    (await node.delete(randomBlock.cid)).tryGet()
    check (await randomBlock.cid in localStore) == false

  test "Should delete an entire dataset":
    let
      blocks = await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)
      md = await storeDataGetManifest(localStore, blocks)
      manifestCid = md.manifestCid

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
      md = await storeDataGetManifest(localStore, blocks)

    check (await node.hasLocalBlock(md.manifestCid)) == true

  test "Should returns false when a cid is not in the local store":
    let randomBlock = bt.Block.new("Random block".toBytes).tryGet()

    check (await node.hasLocalBlock(randomBlock.cid)) == false

  test "updateExpiry succeeds when all blocks have metadata":
    let
      md = await storeDataGetManifest(localStore, chunker)
      expiry = SecondsSince1970(9999999999)
    let res = await node.updateExpiry(md.manifestCid, expiry)
    check res.isOk

  test "updateExpiry returns failure when block metadata is missing":
    let
      manifest = Manifest.example
      manifestBlk = (await node.storeManifest(manifest)).tryGet()
      expiry = SecondsSince1970(9999999999)
    let res = await node.updateExpiry(manifestBlk.cid, expiry)
    check res.isErr
