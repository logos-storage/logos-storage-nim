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

import pkg/chronos
import pkg/libp2p/[peerid, switch]

import ./discovery
import ./logutils

logScope:
  topics = "storage service providers"

type
  ServiceNeeded* = proc(): bool {.gcsafe, raises: [].}

  MaintainedService* = object
    id: string
    target: int
    needed: ServiceNeeded
    connected: seq[PeerId]

  ServiceProviders* = ref object
    discovery: Discovery
    switch: Switch
    interval: Duration
    services: seq[MaintainedService]
    checkNow: AsyncEvent
    loop: Future[void].Raising([CancelledError])

func init*(
    T: type MaintainedService, id: string, target: int, needed: ServiceNeeded
): T =
  T(id: id, target: target, needed: needed)

proc new*(
    T: type ServiceProviders,
    discovery: Discovery,
    switch: Switch,
    interval: Duration,
    services: seq[MaintainedService],
): T =
  T(
    discovery: discovery,
    switch: switch,
    interval: interval,
    services: services,
    checkNow: newAsyncEvent(),
  )

proc maintain(self: ServiceProviders) {.async: (raises: [CancelledError]).} =
  for i in 0 ..< self.services.len:
    if not self.services[i].needed():
      continue

    let serviceId = self.services[i].id
    self.services[i].connected.keepItIf(self.switch.isConnected(it))

    let missing = self.services[i].target - self.services[i].connected.len
    if missing <= 0:
      continue

    let added = await self.discovery.connectServiceProviders(
      serviceId, missing, self.services[i].connected
    )
    self.services[i].connected.add(added)

    debug "Service providers maintained",
      serviceId,
      connected = self.services[i].connected.len,
      target = self.services[i].target

proc run(self: ServiceProviders) {.async: (raises: [CancelledError]).} =
  while true:
    await self.maintain()
    discard await self.checkNow.wait().withTimeout(self.interval)
    self.checkNow.clear()

proc check*(self: ServiceProviders) =
  self.checkNow.fire()

proc start*(self: ServiceProviders) =
  self.loop = self.run()

proc stop*(self: ServiceProviders) {.async: (raises: []).} =
  if self.loop.isNil:
    return

  await self.loop.cancelAndWait()
  self.loop = nil
