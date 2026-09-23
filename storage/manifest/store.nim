## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./manifest
import ../blocktype
import ../logutils
import ../stores/blockstore

proc clearAdvertise*(
    store: BlockStore, cids: seq[Cid]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for cid in cids:
    if err =? (await store.setAdvertise(cid, true)).errorOption:
      return failure(err)

  success()

proc revertAdvertise(
    store: BlockStore, cids: seq[Cid]
) {.async: (raises: [CancelledError]).} =
  if err =? (await store.clearAdvertise(cids)).errorOption:
    error "Unable to revert advertise state", err = err.msg

proc disableAdvertise*(
    store: BlockStore, cids: seq[Cid]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  var disabled: seq[Cid]

  for cid in cids:
    without advertised =? (await store.isAdvertised(cid)), err:
      await store.revertAdvertise(disabled)
      return failure(err)

    if advertised:
      if err =? (await store.setAdvertise(cid, false)).errorOption:
        await store.revertAdvertise(disabled)
        return failure(err)

      disabled.add(cid)

  success(disabled)

proc storeManifestBlock*(
    store: BlockStore, blk: Block, advertise: bool
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Store a manifest block, recording whether the dataset it describes is
  ## announced to the DHT and served to peers. 

  without manifest =? Manifest.decode(blk), err:
    return failure(err)

  var disabled: seq[Cid]

  if not advertise:
    disabled = ?await store.disableAdvertise(@[manifest.treeCid, blk.cid])

  if err =? (await store.putBlock(blk)).errorOption:
    await store.revertAdvertise(disabled)
    return failure(err)

  success(manifest)
