import pkg/chronos
import pkg/questionable/results
import pkg/storage/chunker
import pkg/storage/blocktype as bt
import pkg/storage/manifest

import ../asynctest
import ./helpers
import ./examples

suite "Manifest":
  let manifest = Manifest.new(
    treeCid = Cid.example, blockSize = (64 * 1024).NBytes, datasetSize = 100.MiBs
  )

  proc encodeDecode(manifest: Manifest): Manifest =
    let e = manifest.encode().tryGet()
    Manifest.decode(e).tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode large manifest":
    let large = Manifest.new(
      treeCid = Cid.example,
      blockSize = (64 * 1024).NBytes,
      datasetSize = (5 * 1024).MiBs,
    )

    check:
      encodeDecode(large) == large
