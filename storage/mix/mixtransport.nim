## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/switch
import pkg/libp2p_mix
import pkg/chronos
import pkg/results
# import pkg/libp2p_mix

import ../logutils

import ./mixprotocol

logScope:
  topics = "storage mix-transport"

type MixTransport* = ref object
  switch: Switch
  mix: MixProtocol
  mixTransportProtocol: MixTransportProtocol

proc start*(
    self: MixTransport
): Future[Result[void, ref LPError]] {.async: (raises: [CancelledError]).} =
  try:
    info "Starting MixTransport"
    await self.mixTransportProtocol.start()
    self.switch.mount(self.mixTransportProtocol)
    info "MixTransport started"
    ok()
  except LPError as exc:
    return Result[void, ref LPError].err(exc)

proc newMixTransport*(switch: Switch, mix: MixProtocol): MixTransport =
  let transportProtocol = newMixTransportProtocol()
  let self =
    MixTransport(switch: switch, mix: mix, mixTransportProtocol: transportProtocol)
  return self
