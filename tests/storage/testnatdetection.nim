## NAT detection unit tests: real AutoNAT v2 detecting
## through the NAT simulation, feeding storage's handleNatStatus, which drives
## the relay and client mode.
##
## The MockNatPortMapper simulates a failing port mapping. This is not the aspect
## of the NAT detection that is being tested: we want to test the NAT detection
## logic itself, not the port mapping logic.

import std/options
import pkg/chronos
import pkg/libp2p except setup
import pkg/libp2p/protocols/connectivity/autonatv2/service except setup
import pkg/libp2p/protocols/connectivity/autonatv2/client except setup
import pkg/libp2p/protocols/connectivity/autonatv2/types as autonatv2Types
import pkg/libp2p/protocols/connectivity/relay/client as relayClientModule
import pkg/libp2p/services/autorelayservice except setup
import pkg/libp2p/observedaddrmanager

import ./helpers
import ./natsimulation
import ../asynctest
import ../../storage/utils/natutils
import ../../storage/nat
import ../../storage/discovery
import ../../storage/rng

const
  flags = {ServerFlags.ReuseAddr}
  listenAddr = "/ip4/127.0.0.1/tcp/0"
  # ms — AutoNAT probe + confidence + reaction
  detectTimeout = 20000
  mockMappedTcpPort = Port(40000)

type MockNatPortMapper = ref object of NatPortMapper

method mapNatPorts*(
    m: MockNatPortMapper
): Future[Option[(Port, MappingProtocol)]] {.async: (raises: [CancelledError]), gcsafe.} =
  none((Port, MappingProtocol))

# Simulates a successful PCP mapping
type MockMappingNatPortMapper = ref object of NatPortMapper

method mapNatPorts*(
    m: MockMappingNatPortMapper
): Future[Option[(Port, MappingProtocol)]] {.async: (raises: [CancelledError]), gcsafe.} =
  m.portMapping = some(
    PortMapping(
      activeMappingProtocol: MappingProtocol.PCP, activeTcpPort: mockMappedTcpPort
    )
  )
  some((mockMappedTcpPort, MappingProtocol.PCP))

# Captures the candidate addresses the service sends and answers Reachable, so
# the service flips to reachable and runs its address mapper — without dialing.
type MockAutonatV2Client = ref object of AutonatV2Client
  reqAddrs: seq[MultiAddress]

method sendDialRequest*(
    self: MockAutonatV2Client, pid: PeerId, testAddrs: seq[MultiAddress]
): Future[AutonatV2Response] {.
    async: (raises: [AutonatV2Error, CancelledError, DialFailedError, LPStreamError])
.} =
  self.reqAddrs = testAddrs
  AutonatV2Response(reachability: Reachable)

proc serverSwitch(): Switch =
  SwitchBuilder
    .new()
    .withRng(Rng.instance().libp2pRng)
    .withPrivateKey(PrivateKey.random(Rng.instance().libp2pRng).get())
    .withAddresses(@[MultiAddress.init(listenAddr).get()])
    .withTcpTransport(flags)
    .withNoise()
    .withYamux()
    .withAutonatV2Server()
    .build()

