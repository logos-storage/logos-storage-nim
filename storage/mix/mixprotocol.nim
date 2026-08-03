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
# import pkg/libp2p_mix
# import pkg/libp2p_mix

logScope:
  topics = "storage mix-transport protocol"

const MixTransportCodec* = "/storage/mix-transport/1.0.0"

type MixTransportProtocol* = ref object of LPProtocol

proc newMixTransportProtocol*(): MixTransportProtocol =
  let self = MixTransportProtocol()

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    info "new MixTranportProtocol connection"

  self.handler = handler
  self.codec = MixTransportCodec
  return self
