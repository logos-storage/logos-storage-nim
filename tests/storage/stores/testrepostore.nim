import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore

import pkg/storage/stores/cachestore
import pkg/storage/chunker
import pkg/storage/stores
import pkg/storage/stores/repostore/operations
import pkg/storage/blocktype as bt
import pkg/storage/clock
import pkg/storage/utils/safeasynciter
import pkg/storage/merkletree

import ../../asynctest
import ../helpers
import ../helpers/mockclock
import ../examples
import ./commonstoretests

suite "Test RepoStore start/stop":
  var
    repoDs: Datastore
    metaDs: Datastore

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()

  test "Should set started flag once started":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.stop()
    await repo.stop()
    check not repo.started

asyncchecksuite "RepoStore":
  var
    repoDs: Datastore
    metaDs: Datastore
    mockClock: MockClock

    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 200'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  test "Should advertise a cid by default":
    let blk = createTestBlock(100)

    check (await repo.isAdvertised(blk.cid)).tryGet

  test "Should stop and resume advertising a cid":
    let blk = createTestBlock(100)

    (await repo.setAdvertise(blk.cid, false)).tryGet
    check not (await repo.isAdvertised(blk.cid)).tryGet

    (await repo.setAdvertise(blk.cid, true)).tryGet
    check (await repo.isAdvertised(blk.cid)).tryGet

  test "Should update current used bytes on block put":
    let blk = createTestBlock(200)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet

    check:
      repo.quotaUsedBytes == 200'nb

  test "Should update current used bytes on block delete":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    (await repo.delBlock(blk.cid)).tryGet

    check:
      repo.quotaUsedBytes == 0'nb

  test "Should not update current used bytes if block exist":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    # put again
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

  test "Should fail storing passed the quota":
    let blk = createTestBlock(300)

    check repo.totalUsed == 0'nb
    expect QuotaNotEnoughError:
      (await repo.putBlock(blk)).tryGet

  test "Should reserve bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.reserve(100'nb)).tryGet

    check:
      repo.totalUsed == 200'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 100'nb

  test "Should not reserve bytes over max quota":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    expect QuotaNotEnoughError:
      (await repo.reserve(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 0'nb

  test "Should release bytes":
    discard createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.release(100'nb)).tryGet

    check:
      repo.totalUsed == 0'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 0'nb

  test "Should not release bytes less than quota":
    check repo.totalUsed == 0'nb
    (await repo.reserve(100'nb)).tryGet
    check repo.totalUsed == 100'nb

    expect RangeDefect:
      (await repo.release(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 100'nb

  proc getExpirations(): Future[seq[BlockExpiration]] {.async.} =
    let iter = (await repo.getBlockExpirations(100, 0)).tryGet()

    var res = newSeq[BlockExpiration]()
    for fut in iter:
      if be =? (await fut):
        res.add(be)
    res

  test "Should store block expiration timestamp":
    let
      duration = 10.seconds
      blk = createTestBlock(100)

    let expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)

    (await repo.putBlock(blk, duration.some)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

  test "Should store block with default expiration timestamp when not provided":
    let blk = createTestBlock(100)

    let expectedExpiration =
      BlockExpiration(cid: blk.cid, expiry: now + DefaultBlockTtl.seconds)

    (await repo.putBlock(blk)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

  test "Should refuse update expiry with negative timestamp":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, -1)).tryGet

    expect ValueError:
      (await repo.ensureExpiry(blk.cid, 0)).tryGet

  test "Should fail when updating expiry of non-existing block":
    let blk = createTestBlock(100)

    expect BlockNotFoundError:
      (await repo.ensureExpiry(blk.cid, 10)).tryGet

  test "Should update block expiration timestamp when new expiration is farther":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)
      updatedExpectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 20)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    (await repo.ensureExpiry(blk.cid, now + 20)).tryGet

    let updatedExpirations = await getExpirations()

    check:
      expectedExpiration notin updatedExpirations
      updatedExpectedExpiration in updatedExpirations

  test "Should not update block expiration timestamp when current expiration is farther then new one":
    let
      blk = createTestBlock(100)
      expectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 10)
      updatedExpectedExpiration = BlockExpiration(cid: blk.cid, expiry: now + 5)

    (await repo.putBlock(blk, some 10.seconds)).tryGet

    let expirations = await getExpirations()

    check:
      expectedExpiration in expirations

    (await repo.ensureExpiry(blk.cid, now + 5)).tryGet

    let updatedExpirations = await getExpirations()

    check:
      expectedExpiration in updatedExpirations
      updatedExpectedExpiration notin updatedExpirations

  test "delBlock should remove expiration metadata":
    let
      blk = createTestBlock(100)
      expectedKey = Key.init("meta/ttl/" & $blk.cid).tryGet

    (await repo.putBlock(blk, 10.seconds.some)).tryGet
    (await repo.delBlock(blk.cid)).tryGet

    let expirations = await getExpirations()

    check:
      expirations.len == 0

  test "Should retrieve block expiration information":
    proc unpack(
        beIter: Future[?!SafeAsyncIter[BlockExpiration]]
    ): Future[seq[BlockExpiration]] {.async: (raises: [CatchableError]).} =
      var expirations = newSeq[BlockExpiration](0)
      without iter =? (await beIter), err:
        return expirations
      for beFut in toSeq(iter):
        if value =? (await beFut):
          expirations.add(value)
      return expirations

    let
      duration = 10.seconds
      blk1 = createTestBlock(10)
      blk2 = createTestBlock(11)
      blk3 = createTestBlock(12)

    let expectedExpiration: SecondsSince1970 = now + 10

    proc assertExpiration(be: BlockExpiration, expectedBlock: bt.Block) =
      check:
        be.cid == expectedBlock.cid
        be.expiry == expectedExpiration

    (await repo.putBlock(blk1, duration.some)).tryGet
    (await repo.putBlock(blk2, duration.some)).tryGet
    (await repo.putBlock(blk3, duration.some)).tryGet

    let
      blockExpirations1 =
        await unpack(repo.getBlockExpirations(maxNumber = 2, offset = 0))
      blockExpirations2 =
        await unpack(repo.getBlockExpirations(maxNumber = 2, offset = 2))

    check blockExpirations1.len == 2
    assertExpiration(blockExpirations1[0], blk2)
    assertExpiration(blockExpirations1[1], blk1)

    check blockExpirations2.len == 1
    assertExpiration(blockExpirations2[0], blk3)

  test "should put empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.putBlock(blk)).isOk

  test "should get empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()

    let got = await repo.getBlock(blk.cid)
    check got.isOk
    check got.get.cid == blk.cid

  test "should delete empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.delBlock(blk.cid)).isOk

  test "should have empty block":
    let blk = Cid.example.emptyBlock.tryGet()

    let has = await repo.hasBlock(blk.cid)
    check has.isOk
    check has.get

  test "should set the reference count for orphan blocks to 0":
    let blk = Block.example(size = 200)
    (await repo.putBlock(blk)).tryGet()
    check (await repo.blockRefCount(blk.cid)).tryGet() == 0.Natural

  test "should not allow non-orphan blocks to be deleted directly":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      (blocks, tree, manifest, _) = makeDataset(
          await makeRandomBlocks(datasetSize = 2 * 256, blockSize = 256'nb)
        )
        .tryGet()
      blk = blocks[0]
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    let err = (await repo.delBlock(blk.cid)).error()
    check err.msg ==
      "Directly deleting a block that is part of a dataset is not allowed."

  test "should allow non-orphan blocks to be deleted by dataset reference":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      (blocks, tree, manifest, _) = makeDataset(
          await makeRandomBlocks(datasetSize = 2 * 256, blockSize = 256'nb)
        )
        .tryGet()
      blk = blocks[0]
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    check not (await blk.cid in repo)

  test "should not delete a non-orphan block until it is deleted from all parent datasets":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      blockPool = await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)

    let
      dataset1 = @[blockPool[0], blockPool[1]]
      dataset2 = @[blockPool[1], blockPool[2]]

    let sharedBlock = blockPool[1]

    let
      (_, tree1, manifest1, _) = makeDataset(dataset1).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      (_, tree2, manifest2, _) = makeDataset(dataset2).tryGet()
      treeCid2 = tree2.rootCid.tryGet()

    (await repo.putBlock(sharedBlock)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 0.Natural

    let
      proof1 = tree1.getProof(1).tryGet()
      proof2 = tree2.getProof(0).tryGet()

    (await repo.putCidAndProof(treeCid1, 1, sharedBlock.cid, proof1)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural

    (await repo.putCidAndProof(treeCid2, 0, sharedBlock.cid, proof2)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 2.Natural

    (await repo.delBlock(treeCid1, 1.Natural)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural
    check (await sharedBlock.cid in repo)

    (await repo.delBlock(treeCid2, 0.Natural)).tryGet()
    check not (await sharedBlock.cid in repo)

  test "should not panic (underflow) when deleting a manifest as a leaf":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      (_, tree, manifest, _) = makeDataset(
          await makeRandomBlocks(datasetSize = 2 * 256, blockSize = 256'nb)
        )
        .tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(1).tryGet()

    let encodedVerifiable = manifest.encode().tryGet
    let blk = bt.Block.new(data = encodedVerifiable, codec = ManifestCodec).tryGet

    (await repo.putCidAndProof(treeCid, 0.Natural, blk.cid, proof)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet

    check not (await blk.cid in repo)

  test "should clear leaf metadata when block is deleted from dataset":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      blocks = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = blocks[0]
      (_, tree, manifest, _) = makeDataset(blocks).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(1).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0.Natural, blk.cid, proof)).tryGet()

    discard (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

    let err = (await repo.getLeafMetadata(treeCid, 0.Natural)).error()
    check err of BlockNotFoundError

  test "should not fail when reinserting and deleting a previously deleted block (bug #1108)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      blocks = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = blocks[0]
      (_, tree, manifest, _) = makeDataset(blocks).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(1).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    (await repo.putBlock(blk)).tryGet()
    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

commonBlockStoreTests(
  "RepoStore Sql backend",
  proc(): BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteDatastore.new(Memory).tryGet(),
        SQLiteDatastore.new(Memory).tryGet(),
        clock = MockClock.new(),
      )
    ),
)

const path = currentSourcePath().parentDir / "test"

proc before() {.async.} =
  createDir(path)

proc after() {.async.} =
  removeDir(path)

let depth = path.split(DirSep).len

commonBlockStoreTests(
  "RepoStore FS backend",
  proc(): BlockStore =
    BlockStore(
      RepoStore.new(
        FSDatastore.new(path, depth).tryGet(),
        SQLiteDatastore.new(Memory).tryGet(),
        clock = MockClock.new(),
      )
    ),
  before = before,
  after = after,
)
