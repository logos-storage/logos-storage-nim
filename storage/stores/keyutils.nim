## Logos Storage
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
  StorageMetaKey* = Key.init(StorageMetaNamespace).tryGet
  StorageRepoKey* = Key.init(StorageRepoNamespace).tryGet
  StorageBlocksKey* = Key.init(StorageBlocksNamespace).tryGet
  StorageTotalBlocksKey* = Key.init(StorageBlockTotalNamespace).tryGet
  StorageManifestKey* = Key.init(StorageManifestNamespace).tryGet
  AdvertiseKey* = Key.init(StorageAdvertiseNamespace).tryGet
  BlocksTtlKey* = Key.init(StorageBlocksTtlNamespace).tryGet
  BlockProofKey* = Key.init(StorageBlockProofNamespace).tryGet
  QuotaKey* = Key.init(StorageQuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaKey / "used").tryGet
  QuotaReservedKey* = (QuotaKey / "reserved").tryGet

func makePrefixKey*(postFixLen: int, cid: Cid): ?!Key =
  let cidKey = ?Key.init(($cid)[^postFixLen ..^ 1] & "/" & $cid)

  if ?cid.isManifest:
    success StorageManifestKey / cidKey
  else:
    success StorageBlocksKey / cidKey

proc createBlockExpirationMetadataKey*(cid: Cid): ?!Key =
  BlocksTtlKey / $cid

proc createBlockExpirationMetadataQueryKey*(): ?!Key =
  let queryString = ?(BlocksTtlKey / "*")
  Key.init(queryString)

proc createAdvertiseMetadataKey*(cid: Cid): ?!Key =
  AdvertiseKey / $cid

proc createBlockCidAndProofMetadataKey*(treeCid: Cid, index: Natural): ?!Key =
  (BlockProofKey / $treeCid).flatMap((k: Key) => k / $index)
