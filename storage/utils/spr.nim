## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils
import std/strutils

import pkg/libp2p/multiaddress
import pkg/libp2p/peerid
import pkg/libp2p/peerinfo
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope
import pkg/questionable/results
import pkg/stew/base64

import ../errors

const SprPrefix* = "spr:"

proc toSpr*(peerInfo: PeerInfo): ?!string =
  let record = SignedPeerRecord.init(
    peerInfo.privateKey, PeerRecord.init(peerInfo.peerId, peerInfo.addrs)
  )

  if record.isErr:
    return failure("Unable to sign the peer record: " & $record.error)

  success SprPrefix & Base64Url.encode(record.get.encode())

proc parse*(T: type SignedPeerRecord, spr: string): ?!SignedPeerRecord =
  if not spr.startsWith(SprPrefix):
    return failure("Missing '" & SprPrefix & "' prefix")

  let bytes = Base64Url.decode(spr[SprPrefix.len .. ^1]).catch
  if bytes.isErr:
    return failure("Invalid base64 in signed peer record: " & bytes.error.msg)

  let record = SignedPeerRecord.decode(bytes.get)
  if record.isErr:
    return failure("Invalid signed peer record: " & $record.error)

  success record.get

proc toPeerIdAndAddrs*(record: SignedPeerRecord): (PeerId, seq[MultiAddress]) =
  (record.data.peerId, record.data.addresses.mapIt(it.address))
