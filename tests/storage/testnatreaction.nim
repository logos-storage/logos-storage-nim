import std/[importutils, net, sequtils]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
from pkg/libp2p/protocols/connectivity/autonatv2/server import AutonatV2, new
import pkg/libp2p/services/autorelayservice
import pkg/results

import ./helpers
import ../asynctest
import ../../storage/utils/natutils
import ../../storage/nat
import ../../storage/discovery
import ../../storage/rng
import ../../storage/utils

type MockNatPortMapper = ref object of NatPortMapper
  mappedPorts: Option[(Port, MappingProtocol)]

method mapNatPorts*(
    m: MockNatPortMapper
): Future[Option[(Port, MappingProtocol)]] {.async: (raises: [CancelledError]), gcsafe.} =
  m.mappedPorts

method destroyMappingFor(m: MockNatPortMapper, id: cint) {.gcsafe.} =
  discard

type MockMapNatPortMapper = ref object of NatPortMapper
  tcpResult: Result[MappingResult, string]
  live: bool
  createAttempts: seq[PlumProtocol]
  destroyed: seq[cint]
  initAttempts: int

method initPlum(m: MockMapNatPortMapper): Result[void, string] {.gcsafe.} =
  inc m.initAttempts
  ok()

method hasLivePortMapping(m: MockMapNatPortMapper): bool {.gcsafe.} =
  m.portMapping.isSome and m.live

method createMappingFor(
    m: MockMapNatPortMapper, protocol: PlumProtocol, port: uint16
): Future[Result[MappingResult, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  m.createAttempts.add(protocol)
  m.tcpResult

method destroyMappingFor(m: MockMapNatPortMapper, id: cint) {.gcsafe.} =
  m.destroyed.add(id)

proc mappingOk(id: cint, port: uint16): Result[MappingResult, string] =
  Result[MappingResult, string].ok(
    MappingResult(
      id: id,
      mapping: PlumMapping(mappingProtocol: MappingProtocol.UPnP, externalPort: port),
    )
  )

asyncchecksuite "NAT reaction - port mapping":
  var sw: Switch
  var autoRelay: AutoRelayService
  var disc: Discovery

  setup:
    autoRelay = AutoRelayService.new(
      1, relayClientModule.RelayClient.new(), nil, Rng.instance().libp2pRng
    )
    sw = newStandardSwitch()
    await sw.start()
    disc = Discovery.new(sw, isServer = false)

  teardown:
    await sw.stop()

    if autoRelay.isRunning:
      await autoRelay.stop(sw)

  test "a new mapping keeps the relay running until direct reachability is confirmed":
    let mapper = MockMapNatPortMapper(tcpResult: mappingOk(cint(1), 9000))

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), disc, sw, autoRelay
    )
    check mapper.portMapping.isSome
    check autoRelay.isRunning
    check not disc.isServerMode()

    await mapper.handleNatStatus(Reachable, Opt.none(MultiAddress), disc, sw, autoRelay)
    check mapper.portMapping.isSome
    check not autoRelay.isRunning
    check disc.isServerMode()

  test "handleNatStatus starts autoRelay when NotReachable with no mapped ports":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, MappingProtocol)))

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), disc, sw, autoRelay
    )

    check autoRelay.isRunning
    check not disc.isServerMode()

  test "handleNatStatus keeps a live mapping and starts relay when NotReachable":
    privateAccess(PortMapping)
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockMapNatPortMapper(live: true)
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
      )
    )

    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check autoRelay.isRunning
    check mapper.portMapping.isSome # the live mapping is kept
    check mapper.destroyed.len == 0 # never torn down
    check not disc.isServerMode()

  test "handleNatStatus recreates a dead mapping instead of pinning it":
    privateAccess(PortMapping)
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockMapNatPortMapper(live: false, tcpResult: mappingOk(cint(10), 9000))
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
      )
    )

    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check mapper.destroyed == @[cint(1)] # the dead mapping is torn down
    check mapper.portMapping.isSome # replaced by a fresh one
    check autoRelay.isRunning

  test "handleNatStatus stops relay and exits client mode when mapping is created and node is Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, MappingProtocol)))

    await mapper.handleNatStatus(Reachable, Opt.some(dialBack), disc, sw, autoRelay)

    check not autoRelay.isRunning
    check disc.isServerMode()

  test "Reachable without a dialback address stops relay and enables DHT server mode":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, MappingProtocol)))
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), disc, sw, autoRelay
    )
    check autoRelay.isRunning
    check not disc.isServerMode()

    # AddressManager reachability notifications no longer carry a dialback address.
    await mapper.handleNatStatus(Reachable, Opt.none(MultiAddress), disc, sw, autoRelay)
    check not autoRelay.isRunning
    check disc.isServerMode()

  test "handleNatStatus does nothing after the mapper is stopped":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper =
      MockNatPortMapper(mappedPorts: some((Port(9000), MappingProtocol.UPnP)))
    mapper.stop()

    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check not autoRelay.isRunning

  test "handleNatStatus retries the port mapping on the next NotReachable after a failure":
    # A failed mapping must not disable the mapper: close() resets plum so the
    # next AutoNAT iteration re-runs discover and tries again.
    let mapper = MockMapNatPortMapper(
      tcpResult: Result[MappingResult, string].err("tcp mapping failed")
    )

    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), disc, sw, autoRelay
    )
    await mapper.handleNatStatus(
      NotReachable, Opt.none(MultiAddress), disc, sw, autoRelay
    )

    check mapper.initAttempts == 2
    check mapper.createAttempts == @[PlumProtocol.TCP, PlumProtocol.TCP]

