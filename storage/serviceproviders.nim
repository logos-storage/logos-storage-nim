## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos

import ./logutils

logScope:
  topics = "storage service providers"

type
  ServiceNeeded* = proc(): bool {.gcsafe, raises: [].}
  ServiceRefresh* = proc(): Future[void] {.gcsafe, async: (raises: [CancelledError]).}

  RequiredService* = object
    id: string
    needed: ServiceNeeded
    refresh: ServiceRefresh

  ServiceProviders* = ref object
    interval: Duration
    requiredServices: seq[RequiredService]
    checkNow: AsyncEvent
    loop: Future[void].Raising([CancelledError])

func new*(
    T: type RequiredService, id: string, needed: ServiceNeeded, refresh: ServiceRefresh
): T =
  T(id: id, needed: needed, refresh: refresh)

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
