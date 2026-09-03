## logutils is a module that has several goals:
## 1. Fix json logging output (run with `--log-format=json`) which was
##    effectively broken for many types using default Chronicles json
##    serialization.
## 2. Ability to specify log output for textlines and json sinks together or
##    separately
##     - This is useful if consuming json in some kind of log parser and need
##       valid json with real values
##     - eg a shortened Cid is nice to see in a text log in stdout, but won't
##       provide a real Cid when parsed in json
## 4. Remove usages of `nim-json-serialization` from the codebase
## 5. Remove need to declare `writeValue` for new types
## 6. Remove need to [avoid importing or exporting `toJson`, `%`, `%*` to prevent
##    conflicts](https://github.com/logos-storage/logos-storage-nim/pull/645#issuecomment-1838834467)
##
## When declaring a new type, one should consider importing the `storage/logutils`
## module, and specifying `formatIt`. If textlines log output and json log output
## need to be different, overload `formatIt` and specify a `LogFormat`. If json
## serialization is needed, it can be declared with a `%` proc. `logutils`
## imports and exports `nim-serde` which handles the de/serialization, examples
## below. **Only `storage/logutils` needs to be imported.**
##
## Using `logutils` in the Storage codebase:
## - Instead of importing `pkg/chronicles`, import `pkg/storage/logutils`
##     - most of `chronicles` is exported by `logutils`
## - Instead of importing `std/json`, import `pkg/serde/json`
##     - `std/json` is exported by `serde` which is exported by `logutils`
## - Instead of importing `pkg/nim-json-serialization`, import
##   `pkg/serde/json` or use storage-specific overloads by importing `utils/json`
##     - one of the goals is to remove the use of `nim-json-serialization`
##
## ```nim
## import pkg/storage/logutils
##
## type
##   BlockAddress* = object
##     case leaf*: bool
##     of true:
##       treeCid* {.serialize.}: Cid
##       index* {.serialize.}: Natural
##     else:
##       cid* {.serialize.}: Cid
##
## logutils.formatIt(LogFormat.textLines, BlockAddress):
##   if it.leaf:
##     "treeCid: " & shortLog($it.treeCid) & ", index: " & $it.index
##   else:
##     "cid: " & shortLog($it.cid)
##
## logutils.formatIt(LogFormat.json, BlockAddress): %it
##
## # chronicles textlines output
## TRC test tid=14397405 ba="treeCid: zb2*fndjU1, index: 0"
## # chronicles json output
## {"lvl":"TRC","msg":"test","tid":14397405,"ba":{"treeCid":"zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1","index":0}}
## ```
## In this case, `BlockAddress` is just an object, so `nim-serde` can handle
## serializing it without issue (only fields annotated with `{.serialize.}` will
## serialize (aka opt-in serialization)).
##
## If one so wished, another option for the textlines log output, would be to
## simply `toString` the serialised json:
## ```nim
## logutils.formatIt(LogFormat.textLines, BlockAddress): $ %it
## # or, more succinctly:
## logutils.formatIt(LogFormat.textLines, BlockAddress): it.toJson
## ```
## In that case, both the textlines and json sinks would have the same output,
## so we could reduce this even further by not specifying a `LogFormat`:
## ```nim
## type
##   BlockAddress* = object
##     case leaf*: bool
##     of true:
##       treeCid* {.serialize.}: Cid
##       index* {.serialize.}: Natural
##     else:
##       cid* {.serialize.}: Cid
##
## logutils.formatIt(BlockAddress): %it
##
## # chronicles textlines output
## TRC test tid=14400673 ba="{\"treeCid\":\"zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1\",\"index\":0}"
## # chronicles json output
## {"lvl":"TRC","msg":"test","tid":14400673,"ba":{"treeCid":"zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1","index":0}}
## ```

import std/options
import std/sequtils
import std/strutils
import std/sugar
import std/typetraits

import pkg/chronicles except toJson, `%`
import json_serialization/writer as json_serialization_writer
from pkg/chronos import TransportAddress
from pkg/libp2p import Cid, MultiAddress, SignedPeerRecord, `$`
import pkg/questionable
import pkg/questionable/results
import ./utils/json except formatIt # TODO: remove exception?
import pkg/stew/byteutils
import pkg/stint

export byteutils
export chronicles except toJson, formatIt, `%`
export questionable
export sequtils
export json except formatIt
export strutils
export sugar
export results

func shortLog*(long: string, ellipses = "*", start = 3, stop = 6): string =
  ## Returns compact string representation of ``long``.
  var short = long
  let minLen = start + ellipses.len + stop
  if len(short) > minLen:
    short.insert(ellipses, start)

    when (NimMajor, NimMinor) > (1, 4):
      short.delete(start + ellipses.len .. short.high - stop)
    else:
      short.delete(start + ellipses.len, short.high - stop)

  short

