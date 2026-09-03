## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

const
  # Namespaces
  StorageMetaNamespace* = "meta" # meta info stored here
  StorageRepoNamespace* = "repo" # repository namespace, blocks and manifests are subkeys
  StorageBlockTotalNamespace* = StorageMetaNamespace & "/total"
    # number of blocks in the repo
  StorageBlocksNamespace* = StorageRepoNamespace & "/blocks" # blocks namespace
  StorageManifestNamespace* = StorageRepoNamespace & "/manifests" # manifest namespace
  StorageBlocksTtlNamespace* = # Cid TTL
    StorageMetaNamespace & "/ttl"
  StorageBlockProofNamespace* = # Cid and Proof
    StorageMetaNamespace & "/proof"
  StorageQuotaNamespace* = StorageMetaNamespace & "/quota" # quota's namespace
