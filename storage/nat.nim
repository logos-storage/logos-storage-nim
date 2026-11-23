# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[options, net, os, random, sequtils, sets, json]
import results

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/services/autorelayservice
import pkg/libp2p/protocols/connectivity/autonatv2/service
import pkg/libp2p/protocols/connectivity/relay/relay as relayProtocol
import pkg/libp2p/protocols/connectivity/dcutr/client as dcutrClientModule
import pkg/libp2p/protocols/connectivity/dcutr/server as dcutrServerModule
import pkg/libp2p/wire

import ./utils
import ./utils/natutils
import ./discovery

logScope:
  topics = "nat"

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy

type PortMapping* = object
  tcpMappingId: cint
  activeMappingProtocol*: MappingProtocol
  activeTcpPort*: Port

type NatPortMapper* = ref object of RootObj
  natConfig*: NatConfig
  tcpPort*: Port
  discoverTimeout*: int
  mappingTimeout*: int
  recheckPeriod*: int
  portMapping*: Option[PortMapping]
  plumInitialized: bool
  stopped: bool

# libplum seams, extracted as methods so tests can override them without I/O.

method initPlum*(m: NatPortMapper): Result[void, string] {.base, gcsafe.} =
  let plumLogLevel =
    if getEnv("DEBUG") == "1": PlumLogLevel.Verbose else: PlumLogLevel.None
  init(
    logLevel = plumLogLevel,
    discoverTimeout = m.discoverTimeout.int32,
    mappingTimeout = m.mappingTimeout.int32,
    recheckPeriod = m.recheckPeriod.int32,
  )

