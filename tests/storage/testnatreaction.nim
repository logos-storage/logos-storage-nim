import std/[importutils, net]
import pkg/chronos
import pkg/libp2p/[multiaddress, multihash, multicodec]
import pkg/libp2p/protocols/connectivity/autonat/types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/services/autorelayservice except setup
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

  test "handleNatStatus keeps relay off when NotReachable and mapping succeeds":
    skip()
    return

    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper =
      MockNatPortMapper(mappedPorts: some((Port(9000), MappingProtocol.UPnP)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    # A mapping doesn't guarantee reachability, so the relay stays off until
    # AutoNAT confirms Reachable.
    check not autoRelay.isRunning
    check not disc.isServerMode()

  test "handleNatStatus starts autoRelay when NotReachable with no mapped ports":
    let mapper = MockNatPortMapper(mappedPorts: none((Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
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

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check autoRelay.isRunning
    check mapper.portMapping.isSome # the live mapping is kept
    check mapper.destroyed.len == 0 # never torn down
    check not disc.isServerMode()

  test "handleNatStatus recreates a dead mapping instead of pinning it":
    skip()
    return

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

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check mapper.destroyed == @[cint(1)] # the dead mapping is torn down
    check mapper.portMapping.isSome # replaced by a fresh one
    check not autoRelay.isRunning # direct path kept, no relay

  test "handleNatStatus stops relay and exits client mode when mapping is created and node is Reachable":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper = MockNatPortMapper(mappedPorts: none((Port, MappingProtocol)))

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(Reachable, Opt.some(dialBack), disc, sw, autoRelay)

    check not autoRelay.isRunning
    check disc.isServerMode()

  test "handleNatStatus does nothing after the mapper is stopped":
    let dialBack = MultiAddress.init("/ip4/1.2.3.4/tcp/8080").expect("valid")
    let mapper =
      MockNatPortMapper(mappedPorts: some((Port(9000), MappingProtocol.UPnP)))
    mapper.stop()

    autorelayservice.setup(autoRelay, sw)
    await mapper.handleNatStatus(NotReachable, Opt.some(dialBack), disc, sw, autoRelay)

    check not autoRelay.isRunning

  test "handleNatStatus retries the port mapping on the next NotReachable after a failure":
    skip()
    return

    # A failed mapping must not disable the mapper: close() resets plum so the
    # next AutoNAT iteration re-runs discover and tries again.
    let mapper = MockMapNatPortMapper(
      tcpResult: Result[MappingResult, string].err("tcp mapping failed")
    )

    autorelayservice.setup(autoRelay, sw)
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
