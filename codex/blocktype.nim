## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sugar
import std/hashes

export tables

{.push raises: [], gcsafe.}

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/[byteutils, endians2]
import pkg/questionable
import pkg/questionable/results

import ./units
import ./utils
import ./errors
import ./logutils
import ./utils/json
import ./codextypes

export errors, logutils, units, codextypes

type
  Block* = ref object of RootObj
    cid*: Cid
    data*: seq[byte]

  BlockAddress* = object
    case leaf*: bool
    of true:
      treeCid* {.serialize.}: Cid
      index* {.serialize.}: Natural
    else:
      cid* {.serialize.}: Cid

logutils.formatIt(LogFormat.textLines, BlockAddress):
  if it.leaf:
    "treeCid: " & shortLog($it.treeCid) & ", index: " & $it.index
  else:
    "cid: " & shortLog($it.cid)

logutils.formatIt(LogFormat.json, BlockAddress):
  %it

proc `==`*(a, b: BlockAddress): bool =
  a.leaf == b.leaf and (
    if a.leaf:
      a.treeCid == b.treeCid and a.index == b.index
    else:
      a.cid == b.cid
  )

proc `$`*(a: BlockAddress): string =
  if a.leaf:
    "treeCid: " & $a.treeCid & ", index: " & $a.index
  else:
    "cid: " & $a.cid

proc hash*(a: BlockAddress): Hash =
  if a.leaf:
    let data = a.treeCid.data.buffer & @(a.index.uint64.toBytesBE)
    hash(data)
  else:
    hash(a.cid.data.buffer)

proc cidOrTreeCid*(a: BlockAddress): Cid =
  if a.leaf: a.treeCid else: a.cid

proc address*(b: Block): BlockAddress =
  BlockAddress(leaf: false, cid: b.cid)

proc init*(_: type BlockAddress, cid: Cid): BlockAddress =
  BlockAddress(leaf: false, cid: cid)

proc init*(_: type BlockAddress, treeCid: Cid, index: Natural): BlockAddress =
  BlockAddress(leaf: true, treeCid: treeCid, index: index)

proc `$`*(b: Block): string =
  result &= "cid: " & $b.cid
  result &= "\ndata: " & string.fromBytes(b.data)

func new*(
    T: type Block,
    data: openArray[byte] = [],
    version = CIDv1,
    mcodec = Sha256HashCodec,
    codec = BlockCodec,
): ?!Block =
  ## creates a new block for both storage and network IO
  ##

  let
    hash = ?MultiHash.digest($mcodec, data).mapFailure
    cid = ?Cid.init(version, codec, hash).mapFailure

  # TODO: If the hash is `>=` to the data,
  # use the Cid as a container!

  Block(cid: cid, data: @data).success

proc new*(
    T: type Block, cid: Cid, data: openArray[byte], verify: bool = true
): ?!Block =
  ## creates a new block for both storage and network IO
  ##

  if verify:
    let
      mhash = ?cid.mhash.mapFailure
      computedMhash = ?MultiHash.digest($mhash.mcodec, data).mapFailure
      computedCid = ?Cid.init(cid.cidver, cid.mcodec, computedMhash).mapFailure
    if computedCid != cid:
      return "Cid doesn't match the data".failure

  return Block(cid: cid, data: @data).success

proc emptyBlock*(version: CidVersion, hcodec: MultiCodec): ?!Block =
  emptyCid(version, hcodec, BlockCodec).flatMap(
    (cid: Cid) => Block.new(cid = cid, data = @[])
  )

proc emptyBlock*(cid: Cid): ?!Block =
  cid.mhash.mapFailure.flatMap(
    (mhash: MultiHash) => emptyBlock(cid.cidver, mhash.mcodec)
  )

proc isEmpty*(cid: Cid): bool =
  success(cid) ==
    cid.mhash.mapFailure.flatMap(
      (mhash: MultiHash) => emptyCid(cid.cidver, mhash.mcodec, cid.mcodec)
    )

proc isEmpty*(blk: Block): bool =
  blk.cid.isEmpty
