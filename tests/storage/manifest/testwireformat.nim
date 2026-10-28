import std/options

import pkg/unittest2
import pkg/libp2p/cid
import pkg/storage/manifest
import pkg/storage/storagetypes
import pkg/storage/units

## All Expected_* consts were generated from the minprotobuf encoder and are
## the current manifest wire format.
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY any of the Expected_* consts. If tests are failing after
## touching coders.nim, the protobuf library or anything else in the encode
## path, the wire format has diverged from what existing peers and stored
## manifests expect — both network decoding and manifest CIDs would break.

const Expected_minimal = @[
  0x0A'u8, 0x38'u8, 0x08'u8, 0x00'u8, 0x12'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8,
  0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8,
  0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8,
  0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8,
  0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x18'u8, 0x80'u8, 0x80'u8,
  0x04'u8, 0x20'u8, 0x80'u8, 0x80'u8, 0x40'u8, 0x28'u8, 0x82'u8, 0x9A'u8, 0x03'u8,
  0x30'u8, 0x12'u8, 0x38'u8, 0x02'u8,
]

const Expected_withFilenameMimetype = @[
  0x0A'u8, 0x4E'u8, 0x08'u8, 0x00'u8, 0x12'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8,
  0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8,
  0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8,
  0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8,
  0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x18'u8, 0x80'u8, 0x80'u8,
  0x04'u8, 0x20'u8, 0x80'u8, 0x80'u8, 0x40'u8, 0x28'u8, 0x82'u8, 0x9A'u8, 0x03'u8,
  0x30'u8, 0x12'u8, 0x38'u8, 0x02'u8, 0x42'u8, 0x08'u8, 0x74'u8, 0x65'u8, 0x73'u8,
  0x74'u8, 0x2E'u8, 0x74'u8, 0x78'u8, 0x74'u8, 0x4A'u8, 0x0A'u8, 0x74'u8, 0x65'u8,
  0x78'u8, 0x74'u8, 0x2F'u8, 0x70'u8, 0x6C'u8, 0x61'u8, 0x69'u8, 0x6E'u8,
]

const Expected_onlyFilename = @[
  0x0A'u8, 0x42'u8, 0x08'u8, 0x00'u8, 0x12'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8,
  0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8,
  0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8,
  0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8,
  0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x18'u8, 0x80'u8, 0x80'u8,
  0x04'u8, 0x20'u8, 0x80'u8, 0x80'u8, 0x40'u8, 0x28'u8, 0x82'u8, 0x9A'u8, 0x03'u8,
  0x30'u8, 0x12'u8, 0x38'u8, 0x02'u8, 0x42'u8, 0x08'u8, 0x64'u8, 0x61'u8, 0x74'u8,
  0x61'u8, 0x2E'u8, 0x62'u8, 0x69'u8, 0x6E'u8,
]

const Expected_largeDataset = @[
  0x0A'u8, 0x3A'u8, 0x08'u8, 0x00'u8, 0x12'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8,
  0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8,
  0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8,
  0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8,
  0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x18'u8, 0x80'u8, 0x80'u8,
  0x04'u8, 0x20'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x80'u8, 0x14'u8, 0x28'u8, 0x82'u8,
  0x9A'u8, 0x03'u8, 0x30'u8, 0x12'u8, 0x38'u8, 0x02'u8,
]

proc fixedCid(seed: byte): Cid =
  var bytes = @[
    0x01.byte, 0x55, 0x12, 0x20, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
    0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
  ]
  bytes[^1] = seed
  Cid.init(bytes).expect("valid Cid bytes")

let cidA = fixedCid(0xAA)