method createMappingFor*(
    m: NatPortMapper, protocol: PlumProtocol, port: uint16
): Future[Result[MappingResult, string]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  await createMapping(protocol, port, port)

method destroyMappingFor*(m: NatPortMapper, id: cint) {.base, gcsafe.} =
  destroyMapping(id)

method hasLivePortMapping*(m: NatPortMapper): bool {.base, gcsafe.} =
  ## True only when a mapping was created AND the TCP mapping is still live in
  ## the router.
  if m.portMapping.isNone:
    return false

  let pm = m.portMapping.get
  hasMapping(pm.tcpMappingId)

proc resetMappings(m: NatPortMapper) =
  if m.portMapping.isSome:
    let pm = m.portMapping.get
    m.destroyMappingFor(pm.tcpMappingId)
    m.portMapping = none(PortMapping)

method mapNatPorts*(
    m: NatPortMapper
): Future[Option[(Port, MappingProtocol)]] {.
    async: (raises: [CancelledError]), base, gcsafe
.} =
  if m.stopped or m.natConfig.hasExtIp:
    return none((Port, MappingProtocol))

  # If the mapping is still live, return the stored port without recreating.
  if m.hasLivePortMapping():
    let pm = m.portMapping.get
    return some((pm.activeTcpPort, pm.activeMappingProtocol))

  if not m.plumInitialized:
    let res = m.initPlum()
    if res.isErr:
      warn "Failed to initialize plum", msg = res.error
      return none((Port, MappingProtocol))
    m.plumInitialized = true

  # If there is only one mapping, something went wrong somewhere
  # so we delete the mappings to recreate them.
  m.resetMappings()

  let tcpRes = await m.createMappingFor(TCP, m.tcpPort.uint16)

  if m.stopped:
    # Double check in case the node is stopping
    return none((Port, MappingProtocol))

  if tcpRes.isErr:
    warn "TCP port mapping failed", msg = tcpRes.error
    return none((Port, MappingProtocol))

  m.portMapping = some(
    PortMapping(
      tcpMappingId: tcpRes.value.id,
      activeMappingProtocol: tcpRes.value.mapping.mappingProtocol,
      activeTcpPort: Port(tcpRes.value.mapping.externalPort),
    )
  )

  let pm = m.portMapping.get
  some((pm.activeTcpPort, pm.activeMappingProtocol))

proc close*(m: NatPortMapper) =
  m.resetMappings()

  if m.plumInitialized:
    discard cleanup()
    m.plumInitialized = false

proc start*(m: NatPortMapper) =
  m.stopped = false

proc stop*(m: NatPortMapper) =
  ## Ensure that any future AutoNAT callback does not re-initialize libplum.
  m.stopped = true
  m.close()

method handleNatStatus*(
    m: NatPortMapper,
    networkReachability: NetworkReachability,
    dialBackAddr: Opt[MultiAddress],
    discovery: Discovery,
    switch: Switch,
    autoRelayService: AutoRelayService,
) {.async: (raises: [CancelledError]), base, gcsafe.} =
  if m.stopped:
    return

  case networkReachability
  of Unknown:
    discard
  of Reachable:
    if autoRelayService.isRunning:
      await autoRelayService.stop(switch)
      debug "AutoRelayService stopped"

    await discovery.setServerMode(isServer = true)
  of NotReachable:
    await discovery.setServerMode(isServer = false)

    if m.hasLivePortMapping():
      # The mapping is still live but the node is not reachable: keep it and let
      # the relay take over. A dead mapping falls through to be recreated.
      debug "Not Reachable with live port mapping, keeping it and starting relay if not started"
    else:
      debug "Node is not reachable trying port mapping now"

      let maybePorts = await m.mapNatPorts()

      if m.stopped:
        # Double check in case the node is stopping
        return

      if maybePorts.isSome:
        let (tcpPort, protocol) = maybePorts.get()

        info "Port mapping created successfully", tcpPort, protocol

        # The announce happens once AutoNAT confirms Reachable.

        return
      else:
        # In case of failure, close the port mapping in order to rerun discover
        # on the next iteration
        m.close()

    if not autoRelayService.isRunning:
      debug "No port mapping found let's start autorelay"

      try:
        await autoRelayService.start(switch)
        debug "AutoRelayService started"
      except LPError as exc:
        warn "Failed to start AutoRelayService", err = exc.msg

proc reachabilityStr*(autonat: Option[AutonatV2Service]): string =
  if autonat.isSome:
    $autonat.get.networkReachability
  else:
    "Unknown"

proc portMappingStr*(natMapper: Option[NatPortMapper]): string =
  if natMapper.isNone or natMapper.get.portMapping.isNone:
    return "none"
  case natMapper.get.portMapping.get.activeMappingProtocol
  of MappingProtocol.UPnP: "upnp"
  of MappingProtocol.NatPmp: "pmp"
  of MappingProtocol.PCP: "pcp"
  of MappingProtocol.Direct: "direct"
  of MappingProtocol.Unknown: "none"

proc peerConnections*(switch: Switch): JsonNode =
  result = newJArray()
  for peerId, muxers in switch.connManager.getConnections():
    let entry = newJObject()
    entry["peerId"] = newJString($peerId)
    entry["direct"] = newJBool(muxers.anyIt(not isRelayed(it.connection)))
    result.add(entry)

proc countOutbound*(servers: seq[PeerRecord], outbound: seq[PeerId]): int =
  servers.countIt(it.peerId in outbound)

proc relayPeers*(relayAddresses: seq[MultiAddress]): HashSet[PeerId] =
  for address in relayAddresses:
    let circuit = address[0 .. ^2].valueOr:
      continue
    let relay = parseFullAddress(circuit).valueOr:
      continue
    result.incl(relay[0])

proc connectMissing*(
    discovery: Discovery,
    switch: Switch,
    serviceId: string,
    servers: seq[PeerRecord],
    missing: int,
) {.async: (raises: [CancelledError]).} =
  proc connect(server: PeerRecord): Future[bool] {.async: (raises: [CancelledError]).} =
    try:
      # AutoNAT and AutoRelay use outbound connections only, so an inbound one is not reused,
      # and NAT needs them even when the connection slots are full.
      await switch.connect(
        server.peerId,
        server.addresses.mapIt(it.address),
        forceDial = true,
        reuseConnection = false,
      )
      return true
    except CancelledError as exc:
      raise exc
    except CatchableError as e:
      warn "Cannot connect to NAT server",
        serviceId, peer = server.peerId, error = e.msg
      return false

  if missing <= 0:
    return

  let outbound = switch.connectedPeers(Direction.Out)
  var candidates = servers.filterIt(it.peerId notin outbound)
  shuffle(candidates)
  if candidates.len > missing:
    candidates.setLen(missing)

  debug "Connecting to NAT servers", serviceId, missing, connecting = candidates.len

  let connects = candidates.mapIt(connect(it))
  try:
    await allFutures(connects)
  except CancelledError as exc:
    await noCancel allFutures(connects.mapIt(it.cancelAndWait()))
    raise exc

  for i, fut in connects:
    if not fut.value():
      discovery.removeServiceProvider(serviceId, candidates[i].peerId)

# Hole punching logic below is adapted from libp2p's HPService
# (libp2p/services/hpservice.nim). HPService cannot be used directly because it
# depends on AutoNAT v1 and starts the relay immediately on NotReachable,
# bypassing the UPnP step.

proc tryStartingDirectConn(
    switch: Switch, peerId: PeerId
): Future[bool] {.async: (raises: [CancelledError]).} =
  proc tryConnect(
      address: MultiAddress
  ): Future[bool] {.async: (raises: [DialFailedError, CancelledError]).} =
    debug "Trying to create direct connection", peerId, address
    await switch.connect(peerId, @[address], true, false)
    debug "Direct connection created."
    return true

  await sleepAsync(500.milliseconds) # wait for AddressBook to be populated
  for address in switch.peerStore[AddressBook][peerId]:
    try:
      let isRelayedAddr = address.contains(multiCodec("p2p-circuit"))
      if not isRelayedAddr.get(false) and address.isPublicMA():
        return await tryConnect(address)
    except CancelledError as exc:
      raise exc
    except CatchableError as err:
      debug "Failed to create direct connection.", description = err.msg
      continue
  return false

proc closeRelayConn(relayedConn: Connection) {.async: (raises: [CancelledError]).} =
  await sleepAsync(2000.milliseconds) # grace period before closing relayed connection
  await relayedConn.close()

proc holePunchIfRelayed*(
    switch: Switch, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Attempts to establish a direct connection when a peer connected via relay.
  ## First tries a direct TCP connect (if the peer's address is known and public),
  ## then falls back to dcutr simultaneous-open hole punching.
  ## Closes the relay connection once a direct path is established.
  let connections =
    switch.connManager.getConnections().getOrDefault(peerId).mapIt(it.connection)
  if connections.anyIt(not isRelayed(it)):
    return
  let incomingRelays = connections.filterIt(it.transportDir == Direction.In)
  if incomingRelays.len == 0:
    return

  let relayedConn = incomingRelays[0]

  if await tryStartingDirectConn(switch, peerId):
    await closeRelayConn(relayedConn)
    return

  var natAddrs = switch.addressManager.mostObservedProtosAndPorts()
  if natAddrs.len == 0:
    natAddrs =
      switch.peerInfo.listenAddrs.mapIt(switch.addressManager.externalAddrFor(it))
  try:
    await DcutrClient.new().startSync(switch, peerId, natAddrs)
    await closeRelayConn(relayedConn)
  except DcutrError as err:
    debug "Hole punching failed during dcutr", description = err.msg

proc setupHolePunching*(switch: Switch): PeerEventHandler =
  try:
    switch.mount(Dcutr.new(switch))
  except LPError as err:
    error "Failed to mount Dcutr protocol", description = err.msg

  let handler = proc(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    await holePunchIfRelayed(switch, peerId)
  switch.addPeerEventHandler(handler, PeerEventKind.Joined)
  handler
