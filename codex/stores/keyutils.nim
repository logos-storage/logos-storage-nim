## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/sugar
import pkg/questionable/results
import pkg/datastore
import pkg/libp2p
import ../namespaces
import ../manifest

const
  CodexMetaKey* = Key.init(CodexMetaNamespace).tryGet
  CodexRepoKey* = Key.init(CodexRepoNamespace).tryGet
  CodexBlocksKey* = Key.init(CodexBlocksNamespace).tryGet
  CodexTotalBlocksKey* = Key.init(CodexBlockTotalNamespace).tryGet
  CodexManifestKey* = Key.init(CodexManifestNamespace).tryGet
  BlocksTtlKey* = Key.init(CodexBlocksTtlNamespace).tryGet
  BlockProofKey* = Key.init(CodexBlockProofNamespace).tryGet
  QuotaKey* = Key.init(CodexQuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaKey / "used").tryGet
  QuotaReservedKey* = (QuotaKey / "reserved").tryGet

func makePrefixKey*(postFixLen: int, cid: Cid): ?!Key =
  let cidKey = ?Key.init(($cid)[^postFixLen ..^ 1] & "/" & $cid)

  if ?cid.isManifest:
    success CodexManifestKey / cidKey
  else:
    success CodexBlocksKey / cidKey

proc createBlockExpirationMetadataKey*(cid: Cid): ?!Key =
  BlocksTtlKey / $cid

proc createBlockExpirationMetadataQueryKey*(): ?!Key =
  let queryString = ?(BlocksTtlKey / "*")
  Key.init(queryString)

proc createBlockCidAndProofMetadataKey*(treeCid: Cid, index: Natural): ?!Key =
  (BlockProofKey / $treeCid).flatMap((k: Key) => k / $index)
