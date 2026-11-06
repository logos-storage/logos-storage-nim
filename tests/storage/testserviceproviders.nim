import std/importutils
import std/sequtils
import pkg/chronos
import pkg/results

import ../asynctest
import ./helpers
import ../../storage/discovery
import ../../storage/serviceproviders {.all.}

proc mountAndStart(switch: Switch, discovery: Discovery) {.async.} =
  switch.mount(discovery.kad)
  switch.mount(discovery.serviceDiscovery)
  await switch.start()

proc connected(providers: ServiceProviders): seq[PeerId] =
  privateAccess(ServiceProviders)
  privateAccess(MaintainedService)
  providers.services[0].connected

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

  setup:
    advertiserSwitch = newStandardSwitch()
    advertiser = Discovery.new(advertiserSwitch, providedServices = [AutonatServiceId])
    await advertiserSwitch.mountAndStart(advertiser)
    advertiser.startAdvertising()

    clientSwitch = newStandardSwitch()
    client = Discovery.new(
      clientSwitch,
      bootstrapNodes =
        [(advertiserSwitch.peerInfo.peerId, advertiserSwitch.peerInfo.addrs)],
      isServer = false,
    )
    await clientSwitch.mountAndStart(client)
    await client.waitForAd(advertiserSwitch.peerInfo.peerId)

    needed = true
    providers = ServiceProviders.new(
      client,
      clientSwitch,
      1.hours,
      @[
        MaintainedService.init(
          AutonatServiceId,
          1,
          proc(): bool =
            needed,
        )
      ],
    )

  teardown:
    await providers.stop()
    await clientSwitch.stop()
    await advertiserSwitch.stop()

  test "a needed service connects to its providers":
    await providers.maintain()

    check providers.connected == @[advertiserSwitch.peerInfo.peerId]
    check clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

  test "a service that is not needed is not looked up":
    needed = false
    await providers.maintain()

    check providers.connected.len == 0

  test "a service at its target is not looked up again":
    await providers.maintain()
    await providers.maintain()

    check providers.connected == @[advertiserSwitch.peerInfo.peerId]

  test "a disconnected provider is dropped and looked up again":
    await providers.maintain()
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)
    check not clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

    await providers.maintain()

    check providers.connected == @[advertiserSwitch.peerInfo.peerId]
    check clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

  test "start looks up the needed services":
    providers.start()

    check eventually(providers.connected == @[advertiserSwitch.peerInfo.peerId])

  test "a check looks up a service that became needed":
    needed = false
    providers.start()
    check providers.connected.len == 0

    needed = true
    providers.check()
    for _ in 0 ..< 50:
      if providers.connected.len > 0:
        break
      await sleepAsync(100.milliseconds)

    check providers.connected == @[advertiserSwitch.peerInfo.peerId]

  test "stop ends the maintenance loop":
    privateAccess(ServiceProviders)
    providers.start()
    check not providers.loop.isNil

    await providers.stop()
    check providers.loop.isNil
