## Local experiment only. Can a #1587 endpoint decode a reply that carries the
## experimental limit field, and can the experiment decode a #1587 reply?
import pkg/protobuf_serialization
import pkg/protobuf_serialization/std/enums
import pkg/protobuf_serialization/pkg/results
import ../storage/dht_proxy/protocol
import ../storage/utils/protobuf/serializer

type StockResponse {.proto2.} = object
  requestId {.fieldNumber: 3, required, pint.}: uint64
  code {.fieldNumber: 1, required, ext.}: LookupCode
  providers {.fieldNumber: 2.}: seq[seq[byte]]

Protobuf.serializerForResult([StockResponse])

let withLimit = LookupResponse(
  requestId: 7,
  code: LookupCode.Ok,
  providers: @[@[1'u8, 2, 3]],
  limit: Opt.some(12'u64),
).encode()
let old = StockResponse.decode(withLimit)
echo "stock decodes reply with limit: ", old.isOk
if old.isOk:
  doAssert old.get.requestId == 7 and old.get.code == LookupCode.Ok and
    old.get.providers == @[@[1'u8, 2, 3]]
let plain = StockResponse(requestId: 9, code: LookupCode.ErrTooBusy).encode()
let fresh = LookupResponse.decode(plain)
echo "experiment decodes stock reply: ", fresh.isOk
if fresh.isOk:
  doAssert fresh.get.requestId == 9 and fresh.get.limit.isNone
echo "bytes added by the limit field: ",
  withLimit.len -
    LookupResponse(requestId: 7, code: LookupCode.Ok, providers: @[@[1'u8, 2, 3]]).encode().len