asyncchecksuite "NAT detection - simulated NAT":
  var
    natNode: Switch
    autonat: AutonatV2Service
    relay: AutoRelayService
    disc: Discovery
    server: Switch

  proc setupTopology(router: NatRouter) {.async.} =
    let relayClient = relayClientModule.RelayClient.new()
    natNode = SwitchBuilder
      .new()
      .withRng(Rng.instance().libp2pRng)
      .withPrivateKey(PrivateKey.random(Rng.instance().libp2pRng).get())
      .withAddresses(@[MultiAddress.init(listenAddr).get()])
      .withNatTransport(router, flags)
      .withNoise()
      .withYamux()
      .withCircuitRelay(relayClient)
      .build()

    relay = AutoRelayService.new(1, relayClient, nil, Rng.instance().libp2pRng)
    autorelayservice.setup(relay, natNode)
    # nodes start in client mode until Reachable
    disc = Discovery.new(natNode, isServer = false)

    # Setup real AutoNAT v2 client using nat simulation
    let autonatClient = AutonatV2Client.new(natNode.rng)
    client.setup(autonatClient, natNode)
    natNode.mount(autonatClient)

    # Setup AutoNAT v2 service with maxQueueSize=1 and minConfidence=0.5,
    # so a single dial-back answer (confidence 1.0) is needed.
    let config = AutonatV2ServiceConfig.new(
      scheduleInterval = Opt.some(1.seconds),
      askNewConnectedPeers = true,
      numPeersToAsk = 1,
      maxQueueSize = 1,
      minConfidence = 0.5,
    )
    autonat = AutonatV2Service.new(natNode.rng, autonatClient, config)
    service.setup(autonat, natNode)

    autonat.setStatusAndConfidenceHandler(
      proc(
          reachability: NetworkReachability,
          confidence: Opt[float],
          addrs: Opt[MultiAddress],
      ) {.async: (raises: [CancelledError]).} =
        # One call to our handleNatStatus handler
        await MockNatPortMapper().handleNatStatus(
          reachability, addrs, disc, natNode, relay
        )
    )

    # Create and start one Autonat server (maxQueueSize=1 and minConfidence=0.5)
    server = serverSwitch()
    await server.start()

    # Start the NAT node and connect to the Autonat server (bootstrap node in our network).
    # Then start the Autonat service on the NAT node.
    await natNode.start()
    await natNode.connect(server.peerInfo.peerId, server.peerInfo.addrs)
    await autonat.start(natNode)

  teardown:
    await autonat.stop(natNode)

    if relay.isRunning:
      await relay.stop(natNode)

    await natNode.stop()
    await server.stop()

  test "node behind EIF nat ends up reachable: no relay, not in client mode":
    await setupTopology(NatRouter.new(EndpointIndependent))
    check eventually(
      not relay.isRunning and disc.isServerMode(), timeout = detectTimeout
    )

  test "node behind APDF nat ends up not reachable: relay running, client mode":
    await setupTopology(NatRouter.new(AddressAndPortDependent))
    check eventually(
      relay.isRunning and not disc.isServerMode(), timeout = detectTimeout
    )

  test "node behind double NAT ends up not reachable: relay running, client mode":
    await setupTopology(NatRouter.new(DoubleNat))
    check eventually(
      relay.isRunning and not disc.isServerMode(), timeout = detectTimeout
    )

  test "node recovers (relay stops) when nat switches from APDF to EIF":
    let router = NatRouter.new(AddressAndPortDependent)
    await setupTopology(router)
    check eventually(
      relay.isRunning and not disc.isServerMode(), timeout = detectTimeout
    )

    router.setFiltering(EndpointIndependent)
    check eventually(
      not relay.isRunning and disc.isServerMode(), timeout = detectTimeout
    )

  test "node degrades (relay starts) when nat switches from EIF to APDF":
    let router = NatRouter.new(EndpointIndependent)
    await setupTopology(router)
    check eventually(
      not relay.isRunning and disc.isServerMode(), timeout = detectTimeout
    )

    router.setFiltering(AddressAndPortDependent)
    check eventually(
      relay.isRunning and not disc.isServerMode(), timeout = detectTimeout
    )

asyncchecksuite "NAT detection - dial request candidates":
  # This detects is useful to detect behaviour changes in libp2p
  # that may break our autonat dial request candidate handling.
  #
  # By default, Autonat V2 dials the addresses passed to peerInfo.addrs and
  # uses the first attempt to dial as the primary candidate.
  #
  # With enableDialableCandidates, Autonat V2 also dials the guessDialableAddress
  # as first candidate and use the most observed address as the fallback.
  var sw: Switch

  setup:
    sw = newStandardSwitch()
    await sw.start()

  teardown:
    await sw.stop()

  test "autonat handles the observed dialable address":
    let mockClient = MockAutonatV2Client()
    let autonat = AutonatV2Service.new(
      Rng.instance().libp2pRng,
      mockClient,
      AutonatV2ServiceConfig.new(
        enableDialableCandidates = true, maxQueueSize = 1, minConfidence = 0.5
      ),
    )
    service.setup(autonat, sw)
    await autonat.start(sw) # registers the address mapper on peerInfo

    # observations before the manager trusts an addr in libp2p; the observed
    # port (4001) differs from our listen port on purpose (see dialable below)
    let quorum = 3
    let observed = MultiAddress.init("/ip4/8.8.8.8/tcp/4001").expect("valid")
    for _ in 0 ..< quorum:
      discard sw.peerStore.identify.observedAddrManager.addObservation(observed)

    let sw2 = newStandardSwitch()
    await sw2.start()
    await sw.connect(sw2.peerInfo.peerId, sw2.peerInfo.addrs)

    # The dialable candidate keeps our real listen port and swaps in the
    # observed IP. It must be reached via AutoNAT and peerInfo, so it can only
    # come from guessDialableAddr.
    let tcpPart = sw.peerInfo.listenAddrs[0][1].expect("valid")
    let dialable =
      concat(MultiAddress.init("/ip4/8.8.8.8").expect("valid"), tcpPart).expect("valid")

    # Phase 1: it is submitted as a dial candidate, not 127.0.0.1 from
    # newStandardSwitch.
    check eventually(dialable in mockClient.reqAddrs)

    # Phase 2: the address mapper promotes it into peerInfo.
    check eventually(dialable in sw.peerInfo.addrs)

    await autonat.stop(sw)
    await sw2.stop()