func shortHexLog*(long: string): string =
  if long[0 .. 1] == "0x":
    result &= "0x"
  result &= long[2 .. long.high].shortLog("..", 4, 4)

func short0xHexLog*[N: static[int], T: array[N, byte]](v: T): string =
  v.to0xHex.shortHexLog

func short0xHexLog*[T: distinct](v: T): string =
  type BaseType = T.distinctBase
  BaseType(v).short0xHexLog

func short0xHexLog*[U: distinct, T: seq[U]](v: T): string =
  type BaseType = U.distinctBase
  "@[" & v.map(x => BaseType(x).short0xHexLog).join(",") & "]"

func to0xHexLog*[T: distinct](v: T): string =
  type BaseType = T.distinctBase
  BaseType(v).to0xHex

func to0xHexLog*[U: distinct, T: seq[U]](v: T): string =
  type BaseType = U.distinctBase
  "@[" & v.map(x => BaseType(x).to0xHex).join(",") & "]"

proc formatTextLineSeq*(val: seq[string]): string =
  "@[" & val.join(", ") & "]"

template formatIt*(format: LogFormat, T: typedesc, body: untyped) =
  # Provides formatters for logging with Chronicles for the given type and
  # `LogFormat`.
  # NOTE: `seq[T]`, `Option[T]`, and `seq[Option[T]]` are overridden
  # since the base `setProperty` is generic using `auto` and conflicts with
  # providing a generic `seq` and `Option` override.
  when format == LogFormat.json:
    proc formatJsonOption(val: ?T): JsonNode =
      if it =? val:
        json.`%`(body)
      else:
        newJNull()

    proc formatJsonResult*(val: ?!T): JsonNode =
      without it =? val, error:
        let jObj = newJObject()
        jObj["error"] = newJString(error.msg)
        return jObj
      json.`%`(body)

    proc writeValue*(w: var JsonWriter, res: ?!T) {.raises: [IOError].} =
      var it {.inject, used.}: T
      w.writeValue(res.formatJsonResult)

    proc writeValue*(w: var JsonWriter, opt: ?T) {.raises: [IOError].} =
      var it {.inject, used.}: T
      w.writeValue(opt.formatJsonOption)

    proc writeValue*(w: var JsonWriter, opts: seq[?T]) {.raises: [IOError].} =
      var it {.inject, used.}: T
      let v = opts.map(opt => opt.formatJsonOption)
      w.writeValue(json.`%`(v))

    proc writeValue*(w: var JsonWriter, val: seq[T]) {.raises: [IOError].} =
      var it {.inject, used.}: T
      let v = val.map(it => body)
      w.writeValue(json.`%`(v))

    proc writeValue*(w: var JsonWriter, val: T) {.raises: [IOError].} =
      var it {.inject, used.}: T = val
      let v = body
      w.writeValue(json.`%`(v))

  elif format == LogFormat.textLines:
    proc formatTextLineOption*(val: ?T): string =
      var v = "none(" & $T & ")"
      if it =? val:
        v = "some(" & $(body) & ")" # that I used to know :)
      v

    proc formatTextLineResult*(val: ?!T): string =
      without it =? val, error:
        return "Error: " & error.msg
      $(body)

    proc setProperty*(r: var TextLogRecord, key: string, res: ?!T) =
      var it {.inject, used.}: T
      setProperty(r, key, res.formatTextLineResult)

    proc setProperty*(r: var TextLogRecord, key: string, opt: ?T) =
      var it {.inject, used.}: T
      let v = opt.formatTextLineOption
      setProperty(r, key, v)

    proc setProperty*(r: var TextLogRecord, key: string, opts: seq[?T]) =
      var it {.inject, used.}: T
      let v = opts.map(opt => opt.formatTextLineOption)
      setProperty(r, key, v.formatTextLineSeq)

    proc setProperty*(
        r: var TextLogRecord, key: string, val: seq[T]
    ) {.raises: [ValueError, IOError].} =
      var it {.inject, used.}: T
      let v = val.map(it => body)
      setProperty(r, key, v.formatTextLineSeq)

    proc setProperty*(
        r: var TextLogRecord, key: string, val: T
    ) {.raises: [ValueError, IOError].} =
      var it {.inject, used.}: T = val
      let v = body
      setProperty(r, key, v)

template formatIt*(T: type, body: untyped) {.dirty.} =
  formatIt(LogFormat.textLines, T):
    body
  formatIt(LogFormat.json, T):
    body

formatIt(LogFormat.textLines, Cid):
  shortLog($it)
formatIt(LogFormat.json, Cid):
  $it
formatIt(UInt256):
  $it
formatIt(MultiAddress):
  $it
formatIt(SignedPeerRecord):
  $it.data
formatIt(LogFormat.textLines, array[32, byte]):
  it.short0xHexLog
formatIt(LogFormat.json, array[32, byte]):
  it.to0xHex
formatIt(TransportAddress):
  $it
