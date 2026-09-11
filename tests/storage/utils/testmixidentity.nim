import std/tables

import pkg/unittest2
import pkg/libp2p/peerid
import pkg/libp2p/multiaddress
import pkg/storage/utils/mixidentity {.all.}

const SamplePoolJson = """
{
  "version": 1,
  "relays": [
    {
      "peerId": "16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP",
      "multiAddr": "/ip4/127.0.0.1/tcp/4242",
      "mixPubKey": "8a6571e8665fb1c894215f97d6a244591b655b1f5fd5ff7f928ef8b74aa66c5f",
      "libp2pPubKey": "03907bc5a41bec7c5ba11f8dfe6c7f779328d2d5bb48c9a978a11e09f3fbf61b3e"
    },
    {
      "peerId": "16Uiu2HAmM6CDJa9HJQ76cRubcpAmrHfMcUCvYncA9M4BfFFEszQn",
      "multiAddr": "/ip4/127.0.0.1/tcp/4243",
      "mixPubKey": "f268d04a1a0903ecf63a3441b986eae414579aa47ff22b071370e6fcd9d3b45c",
      "libp2pPubKey": "037d526dab2572c2336f721813964011899ba7d11a3ebebed1d22d1dea2b74e547"
    }
  ]
}
"""

suite "mixidentity / loadRelayPubInfoTableFromJson":
  test "empty string yields an empty table":
    let res = loadRelayPubInfoTableFromJson("")
    check res.isOk
    check res.get.len == 0

  test "parses a well-formed pool":
    let res = loadRelayPubInfoTableFromJson(SamplePoolJson)
    check res.isOk
    let t = res.get
    check t.len == 2
    let
      p0 = PeerId.init("16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP").get
      p1 = PeerId.init("16Uiu2HAmM6CDJa9HJQ76cRubcpAmrHfMcUCvYncA9M4BfFFEszQn").get
    check p0 in t
    check p1 in t

  test "rejects malformed JSON":
    let res = loadRelayPubInfoTableFromJson("{not json")
    check res.isErr

  test "rejects unsupported version":
    let
      json = """{"version": 99, "relays": []}"""
      res = loadRelayPubInfoTableFromJson(json)
    check res.isErr

  test "rejects missing relays array":
    let
      json = """{"version": 1}"""
      res = loadRelayPubInfoTableFromJson(json)
    check res.isErr

  test "rejects entry missing required field":
    let json = """
{
  "version": 1,
  "relays": [
    {
      "peerId": "16Uiu2HAmNNzXL3wnW64pPFJDwrSJnNaX4CNLeWPbzdPcVJhRTGwP",
      "multiAddr": "/ip4/127.0.0.1/tcp/4242",
      "mixPubKey": "8a6571e8665fb1c894215f97d6a244591b655b1f5fd5ff7f928ef8b74aa66c5f"
    }
  ]
}
"""
    let res = loadRelayPubInfoTableFromJson(json)
    check res.isErr

suite "mixidentity / pickMixCompatibleMultiAddr":
  let
    tcpAddr = MultiAddress.init("/ip4/1.2.3.4/tcp/4001").expect("valid")
    quicAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001/quic-v1").expect("valid")
    udpAddr = MultiAddress.init("/ip4/1.2.3.4/udp/4001").expect("valid")
    ip6Addr = MultiAddress.init("/ip6/::1/tcp/4001").expect("valid")
    circuitAddr = MultiAddress
      .init(
        "/ip4/5.6.7.8/tcp/4002/p2p/16Uiu2HAmQu456Ae52JqPuqog6wCex47LLvNY8oHMBC4GRRtaStHs/p2p-circuit"
      )
      .expect("valid")

  test "picks a TCP address":
    let picked = pickMixCompatibleMultiAddr(@[tcpAddr])

    check picked.isSome

    if picked.isSome:
      check $picked.get == $tcpAddr

  test "picks a QUIC-v1 address":
    let picked = pickMixCompatibleMultiAddr(@[quicAddr])

    check picked.isSome

    if picked.isSome:
      check $picked.get == $quicAddr

  test "returns none on an empty list":
    check pickMixCompatibleMultiAddr(newSeq[MultiAddress]()).isNone

  test "skips a plain UDP address":
    check pickMixCompatibleMultiAddr(@[udpAddr]).isNone

  test "picks the placeholder":
    let picked = pickMixCompatibleMultiAddr(@[mixUnsetMultiAddr()])

    check picked.isSome

    if picked.isSome:
      check $picked.get == $mixUnsetMultiAddr()

  test "returns the first compatible address, skipping the others":
    let picked = pickMixCompatibleMultiAddr(@[udpAddr, tcpAddr, quicAddr])

    check picked.isSome

    if picked.isSome:
      check $picked.get == $tcpAddr

  test "skips an IPv6 address":
    check pickMixCompatibleMultiAddr(@[ip6Addr]).isNone

  test "picks a circuit-relay address":
    let picked = pickMixCompatibleMultiAddr(@[circuitAddr])

    check picked.isSome

    if picked.isSome:
      check $picked.get == $circuitAddr