suite "Manifest wire-format contract":
  test "Should encode a minimal manifest":
    let m = Manifest.new(
      treeCid = cidA, blockSize = 65536.NBytes, datasetSize = 1048576.NBytes
    )
    let encoded = m.encode()
    check encoded.isOk
    check encoded.get == Expected_minimal

  test "Should encode a manifest with filename and mimetype":
    let m = Manifest.new(
      treeCid = cidA,
      blockSize = 65536.NBytes,
      datasetSize = 1048576.NBytes,
      filename = "test.txt".some,
      mimetype = "text/plain".some,
    )
    let encoded = m.encode()
    check encoded.isOk
    check encoded.get == Expected_withFilenameMimetype

  test "Should encode a manifest with only a filename":
    let m = Manifest.new(
      treeCid = cidA,
      blockSize = 65536.NBytes,
      datasetSize = 1048576.NBytes,
      filename = "data.bin".some,
    )
    let encoded = m.encode()
    check encoded.isOk
    check encoded.get == Expected_onlyFilename

  test "Should encode a manifest with a large dataset size":
    let m = Manifest.new(
      treeCid = cidA,
      blockSize = 65536.NBytes,
      datasetSize = (5'u64 * 1024 * 1024 * 1024).NBytes,
    )
    let encoded = m.encode()
    check encoded.isOk
    check encoded.get == Expected_largeDataset

  test "Should round-trip every captured byte fixture (decode + re-encode)":
    let fixtures = [
      ("minimal", Expected_minimal),
      ("withFilenameMimetype", Expected_withFilenameMimetype),
      ("onlyFilename", Expected_onlyFilename),
      ("largeDataset", Expected_largeDataset),
    ]
    for (name, expected) in fixtures:
      checkpoint("fixture: " & name)
      let decoded = Manifest.decode(expected)
      check decoded.isOk
      let reEncoded = decoded.get.encode()
      check reEncoded.isOk
      check reEncoded.get == expected

suite "Manifest decode error handling":
  test "Should reject empty bytes":
    check Manifest.decode(newSeq[byte]()).isErr

  test "Should reject random garbage bytes":
    check Manifest.decode(@[0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).isErr

  test "Should reject truncated bytes":
    check Manifest.decode(Expected_minimal[0 ..< 8]).isErr

  test "Should reject an unsupported manifest version":
    # index 3 is the manifestVersion varint value (0x00 -> 0x01).
    var corrupted = Expected_minimal
    corrupted[3] = 0x01
    check Manifest.decode(corrupted).isErr

  test "Should reject a block size outside the bounds":
    for blockSize in [0'u64, MinBlockSize - 1, MaxBlockSize + 1]:
      checkpoint("blockSize: " & $blockSize)
      let m = Manifest.new(
        treeCid = cidA, blockSize = blockSize.NBytes, datasetSize = 1048576.NBytes
      )
      check Manifest.decode(m.encode().get).isErr

  test "Should reject a zero dataset size":
    let m =
      Manifest.new(treeCid = cidA, blockSize = 65536.NBytes, datasetSize = 0.NBytes)
    check Manifest.decode(m.encode().get).isErr

  test "Should reject a manifest with a corrupted first byte":
    var corrupted = Expected_minimal
    corrupted[0] = 0x12
    check Manifest.decode(corrupted).isErr

  test "Should reject a size field above high(int)":
    const twoPow63 = @[0x80'u8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
    var
      blockSize = Expected_minimal[0 ..< 43] & twoPow63 & Expected_minimal[46 .. ^1]
      datasetSize = Expected_minimal[0 ..< 47] & twoPow63 & Expected_minimal[50 .. ^1]
    blockSize[1] += 7
    datasetSize[1] += 7
    check Manifest.decode(blockSize).isErr
    check Manifest.decode(datasetSize).isErr

  test "Should skip an unknown field and decode to the canonical manifest":
    var withUnknown = Expected_minimal
    withUnknown[1] = withUnknown[1] + 0x02'u8
    withUnknown.add(0x50'u8)
    withUnknown.add(0x01'u8)
    let decoded = Manifest.decode(withUnknown)
    check decoded.isOk
    let reEncoded = decoded.get.encode()
    check reEncoded.isOk
    check reEncoded.get == Expected_minimal

  test "Should decode an empty filename/mimetype string as none":
    let m = Manifest.new(
      treeCid = cidA,
      blockSize = 65536.NBytes,
      datasetSize = 1048576.NBytes,
      filename = "".some,
      mimetype = "".some,
    )
    let encoded = m.encode()
    check encoded.isOk
    let decoded = Manifest.decode(encoded.get)
    check decoded.isOk
    check decoded.get.filename.isNone
    check decoded.get.mimetype.isNone

# ============================================================================
# For reference: minprotobuf encoder that produced the Expected_* bytes above.
# Kept as documentation of the wire-format derivation.
# ============================================================================

when false:
  import pkg/libp2p/protobuf/minprotobuf

  proc legacyEncode(manifest: Manifest): seq[byte] =
    var pbNode = initProtoBuffer()
    var header = initProtoBuffer()
    header.write(1, manifest.manifestVersion)
    header.write(2, manifest.treeCid.data.buffer)
    header.write(3, manifest.blockSize.uint32)
    header.write(4, manifest.datasetSize.uint64)
    header.write(5, manifest.codec.uint32)
    header.write(6, manifest.hcodec.uint32)
    header.write(7, manifest.version.uint32)
    if manifest.filename.isSome:
      header.write(8, manifest.filename.get())
    if manifest.mimetype.isSome:
      header.write(9, manifest.mimetype.get())
    pbNode.write(1, header)
    pbNode.finish()
    pbNode.buffer
