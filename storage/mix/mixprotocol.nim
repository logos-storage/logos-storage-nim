## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import ../logutils

import pkg/chronos
import pkg/libp2p/protocols/protocol
import pkg/libp2p/stream/connection
import pkg/libp2p/[peerid, multiaddress]
import pkg/libp2p_mix
# import pkg/libp2p_mix

logScope:
  topics = "storage mix-transport protocol"

const MixTransportCodec* = "/storage/mix-transport/1.0.0"

type MixTransportProtocol* = ref object of LPProtocol
  mix: MixProtocol

proc newMixTransportProtocol*(mix: MixProtocol): MixTransportProtocol =
  #mix.registerDestReadBehavior(MixTransportCodec, readLp(MaxLookupResponseBytes))
  let self = MixTransportProtocol(mix: mix)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    info "new MixTranportProtocol connection"

  self.handler = handler
  self.codec = MixTransportCodec
  return self

proc connect*(
    self: MixTransportProtocol, peerId: PeerId, multiaddr: MultiAddress
): Future[Result[void, ref LPError]] {.async: (raises: [CancelledError]).} =
  try:
    info "Connecting to peer over Mix", peerId = $peerId, multiaddres = $multiaddr
    let mixDest = MixDestination.init(peerId, multiaddr)
    let mixConnection = self.mix.toConnection(
      mixDest, MixTransportCodec, MixParameters(expectReply: Opt.some(true))
    )
    ok()
  except LPError as exc:
    return Result[void, ref LPError].err(exc)

#proc sendSessionId(
#    self: MixTransportProtocol,
#    connection: Connection
#) {.async: (raises: [CancelledError]).} =
#  # let sessionId =
#  let sessionIdBytes = sessionId.toBytes()
#  await connection.writeLp(sessionIdBytes
#)
