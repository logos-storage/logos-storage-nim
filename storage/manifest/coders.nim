## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements serialization and deserialization of Manifest.
##
## ```protobuf
##   Message Manifest {
##     required uint32 manifestVersion = 1; # manifest format version
##     required bytes treeCid = 2;          # cid (root) of the tree
##     required uint32 blockSize = 3;       # size of a single block
##     required uint64 datasetSize = 4;     # size of the dataset
##     required codec: MultiCodec = 5;      # Dataset codec
##     required hcodec: MultiCodec = 6;     # Multihash codec
##     required version: CidVersion = 7;    # Cid version
##     optional filename: string = 8;       # original filename
##     optional mimetype: string = 9;       # original mimetype
##   }
## ```

{.push raises: [].}

import pkg/faststreams
import pkg/libp2p/cid
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec
import pkg/protobuf_serialization/std/enums
import pkg/questionable
import pkg/questionable/results

import ./manifest
import ../blocktype
import ../storagetypes
import ../utils/protobuf/cid
import ../utils/protobuf/multicodec
import ../utils/protobuf/nbytes
import ../utils/protobuf/option
import ../utils/protobuf/refobject

type ManifestEnvelope {.proto2.} = object
  data {.fieldNumber: 1, required.}: seq[byte]

proc encodeManifestFields(manifest: Manifest): seq[byte] {.raises: [IOError].} =
  encode(Protobuf, manifest)

proc decodeManifestFields(
    fields: seq[byte]
): Manifest {.raises: [SerializationError].} =
  decode(Protobuf, fields, Manifest)

proc decodeEnvelope(
    data: openArray[byte]
): ManifestEnvelope {.raises: [SerializationError].} =
  decode(Protobuf, data, ManifestEnvelope)

proc encode*(manifest: Manifest): ?!seq[byte] =
  try:
    encode(Protobuf, ManifestEnvelope(data: encodeManifestFields(manifest))).success
  except IOError as exc:
    failure(exc.msg)

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  if data.len == 0:
    return failure("Empty manifest input")

  let envelope =
    try:
      decodeEnvelope(data)
    except SerializationError as exc:
      return failure("Unable to decode manifest envelope: " & exc.msg)

  let manifest =
    try:
      decodeManifestFields(envelope.data)
    except SerializationError as exc:
      return failure("Unable to decode manifest fields: " & exc.msg)

  if manifest.manifestVersion != 0:
    return failure("Unsupported manifest version: " & $manifest.manifestVersion)

  let blockSize = manifest.blockSize.uint64
  if blockSize < MinBlockSize or blockSize > MaxBlockSize:
    return failure(
      "Manifest block size " & $blockSize & " is outside " & $MinBlockSize & ".." &
        $MaxBlockSize
    )

  if manifest.datasetSize.uint64 == 0:
    return failure("Manifest dataset size is zero")

  manifest.success

proc decode*(_: type Manifest, blk: Block): ?!Manifest =
  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data[])
