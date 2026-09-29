import std/sequtils

import pkg/storage/utils
import pkg/storage/utils/spr
import pkg/unittest2

import ../helpers

suite "parseDuration":
  test "should parse durations":
    var res: Duration # caller must still know if 'b' refers to bytes|bits
    check parseDuration("10Hr", res) == 3
    check res == hours(10)
    check parseDuration("64min", res) == 3
    check res == minutes(64)
    check parseDuration("7m/block", res) == 2 # '/' stops parse
    check res == minutes(7) # 1 shl 30, forced binary metric
    check parseDuration("3d", res) == 2 # '/' stops parse
    check res == days(3) # 1 shl 30, forced binary metric

  test "should encode PeerInfo to SPR and parse it back":
    let
      info = examplePeerInfo()
      peerRecord =
        SignedPeerRecord.parse(info.toSpr().expect("invalid")).expect("invalid")

    check peerRecord.data.peerId == info.peerId
    check peerRecord.data.seqNo > 0
    check peerRecord.data.addresses.mapIt(it.address).toSeq == info.addrs
