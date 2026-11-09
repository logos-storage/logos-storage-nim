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
  ServiceCount* = proc(): int {.gcsafe, raises: [].}
  ServiceConnect* =
    proc(missing: int): Future[void] {.gcsafe, async: (raises: [CancelledError]).}
  ServiceRefresh* = proc(): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

  ServiceKind* = enum
    Nat
    Mix

  RequiredService* = object
    id: string
    needed: ServiceNeeded
    case kind: ServiceKind
    of Nat:
      target: int
      connected: ServiceCount
      connect: ServiceConnect
    of Mix:
      refresh: ServiceRefresh

  ServiceProviders* = ref object
    interval: Duration
    requiredServices: seq[RequiredService]
    checkNow: AsyncEvent
    loop: Future[void].Raising([CancelledError])

func forMix*(
    T: type RequiredService, id: string, needed: ServiceNeeded, refresh: ServiceRefresh
): T =
  T(kind: Mix, id: id, needed: needed, refresh: refresh)

proc forNat*(
    T: type RequiredService,
    discovery: Discovery,
    switch: Switch,
    id: string,
    target: int,
    needed: ServiceNeeded,
): T =
  var peers: seq[PeerId]

  proc connected(): int =
    peers.keepItIf(switch.isConnected(it))
    peers.len

  proc connect(missing: int) {.async: (raises: [CancelledError]).} =
    peers.add(await discovery.connectServiceProviders(id, missing, peers))

  T(
    kind: Nat,
    id: id,
    needed: needed,
    target: target,
    connected: connected,
    connect: connect,
  )

proc new*(T: type ServiceProviders, interval: Duration): T =
  T(interval: interval, checkNow: newAsyncEvent())

proc add*(self: ServiceProviders, service: RequiredService) =
  self.requiredServices.add(service)

func hasRequiredServices*(self: ServiceProviders): bool =
  self.requiredServices.len > 0

proc maintain(self: ServiceProviders) {.async: (raises: [CancelledError]).} =
  for service in self.requiredServices:
    if not service.needed():
      continue

    case service.kind
    of Nat:
      let missing = service.target - service.connected()
      if missing <= 0:
        continue

      debug "Looking up service providers",
        serviceId = service.id, missing, target = service.target
      await service.connect(missing)
    of Mix:
      debug "Refreshing service providers", serviceId = service.id
      await service.refresh()

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
