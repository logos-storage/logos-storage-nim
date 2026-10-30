## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/faststreams
import pkg/libp2p/multicodec
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec

Protobuf.extensionDefaults(MultiCodec, puint32)

func computeFieldSize*(
    field: int, value: MultiCodec, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, uint32(value), puint32, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: MultiCodec,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, uint32(value), puint32, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var MultiCodec,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var raw: uint32
  if readFieldInto(stream, raw, header, puint32):
    value = MultiCodec(raw)
    true
  else:
    false
