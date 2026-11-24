## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/presto
import pkg/chronos
import pkg/libp2p
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/results
import pkg/stint

import ../utils/stintutils

proc encodeString*(cid: type Cid): Result[string, cstring] =
  ok($cid)

proc decodeString*(T: type Cid, value: string): Result[Cid, cstring] =
  Cid.init(value).mapErr do(e: CidError) -> cstring:
    case e
    of CidError.Incorrect: "Incorrect Cid".cstring
    of CidError.Unsupported: "Unsupported Cid".cstring
    of CidError.Overrun: "Overrun Cid".cstring
    else: "Error parsing Cid".cstring

proc encodeString*(peerId: PeerId): Result[string, cstring] =
  ok($peerId)

proc decodeString*(T: type PeerId, value: string): Result[PeerId, cstring] =
  PeerId.init(value)

proc encodeString*(address: MultiAddress): Result[string, cstring] =
  ok($address)

proc decodeString*(T: type MultiAddress, value: string): Result[MultiAddress, cstring] =
  let address = MultiAddress.init(value).valueOr:
    return err(cstring"Invalid multiaddress")
  ok(address)

proc decodeString*(T: type SomeUnsignedInt, value: string): Result[T, cstring] =
  Base10.decode(T, value)

proc encodeString*(value: SomeUnsignedInt): Result[string, cstring] =
  ok(Base10.toString(value))

proc decodeString*(T: type Duration, value: string): Result[T, cstring] =
  let v = ?Base10.decode(uint32, value)
  ok(v.minutes)

proc encodeString*(value: Duration): Result[string, cstring] =
  ok($value)

proc decodeString*(T: type bool, value: string): Result[T, cstring] =
  try:
    ok(value.parseBool())
  except CatchableError as exc:
    let s: cstring = exc.msg
    err(s) # err(exc.msg) won't compile

proc encodeString*(value: bool): Result[string, cstring] =
  ok($value)

proc decodeString*(_: type UInt256, value: string): Result[UInt256, cstring] =
  try:
    ok UInt256.fromDecimal(value)
  except ValueError as e:
    err e.msg.cstring

proc decodeString*(
    _: type array[32, byte], value: string
): Result[array[32, byte], cstring] =
  try:
    ok array[32, byte].fromHex(value)
  except ValueError as e:
    err e.msg.cstring

proc decodeString*(t: typedesc[string], value: string): Result[string, cstring] =
  ok(value)

proc encodeString*(value: string): RestResult[string] =
  ok(value)
