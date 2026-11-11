import std/sequtils
import pkg/chronos
import pkg/results
import pkg/libp2p/protocols/service_discovery except PeerRecord

import ../asynctest
import ./helpers
import ../../storage/discovery

proc mountAndStart(switch: Switch, discovery: Discovery) {.async.} =
  switch.mount(discovery.kad)
  switch.mount(discovery.serviceDiscovery)
  await switch.start()

proc waitForProvider(
    discovery: Discovery, serviceId: string, provider: PeerId
): Future[seq[PeerRecord]] {.async.} =
  for _ in 0 ..< 50:
    let found = (await discovery.findServiceProviders(serviceId)).tryGet()
    if found.anyIt(it.peerId == provider):
      return found
    await sleepAsync(100.milliseconds)

suite "Discovery - provided services":
  test "an AutoNAT server provides the AutoNAT service":
    check providedServices(autonatServer = true, relayServer = false) ==
      @[AutonatServiceId]

  test "a relay server provides the relay service":
    check providedServices(autonatServer = false, relayServer = true) ==
      @[CircuitRelayServiceId]

  test "an AutoNAT and relay server provides both services":
    check providedServices(autonatServer = true, relayServer = true) ==
      @[AutonatServiceId, CircuitRelayServiceId]

  test "a Mix relay provides the Mix service":
    check providedServices(autonatServer = false, relayServer = false, mixRelay = true) ==
      @[MixServiceId]

  test "a DHT proxy server provides the DHT proxy service":
    check providedServices(
      autonatServer = false, relayServer = false, dhtProxyServer = true
    ) == @[DhtProxyServiceId]

  test "a node that is no server provides no service":
    check providedServices(autonatServer = false, relayServer = false).len == 0

asyncchecksuite "Discovery - service discovery":
  var
    advertiserSwitch: Switch
    clientSwitch: Switch
    advertiser: Discovery
    client: Discovery

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

  teardown:
    await clientSwitch.stop()
    await advertiserSwitch.stop()

  test "a server node advertises its services":
    check:
      advertiser.serviceDiscovery.isServer
      AutonatServiceId.hashServiceId() in
        advertiser.serviceDiscovery.advertiser.providedAdverts

  test "a client node does not advertise its services":
    let
      switch = newStandardSwitch()
      discovery = Discovery.new(
        switch, isServer = false, providedServices = [CircuitRelayServiceId]
      )
    await switch.mountAndStart(discovery)

    check:
      not discovery.serviceDiscovery.isServer
      discovery.serviceDiscovery.advertiser.providedAdverts.len == 0

    await switch.stop()

  test "a client finds a node that advertises a service":
    let found =
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)

    check found.len == 1
    check found[0].peerId == advertiserSwitch.peerInfo.peerId
    check found[0].addresses.len > 0

  test "a client finds no provider for a service nobody advertises":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)

    check (await client.findServiceProviders(CircuitRelayServiceId)).tryGet().len == 0

  test "a node does not find itself as a provider":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)

    let found = (await advertiser.findServiceProviders(AutonatServiceId)).tryGet()

    check not found.anyIt(it.peerId == advertiserSwitch.peerInfo.peerId)

  test "connecting to service providers connects to the advertiser":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)
    check not clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

    let connected =
      await client.connectServiceProviders(AutonatServiceId, limit = 1, exclude = @[])

    check connected == @[advertiserSwitch.peerInfo.peerId]
    check clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

  test "connecting to service providers skips the excluded ones":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)

    let connected = await client.connectServiceProviders(
      AutonatServiceId, limit = 1, exclude = @[advertiserSwitch.peerInfo.peerId]
    )

    check connected.len == 0

  test "connecting to service providers connects to none with a limit of zero":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)

    let connected =
      await client.connectServiceProviders(AutonatServiceId, limit = 0, exclude = @[])

    check connected.len == 0

  test "switching to server mode switches the service discovery":
    await client.setServerMode(isServer = true)
    check client.serviceDiscovery.isServer

    await client.setServerMode(isServer = false)
    check not client.serviceDiscovery.isServer

  test "a server node stops advertising in client mode and resumes in server mode":
    await advertiser.setServerMode(isServer = false)
    check AutonatServiceId.hashServiceId() notin
      advertiser.serviceDiscovery.advertiser.providedAdverts

    await advertiser.setServerMode(isServer = true)
    check AutonatServiceId.hashServiceId() in
      advertiser.serviceDiscovery.advertiser.providedAdverts

  test "a Mix relay lookup skips providers without a Mix address":
    let
      switch = newStandardSwitch()
      relay = Discovery.new(
        switch,
        bootstrapNodes =
          [(advertiserSwitch.peerInfo.peerId, advertiserSwitch.peerInfo.addrs)],
        providedServices = [MixServiceId],
      )
    await switch.mountAndStart(relay)
    relay.startAdvertisingServices()
    discard await client.waitForProvider(MixServiceId, switch.peerInfo.peerId)

    check (await client.findMixRelays()).tryGet().len == 0

    await switch.stop()

  test "a node that starts in client mode advertises once in server mode":
    let
      switch = newStandardSwitch()
      discovery = Discovery.new(
        switch, isServer = false, providedServices = [CircuitRelayServiceId]
      )
    await switch.mountAndStart(discovery)

    await discovery.setServerMode(isServer = true)

    check CircuitRelayServiceId.hashServiceId() in
      discovery.serviceDiscovery.advertiser.providedAdverts

    await switch.stop()