proc mapperWith(protocol: MappingProtocol): Option[NatPortMapper] =
  some(NatPortMapper(portMapping: some(PortMapping(activeMappingProtocol: protocol))))

asyncchecksuite "NAT - portMappingStr":
  test "no mapper is none":
    check portMappingStr(none(NatPortMapper)) == "none"

  test "mapper without an active protocol is none":
    check portMappingStr(some(NatPortMapper())) == "none"

  test "UPnP maps to upnp":
    check portMappingStr(mapperWith(MappingProtocol.UPnP)) == "upnp"

  test "NAT-PMP maps to pmp":
    check portMappingStr(mapperWith(MappingProtocol.NatPmp)) == "pmp"

  test "PCP maps to pcp":
    check portMappingStr(mapperWith(MappingProtocol.PCP)) == "pcp"

  test "Direct maps to direct":
    check portMappingStr(mapperWith(MappingProtocol.Direct)) == "direct"

  test "Unknown maps to none":
    check portMappingStr(mapperWith(MappingProtocol.Unknown)) == "none"

asyncchecksuite "NAT - mapNatPorts":
  test "returns the mapped port when the mapping succeeds":
    let mapper = MockMapNatPortMapper(tcpResult: mappingOk(cint(1), 9000))

    check (await mapper.mapNatPorts()) == some((Port(9000), MappingProtocol.UPnP))
    check mapper.destroyed.len == 0

  test "gives up when the TCP mapping fails":
    let mapper = MockMapNatPortMapper(
      tcpResult: Result[MappingResult, string].err("tcp mapping failed")
    )

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts == @[PlumProtocol.TCP]
    check mapper.destroyed.len == 0 # nothing to clean up

  test "does not map when configured with an external IP":
    let mapper = MockMapNatPortMapper(
      natConfig: nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))
    )

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts.len == 0 # short-circuits before any mapping

  test "reuses the existing mapping when it is still live":
    privateAccess(PortMapping)
    let mapper = MockMapNatPortMapper(live: true)
    mapper.portMapping = some(
      PortMapping(
        tcpMappingId: cint(1),
        activeMappingProtocol: MappingProtocol.UPnP,
        activeTcpPort: Port(9000),
      )
    )

    check (await mapper.mapNatPorts()) == some((Port(9000), MappingProtocol.UPnP))
    check mapper.createAttempts.len == 0

  test "does not map after stop, maps again after start":
    let mapper = MockMapNatPortMapper(tcpResult: mappingOk(cint(1), 9000))

    mapper.stop()

    check (await mapper.mapNatPorts()).isNone
    check mapper.createAttempts.len == 0

    mapper.start()

    check (await mapper.mapNatPorts()) == some((Port(9000), MappingProtocol.UPnP))

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

