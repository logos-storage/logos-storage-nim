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

  proc manifestWithMetadata(filename, mimetype: string): seq[byte] =
    Manifest
      .new(
        treeCid = Cid.example,
        blockSize = (64 * 1024).NBytes,
        datasetSize = 100.MiBs,
        filename = some(filename),
        mimetype = some(mimetype),
      )
      .encode()
      .get()

  test "Should decode a manifest with a valid filename and mimetype":
    check Manifest.decode(manifestWithMetadata("example.txt", "text/plain")).isOk

  test "Should reject a manifest whose filename contains a line break":
    check Manifest.decode(manifestWithMetadata("x.txt\r\nX-Injected: 1", "text/plain")).isErr

  test "Should reject a manifest whose mimetype contains a quote":
    check Manifest.decode(manifestWithMetadata("example.txt", "text/plain\"")).isErr
