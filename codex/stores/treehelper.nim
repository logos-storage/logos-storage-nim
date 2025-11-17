## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/sugar
import pkg/chronos
import pkg/chronos/futures
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../utils/asynciter
import ../merkletree

proc putSomeProofs*(
    store: BlockStore, tree: CodexTree, iter: Iter[int]
): Future[?!void] {.async.} =
  without treeCid =? tree.rootCid, err:
    return failure(err)

  for i in iter:
    if i notin 0 ..< tree.leavesCount:
      return failure(
        "Invalid leaf index " & $i & ", tree with cid " & $treeCid & " has " &
          $tree.leavesCount & " leaves"
      )

    without blkCid =? tree.getLeafCid(i), err:
      return failure(err)

    without proof =? tree.getProof(i), err:
      return failure(err)

    let res = await store.putCidAndProof(treeCid, i, blkCid, proof)

    if err =? res.errorOption:
      return failure(err)

  success()

proc putSomeProofs*(
    store: BlockStore, tree: CodexTree, iter: Iter[Natural]
): Future[?!void] =
  store.putSomeProofs(tree, iter.map((i: Natural) => i.ord))

proc putAllProofs*(store: BlockStore, tree: CodexTree): Future[?!void] =
  store.putSomeProofs(tree, Iter[int].new(0 ..< tree.leavesCount))