asyncchecksuite "NAT - connecting to NAT servers":
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

  proc connectedOutbound(switch: Switch): bool =
    advertiserSwitch.peerInfo.peerId in switch.connectedPeers(Direction.Out)

  proc inboundSwitch(): Future[Switch] {.async.} =
    let switch = newStandardSwitch()
    await switch.start()
    await advertiserSwitch.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    check eventually(switch.isConnected(advertiserSwitch.peerInfo.peerId))
    check not switch.connectedOutbound()
    switch

  test "connecting to service providers connects to the advertiser":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)
    check not clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

    await connectMissing(
      client, clientSwitch, AutonatServiceId, client.autonatServers(), 1
    )

    check clientSwitch.connectedOutbound()

  test "connecting to service providers connects to none with a limit of zero":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)
    await clientSwitch.disconnect(advertiserSwitch.peerInfo.peerId)

    await connectMissing(
      client, clientSwitch, AutonatServiceId, client.autonatServers(), 0
    )

    check not clientSwitch.isConnected(advertiserSwitch.peerInfo.peerId)

  test "connecting to service providers dials out to a server connected inbound":
    let switch = await inboundSwitch()

    await connectMissing(client, switch, AutonatServiceId, client.autonatServers(), 1)

    check switch.connectedOutbound()

    await switch.stop()

  test "connecting to service providers connects when the connection slots are full":
    discard
      await client.waitForProvider(AutonatServiceId, advertiserSwitch.peerInfo.peerId)
    let
      fullSwitch = newStandardSwitch(maxConnections = 1)
      otherSwitch = newStandardSwitch()
    await fullSwitch.start()
    await otherSwitch.start()
    await fullSwitch.connect(otherSwitch.peerInfo.peerId, otherSwitch.peerInfo.addrs)

    expect DialFailedError:
      await fullSwitch.connect(
        advertiserSwitch.peerInfo.peerId, advertiserSwitch.peerInfo.addrs
      )

    await connectMissing(
      client, fullSwitch, AutonatServiceId, client.autonatServers(), 1
    )

    check fullSwitch.connectedOutbound()

    await fullSwitch.stop()
    await otherSwitch.stop()

asyncchecksuite "NAT - AutoNAT helper target":
  var bootstrap, clientSwitch: Switch
  var client: Discovery

  setup:
    bootstrap = newStandardSwitch()
    clientSwitch = newStandardSwitch()

  teardown:
    await clientSwitch.stop()
    await bootstrap.stop()

  proc bootstrapClient() {.async.} =
    await bootstrap.mountAndStart(Discovery.new(bootstrap))
    client = Discovery.new(
      clientSwitch,
      bootstrapNodes = [(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)],
      isServer = false,
    )
    await clientSwitch.mountAndStart(client)
    await clientSwitch.connect(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)

  test "a plain bootstrap leaves room for a separately advertised AutoNAT server":
    await bootstrapClient()
    check clientSwitch.countAutonatHelpers() == 0

    let server = newStandardSwitch()
    server.mount(AutonatV2.new(server))
    let serverDiscovery = Discovery.new(
      server,
      bootstrapNodes = [(bootstrap.peerInfo.peerId, bootstrap.peerInfo.addrs)],
      providedServices = [AutonatServiceId],
    )
    await server.mountAndStart(serverDiscovery)
    defer:
      await server.stop()
    serverDiscovery.startAdvertisingServices()
    let found = await client.waitForProvider(AutonatServiceId, server.peerInfo.peerId)
    check found.anyIt(it.peerId == server.peerInfo.peerId)
    await connectMissing(
      client,
      clientSwitch,
      AutonatServiceId,
      client.autonatServers(),
      1 - clientSwitch.countAutonatHelpers(),
    )
    check eventually(clientSwitch.countAutonatHelpers() == 1)

  test "a capable bootstrap counts without a service advertisement":
    bootstrap.mount(AutonatV2.new(bootstrap))
    await bootstrapClient()
    check eventually(clientSwitch.countAutonatHelpers() == 1)

    await bootstrap.connect(
      clientSwitch.peerInfo.peerId, clientSwitch.peerInfo.addrs, reuseConnection = false
    )
    check eventually(clientSwitch.countAutonatHelpers() == 0)
