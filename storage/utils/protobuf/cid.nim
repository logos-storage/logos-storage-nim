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
import pkg/libp2p/cid
import pkg/protobuf_serialization
import pkg/protobuf_serialization/codec

Protobuf.extensionDefaults(Cid, pbytes)

func computeFieldSize*(
    field: int, cid: Cid, ProtoType: type ProtobufExt, skipDefault: static bool
): int =
  computeFieldSize(field, cid.data.buffer, pbytes, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    cid: Cid,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, cid.data.buffer, pbytes, skipDefault)

proc readFieldInto*(
    stream: InputStream, cid: var Cid, header: FieldHeader, ProtoType: type ProtobufExt
): bool {.raises: [SerializationError, IOError].} =
  var bytes: seq[byte]
  if not readFieldInto(stream, bytes, header, pbytes):
    return false
  let res = Cid.init(bytes)
  if res.isErr:
    raise newException(SerializationError, "Invalid Cid bytes: " & $res.error)
  cid = res.get()
  true
