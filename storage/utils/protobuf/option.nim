## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options

import pkg/faststreams
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec

Protobuf.extensionDefaults(Option[string], pstring)

template isExtension*(T: type Protobuf, FieldType: type Option[string]): bool =
  true

template flatType*(T: type Protobuf, value: Option[string]): type =
  string

func computeFieldSize*(
    field: int,
    value: Option[string],
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  if value.isSome:
    computeFieldSize(field, value.get, pstring, skipDefault)
  else:
    0

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Option[string],
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  if value.isSome:
    writeField(stream, field, value.get, pstring, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Option[string],
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var raw: string
  if readFieldInto(stream, raw, header, pstring):
    if raw.len > 0:
      value = some(raw)
    true
  else:
    false
