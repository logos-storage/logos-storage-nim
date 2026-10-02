import std/options
import std/strutils

import pkg/unittest2
import pkg/storage/blocktype
import pkg/storage/conf
import pkg/storage/logutils
import pkg/storage/units
import pkg/storage/utils/json
import pkg/libp2p/cid
import pkg/libp2p/multiaddress
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/stint
import ../checktest

export logutils

logStream testlines[textlines[nocolors, notimestamps, dynamic]]
logStream testjson[json[nocolors, notimestamps, dynamic]]

type
  ObjectType = object
    a: string

  DistinctType {.borrow: `.`.} = distinct ObjectType
  RefType = ref object
    a: string

  AnotherType = object
    a: int

# must be defined at the top-level
proc `$`*(t: ObjectType): string =
  "used `$`"

func `%`*(t: RefType): JsonNode =
  %t.a
logutils.formatIt(LogFormat.textLines, ObjectType):
  "formatted_" & it.a
logutils.formatIt(LogFormat.textLines, RefType):
  "formatted_" & it.a
logutils.formatIt(LogFormat.textLines, DistinctType):
  "formatted_" & it.a
logutils.formatIt(LogFormat.json, ObjectType):
  "formatted_" & it.a
logutils.formatIt(LogFormat.json, RefType):
  %it
logutils.formatIt(LogFormat.json, DistinctType):
  "formatted_" & it.a
logutils.formatIt(AnotherType):
  it.a

checksuite "Test logging output":
  var outputLines: string
  var outputJson: string

  proc writeToLines(logLevel: LogLevel, msg: LogOutputStr) =
    outputLines &= msg

  proc writeToJson(logLevel: LogLevel, msg: LogOutputStr) =
    outputJson &= msg

  setup:
    outputLines = ""
    outputJson = ""
    testlines.outputs[0].writer = writeToLines
    testjson.outputs[0].writer = writeToJson

  template logged(prop, expected): auto =
    let toFind = prop & "=" & expected
    outputLines.contains(toFind)

  template loggedJson(prop, expected): auto =
    let jsonVal = !JsonNode.parse(outputJson)
    $jsonVal{prop} == expected

  template log(val) =
    testlines.trace "test", val
    testjson.trace "test", val

  test "logs objects":
    let t = ObjectType(a: "a")
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of objects":
    let t1 = ObjectType(a: "a")
    let t2 = ObjectType(a: "b")
    let t = @[t1, t2]
    log t
    check logged("t", "\"@[formatted_a, formatted_b]\"")
    check loggedJson("t", "[\"formatted_a\",\"formatted_b\"]")

  test "logs ref types":
    let t = RefType(a: "a")
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"a\"")

  test "logs sequences of ref types":
    let t1 = RefType(a: "a")
    let t2 = RefType(a: "b")
    let t = @[t1, t2]
    log t
    check logged("t", "\"@[formatted_a, formatted_b]\"")
    check loggedJson("t", "[\"a\",\"b\"]")

  test "logs distinct types":
    let t = DistinctType(ObjectType(a: "a"))
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of distinct types":
    let t1 = DistinctType(ObjectType(a: "a"))
    let t2 = DistinctType(ObjectType(a: "b"))
    let t = @[t1, t2]
    log t
    check logged("t", "\"@[formatted_a, formatted_b]\"")
    check loggedJson("t", "[\"formatted_a\",\"formatted_b\"]")

  test "formatIt can return non-string types":
    let t = AnotherType(a: 1)
    log t
    check logged("t", "1")
    check loggedJson("t", "1")

  test "logs Option types":
    let t = some ObjectType(a: "a")
    log t
    check logged("t", "some(formatted_a)")
    check loggedJson("t", "\"formatted_a\"")

  test "logs sequences of Option types":
    let t1 = some ObjectType(a: "a")
    let t2 = none ObjectType
    let t = @[t1, t2]
    log t
    check logged("t", "\"@[some(formatted_a), none(ObjectType)]\"")
    check loggedJson("t", """["formatted_a",null]""")

  test "logs Result types -- success with string property":
    let t: ?!ObjectType = success ObjectType(a: "a")
    log t
    check logged("t", "formatted_a")
    check loggedJson("t", "\"formatted_a\"")

  test "logs Result types -- success with int property":
    let t: ?!AnotherType = success AnotherType(a: 1)
    log t
    check logged("t", "1")
    check loggedJson("t", "1")

  test "logs Result types -- failure":
    let t: ?!ObjectType = ObjectType.failure newException(ValueError, "some error")
    log t
    check logged("t", "\"Error: some error\"")
    check loggedJson("t", """{"error":"some error"}""")

  test "can define `$` override for T":
    let o = ObjectType()
    check $o == "used `$`"

  test "logs NByte correctly":
    let nb = 12345.NBytes
    log nb
    check logged("nb", "12345\'NByte")
    check loggedJson("nb", "\"12345\'NByte\"")

  test "logs BlockAddress correctly":
    let cid = Cid.init("zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1").tryGet
    let ba = BlockAddress.init(cid, 0)
    log ba
    check logged("ba", "\"treeCid: zb2*fndjU1, index: 0\"")
    check loggedJson(
      "ba",
      """{"treeCid":"zb2rhgsDE16rLtbwTFeNKbdSobtKiWdjJPvKEuPgrQAfndjU1","index":0}""",
    )

  test "logs Cid correctly":
    let cid = Cid.init("zb2rhmfWaXASbyi15iLqbz5yp3awnSyecpt9jcFnc2YA5TgiD").tryGet
    log cid
    check logged("cid", "zb2*A5TgiD")
    check loggedJson("cid", "\"zb2rhmfWaXASbyi15iLqbz5yp3awnSyecpt9jcFnc2YA5TgiD\"")

  test "logs StUint correctly":
    let stint = 12345678901234.u256
    log stint
    check logged("stint", "12345678901234")
    check loggedJson("stint", "\"12345678901234\"")

  test "logs int correctly":
    let int = 123
    log int
    check logged("int", "123")
    check loggedJson("int", "123")

  test "logs MultiAddress correctly":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet
    log ma
    check logged("ma", "/ip4/127.0.0.1/tcp/0")
    check loggedJson("ma", "\"/ip4/127.0.0.1/tcp/0\"")

  test "logs seq[MultiAddress] correctly":
    let ma = @[
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet,
      MultiAddress.init("/ip4/127.0.0.2/tcp/1").tryGet,
    ]
    log ma
    check logged("ma", "\"[/ip4/127.0.0.1/tcp/0, /ip4/127.0.0.2/tcp/1]\"")
    check loggedJson("ma", "\"[/ip4/127.0.0.1/tcp/0, /ip4/127.0.0.2/tcp/1]\"")
