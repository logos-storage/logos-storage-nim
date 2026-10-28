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
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec

import ../../units

Protobuf.extensionDefaults(NBytes)

func computeFieldSize*(
    field: int, value: NBytes, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, uint64(value), puint64, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: NBytes,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, uint64(value), puint64, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var NBytes,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var raw: uint64
  if readFieldInto(stream, raw, header, puint64):
    if raw > uint64(high(Natural)):
      raise newException(
        SerializationError, "NBytes value " & $raw & " exceeds " & $high(Natural)
      )
    value = NBytes(raw)
    true
  else:
    false
