import std/importutils
import std/sequtils
import pkg/chronos
import pkg/results

import ../asynctest
import ./helpers
import ../../storage/discovery
import ../../storage/nat
import ../../storage/serviceproviders {.all.}

proc mountAndStart(switch: Switch, discovery: Discovery) {.async.} =
  switch.mount(discovery.kad)
  switch.mount(discovery.serviceDiscovery)
  await switch.start()

proc waitForAd(discovery: Discovery, provider: PeerId) {.async.} =
  for _ in 0 ..< 50:
    let found = (await discovery.findServiceProviders(AutonatServiceId)).tryGet()
    if found.anyIt(it.peerId == provider):
      return
    await sleepAsync(100.milliseconds)

asyncchecksuite "Service providers":
  var
    advertiserSwitch: Switch
    clientSwitch: Switch
    advertiser: Discovery
    client: Discovery
    providers: ServiceProviders
    needed: bool

  proc connected(): bool =
    advertiserSwitch.peerInfo.peerId in clientSwitch.connectedPeers(Direction.Out)

  setup:
    advertiserSwitch = newStandardSwitch()
    advertiser = Discovery.new(advertiserSwitch, providedServices = [AutonatServiceId])
    await advertiserSwitch.mountAndStart(advertiser)
    advertiser.startAdvertisingServices()

    clientSwitch = newStandardSwitch()
    client = Discovery.new(
      clientSwitch,
      bootstrapNodes =
        [(advertiserSwitch.peerInfo.peerId, advertiserSwitch.peerInfo.addrs)],
      isServer = false,
    )
    await clientSwitch.mountAndStart(client)
    await client.waitForAd(advertiserSwitch.peerInfo.peerId)
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)

    proc refresh() {.async: (raises: [CancelledError]).} =
      await connectMissing(
        client, clientSwitch, AutonatServiceId, client.autonatServers(), 1
      )

    needed = true
    providers = ServiceProviders.new(1.hours)
    providers.add(
      RequiredService.new(
        AutonatServiceId,
        proc(): bool =
          needed,
        refresh,
      )
    )

  teardown:
    await providers.stop()
    await clientSwitch.stop()
    await advertiserSwitch.stop()

  test "a needed service connects to its providers":
    await providers.maintain()

    check connected()

  test "a service that is not needed is not looked up":
    needed = false
    await providers.maintain()

    check not connected()

  test "a service at its target is not looked up again":
    await providers.maintain()
    await providers.maintain()

    check connected()

  test "a disconnected provider is dropped and looked up again":
    await providers.maintain()
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)
    check not connected()

    await providers.maintain()

    check connected()

  test "start looks up the needed services":
    providers.start()

    check eventually(connected())

  test "a check looks up a service that became needed":
    needed = false
    providers.start()
    check not connected()

    needed = true
    providers.check()

    check eventually(connected())

  test "stop ends the maintenance loop":
    privateAccess(ServiceProviders)
    providers.start()
    check not providers.loop.isNil

    await providers.stop()
    check providers.loop.isNil

  test "a Mix service is refreshed on every maintenance":
    var refreshes = 0
    let service = ServiceProviders.new(1.hours)
    service.add(
      RequiredService.new(
        MixServiceId,
        proc(): bool =
          true,
        proc() {.async: (raises: [CancelledError]).} =
          refreshes.inc,
      )
    )

    await service.maintain()
    await service.maintain()

    check refreshes == 2

  test "a Mix service that is not needed is not refreshed":
    var refreshes = 0
    let service = ServiceProviders.new(1.hours)
    service.add(
      RequiredService.new(
        MixServiceId,
        proc(): bool =
          false,
        proc() {.async: (raises: [CancelledError]).} =
          refreshes.inc,
      )
    )

    await service.maintain()

    check refreshes == 0
