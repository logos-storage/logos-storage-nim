# NAT simulation for integration testing.
#
# It simulates the filtering behaviors (endpoint-independent, address-dependent,
# address-and-port-dependent, double NAT) at the connection level, so the full
# AutoNAT detection and relay stack can be exercised without actual NAT hardware.

{.push raises: [].}

import std/[options, sequtils]
import pkg/chronos
import pkg/chronicles
import pkg/results
import pkg/libp2p
import pkg/libp2p/transports/tcptransport
import pkg/libp2p/transports/transport
import pkg/libp2p/wire

import ../../storage/nat

logScope:
  topics = "nat simulation"

type FilteringBehavior* = enum
  EndpointIndependent
  AddressDependent
  AddressAndPortDependent
  DoubleNat

type NatRouter* = ref object
  filtering*: FilteringBehavior
  conntrack: seq[TransportAddress] # remote addrs we dialed; allows them to connect back
  natMapper*: Option[NatPortMapper]

type NatTransport* = ref object of Transport
  tcp: TcpTransport
  router: NatRouter

proc fromString*(
    T: type FilteringBehavior, s: string
): Result[FilteringBehavior, string] =
  case s
  of "endpoint-independent":
    ok(EndpointIndependent)
  of "address-dependent":
    ok(AddressDependent)
  of "address-and-port-dependent":
    ok(AddressAndPortDependent)
  of "double-nat":
    ok(DoubleNat)
  else:
    err("Unknown filtering behavior: " & s)

proc new*(T: type NatRouter, filtering: FilteringBehavior): T =
  T(filtering: filtering)

proc setFiltering*(r: NatRouter, filtering: FilteringBehavior) =
  debug "NAT filtering changed", previous = r.filtering, next = filtering

  r.filtering = filtering
  r.conntrack = @[]

proc allowInbound(r: NatRouter, remote: TransportAddress, localPort: Port): bool =
  case r.filtering
  of DoubleNat:
    return
      false
        # always blocks: simulates a scenario where inbound connections are never possible
  of EndpointIndependent:
    return true
  else:
    discard

  if r.natMapper.isSome and r.natMapper.get.portMapping.isSome and
      r.natMapper.get.portMapping.get.activeTcpPort == localPort:
    return true

  case r.filtering
  of AddressDependent:
    r.conntrack.anyIt(
      try:
        it.address == remote.address
      except ValueError:
        false
    )
  of AddressAndPortDependent:
    remote in r.conntrack
  else:
    false

proc new*(
    T: type NatTransport,
    router: NatRouter,
    upgrade: Upgrade,
    flags: set[ServerFlags] = {},
): T =
  let self = T(tcp: TcpTransport.new(flags, upgrade), upgrader: upgrade, router: router)
  procCall Transport(self).initialize()
  return self

method start*(
    self: NatTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  await self.tcp.start(addrs)
  self.addrs = self.tcp.addrs
  self.running = true
  self.onRunning.fire()

method stop*(self: NatTransport) {.async: (raises: []).} =
  await self.tcp.stop()
  self.running = false
  self.onStop.fire()

method dial*(
    self: NatTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
    dir: Direction = Direction.Out,
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## establishes an outgoing TCP connection and records the remote address
  ## so it can connect back to us later
  let conn = await self.tcp.dial(hostname, address, peerId, dir)

  if conn.observedAddr.isSome:
    let transportAddr = initTAddress(conn.observedAddr.get)
    if transportAddr.isOk:
      let remote = transportAddr.get
      self.router.conntrack.add(remote)
      proc cleanupConntrack() {.async: (raises: []).} =
        await noCancel conn.closeEvent.wait()
        self.router.conntrack.keepItIf(it != remote)

      asyncSpawn cleanupConntrack()

  return conn

method accept*(
    self: NatTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## waits for an incoming TCP connection and applies the NAT filtering rules
  while true:
    let conn = await self.tcp.accept()

    if self.router.filtering == EndpointIndependent:
      return conn

    if conn.observedAddr.isNone:
      await conn.close()
      continue

    let transportAddr = initTAddress(conn.observedAddr.get)
    if transportAddr.isErr:
      debug "Dropping inbound connection: invalid observed address",
        address = conn.observedAddr.get
      await conn.close()
      continue

    var localPort = Port(0)
    if conn.localAddr.isSome:
      # Local address read from the accepted socket.
      let localAddr = initTAddress(conn.localAddr.get)
      if localAddr.isOk:
        localPort = localAddr.get.port

    if not self.router.allowInbound(transportAddr.get, localPort):
      # The rejected connection is not closed here: tcp.stop() closes all
      # accepted TCP connections on teardown.
      continue

    debug "Inbound connection accepted",
      remote = transportAddr.get, filtering = self.router.filtering
    return conn

method handles*(
    self: NatTransport, address: MultiAddress
): bool {.gcsafe, raises: [].} =
  ## returns true if this transport handles the given address (TCP only)
  if procCall Transport(self).handles(address):
    if address.protocols.isOk:
      return TCP.match(address)

proc withNatTransport*(
    b: SwitchBuilder, router: NatRouter, flags: set[ServerFlags] = {}
): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      NatTransport.new(router, config.upgr, flags)
  )
