# Copyright (c) 2019-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[options, os, strutils, times, net, atomics],
  stew/[objects],
  nat_traversal/[miniupnpc, natpmp],
  json_serialization/std/net,
  results

import pkg/chronos
import pkg/chronicles
import pkg/libp2p

import ./utils
import ./utils/natutils
import ./utils/addrutils

const
  UPNP_TIMEOUT = 200 # ms
  PORT_MAPPING_INTERVAL = 20 * 60 # seconds
  NATPMP_LIFETIME = 60 * 60 # in seconds, must be longer than PORT_MAPPING_INTERVAL

type PortMappings* = object
  internalTcpPort: Port
  externalTcpPort: Port
  internalUdpPort: Port
  externalUdpPort: Port
  description: string

type PortMappingArgs =
  tuple[strategy: NatStrategy, tcpPort, udpPort: Port, description: string]

type NatConfig* = object
  case hasExtIp*: bool
  of true: extIp*: IpAddress
  of false: nat*: NatStrategy

var
  upnp {.threadvar.}: Miniupnp
  npmp {.threadvar.}: NatPmp
  strategy = NatStrategy.NatNone
  natClosed: Atomic[bool]
  extIp: Option[IpAddress]
  activeMappings: seq[PortMappings]
  natThreads: seq[Thread[PortMappingArgs]] = @[]

logScope:
  topics = "nat"

type PrefSrcStatus = enum
  NoRoutingInfo
  PrefSrcIsPublic
  PrefSrcIsPrivate
  BindAddressIsPublic
  BindAddressIsPrivate

## Also does threadvar initialisation.
## Must be called before redirectPorts() in each thread.
proc getExternalIP*(natStrategy: NatStrategy, quiet = false): Option[IpAddress] =
  var externalIP: IpAddress

  if natStrategy == NatStrategy.NatAny or natStrategy == NatStrategy.NatUpnp:
    if upnp == nil:
      upnp = newMiniupnp()

    upnp.discoverDelay = UPNP_TIMEOUT
    let dres = upnp.discover()
    if dres.isErr:
      debug "UPnP", msg = dres.error
    else:
      var
        msg: cstring
        canContinue = true
      case upnp.selectIGD()
      of IGDNotFound:
        msg = "Internet Gateway Device not found. Giving up."
        canContinue = false
      of IGDFound:
        msg = "Internet Gateway Device found."
      of IGDNotConnected:
        msg = "Internet Gateway Device found but it's not connected. Trying anyway."
      of NotAnIGD:
        msg =
          "Some device found, but it's not recognised as an Internet Gateway Device. Trying anyway."
      of IGDIpNotRoutable:
        msg =
          "Internet Gateway Device found and is connected, but with a reserved or non-routable IP. Trying anyway."
      if not quiet:
        debug "UPnP", msg
      if canContinue:
        let ires = upnp.externalIPAddress()
        if ires.isErr:
          debug "UPnP", msg = ires.error
        else:
          # if we got this far, UPnP is working and we don't need to try NAT-PMP
          try:
            externalIP = parseIpAddress(ires.value)
            strategy = NatStrategy.NatUpnp
            return some(externalIP)
          except ValueError as e:
            error "parseIpAddress() exception", err = e.msg
            return

  if natStrategy == NatStrategy.NatAny or natStrategy == NatStrategy.NatPmp:
    if npmp == nil:
      npmp = newNatPmp()
    let nres = npmp.init()
    if nres.isErr:
      debug "NAT-PMP", msg = nres.error
    else:
      let nires = npmp.externalIPAddress()
      if nires.isErr:
        debug "NAT-PMP", msg = nires.error
      else:
        try:
          externalIP = parseIpAddress($(nires.value))
          strategy = NatStrategy.NatPmp
          return some(externalIP)
        except ValueError as e:
          error "parseIpAddress() exception", err = e.msg
          return

# This queries the routing table to get the "preferred source" attribute and
# checks if it's a public IP. If so, then it's our public IP.
#
# Further more, we check if the bind address (user provided, or a "0.0.0.0"
# default) is a public IP. That's a long shot, because code paths involving a
# user-provided bind address are not supposed to get here.
proc getRoutePrefSrc(bindIp: IpAddress): (Option[IpAddress], PrefSrcStatus) =
  let bindAddress = initTAddress(bindIp, Port(0))

  if bindAddress.isAnyLocal():
    let ip = getRouteIpv4()
    if ip.isErr():
      # No route was found, log error and continue without IP.
      error "No routable IP address found, check your network connection",
        error = ip.error
      return (none(IpAddress), NoRoutingInfo)
    elif ip.get().isGlobalUnicast():
      return (some(ip.get()), PrefSrcIsPublic)
    else:
      return (none(IpAddress), PrefSrcIsPrivate)
  elif bindAddress.isGlobalUnicast():
    return (some(bindIp), BindAddressIsPublic)
  else:
    return (none(IpAddress), BindAddressIsPrivate)

# Try to detect a public IP assigned to this host, before trying NAT traversal.
proc getPublicRoutePrefSrcOrExternalIP*(
    natStrategy: NatStrategy, bindIp: IpAddress, quiet = true
): Option[IpAddress] =
  let (prefSrcIp, prefSrcStatus) = getRoutePrefSrc(bindIp)

  case prefSrcStatus
  of NoRoutingInfo, PrefSrcIsPublic, BindAddressIsPublic:
    return prefSrcIp
  of PrefSrcIsPrivate, BindAddressIsPrivate:
    let extIp = getExternalIP(natStrategy, quiet)
    if extIp.isSome:
      return some(extIp.get)

proc doPortMapping(
    strategy: NatStrategy, tcpPort, udpPort: Port, description: string
): Option[(Port, Port)] {.gcsafe.} =
  var
    extTcpPort: Port
    extUdpPort: Port

  if strategy == NatStrategy.NatUpnp:
    for t in [(tcpPort, UPNPProtocol.TCP), (udpPort, UPNPProtocol.UDP)]:
      let
        (port, protocol) = t
        pmres = upnp.addPortMapping(
          externalPort = $port,
          protocol = protocol,
          internalHost = upnp.lanAddr,
          internalPort = $port,
          desc = description,
          leaseDuration = 0,
        )
      if pmres.isErr:
        error "UPnP port mapping", msg = pmres.error, port
        return
      else:
        # let's check it
        let cres =
          upnp.getSpecificPortMapping(externalPort = $port, protocol = protocol)
        if cres.isErr:
          warn "UPnP port mapping check failed. Assuming the check itself is broken and the port mapping was done.",
            msg = cres.error

        info "UPnP: added port mapping",
          externalPort = port, internalPort = port, protocol = protocol
        case protocol
        of UPNPProtocol.TCP:
          extTcpPort = port
        of UPNPProtocol.UDP:
          extUdpPort = port
  elif strategy == NatStrategy.NatPmp:
    for t in [(tcpPort, NatPmpProtocol.TCP), (udpPort, NatPmpProtocol.UDP)]:
      let
        (port, protocol) = t
        pmres = npmp.addPortMapping(
          eport = port.cushort,
          iport = port.cushort,
          protocol = protocol,
          lifetime = NATPMP_LIFETIME,
        )
      if pmres.isErr:
        error "NAT-PMP port mapping", msg = pmres.error, port
        return
      else:
        let extPort = Port(pmres.value)
        info "NAT-PMP: added port mapping",
          externalPort = extPort, internalPort = port, protocol = protocol
        case protocol
        of NatPmpProtocol.TCP:
          extTcpPort = extPort
        of NatPmpProtocol.UDP:
          extUdpPort = extPort
  return some((extTcpPort, extUdpPort))

proc repeatPortMapping(args: PortMappingArgs) {.thread, raises: [ValueError].} =
  ignoreSignalsInThread()
  let
    (strategy, tcpPort, udpPort, description) = args
    interval = initDuration(seconds = PORT_MAPPING_INTERVAL)
    sleepDuration = 1_000 # in ms, also the maximum delay after pressing Ctrl-C

  var lastUpdate = now()

  # We can't use copies of Miniupnp and NatPmp objects in this thread, because they share
  # C pointers with other instances that have already been garbage collected, so
  # we use threadvars instead and initialise them again with getExternalIP(),
  # even though we don't need the external IP's value.
  let ipres = getExternalIP(strategy, quiet = true)
  if ipres.isSome:
    while natClosed.load() == false:
      let
        # we're being silly here with this channel polling because we can't
        # select on Nim channels like on Go ones
        currTime = now()
      if currTime >= (lastUpdate + interval):
        discard doPortMapping(strategy, tcpPort, udpPort, description)
        lastUpdate = currTime

        sleep(sleepDuration)

proc stopNatThreads() {.noconv.} =
  # stop the thread
  debug "Stopping NAT port mapping renewal threads"
  try:
    natClosed.store(true)
    joinThreads(natThreads)
  except Exception as exc:
    warn "Failed to stop NAT port mapping renewal thread", exc = exc.msg

  # delete our port mappings

  # FIXME: if the initial port mapping failed because it already existed for the
  # required external port, we should not delete it. It might have been set up
  # by another program.

  # In Windows, a new thread is created for the signal handler, so we need to
  # initialise our threadvars again.

  let ipres = getExternalIP(strategy, quiet = true)
  if ipres.isSome:
    if strategy == NatStrategy.NatUpnp:
      for entry in activeMappings:
        for t in [
          (entry.externalTcpPort, entry.internalTcpPort, UPNPProtocol.TCP),
          (entry.externalUdpPort, entry.internalUdpPort, UPNPProtocol.UDP),
        ]:
          let
            (eport, iport, protocol) = t
            pmres = upnp.deletePortMapping(externalPort = $eport, protocol = protocol)
          if pmres.isErr:
            error "UPnP port mapping deletion", msg = pmres.error
          else:
            debug "UPnP: deleted port mapping",
              externalPort = eport, internalPort = iport, protocol = protocol
    elif strategy == NatStrategy.NatPmp:
      for entry in activeMappings:
        for t in [
          (entry.externalTcpPort, entry.internalTcpPort, NatPmpProtocol.TCP),
          (entry.externalUdpPort, entry.internalUdpPort, NatPmpProtocol.UDP),
        ]:
          let
            (eport, iport, protocol) = t
            pmres = npmp.deletePortMapping(
              eport = eport.cushort, iport = iport.cushort, protocol = protocol
            )
          if pmres.isErr:
            error "NAT-PMP port mapping deletion", msg = pmres.error
          else:
            debug "NAT-PMP: deleted port mapping",
              externalPort = eport, internalPort = iport, protocol = protocol

proc redirectPorts*(
    strategy: NatStrategy, tcpPort, udpPort: Port, description: string
): Option[(Port, Port)] =
  result = doPortMapping(strategy, tcpPort, udpPort, description)
  if result.isSome:
    let (externalTcpPort, externalUdpPort) = result.get()
    # needed by NAT-PMP on port mapping deletion
    # Port mapping works. Let's launch a thread that repeats it, in case the
    # NAT-PMP lease expires or the router is rebooted and forgets all about
    # these mappings.
    activeMappings.add(
      PortMappings(
        internalTcpPort: tcpPort,
        externalTcpPort: externalTcpPort,
        internalUdpPort: udpPort,
        externalUdpPort: externalUdpPort,
        description: description,
      )
    )
    try:
      natThreads.add(Thread[PortMappingArgs]())
      natThreads[^1].createThread(
        repeatPortMapping, (strategy, externalTcpPort, externalUdpPort, description)
      )
      # atexit() in disguise
      if natThreads.len == 1:
        # we should register the thread termination function only once
        addQuitProc(stopNatThreads)
    except Exception as exc:
      warn "Failed to create NAT port mapping renewal thread", exc = exc.msg

proc setupNat*(
    natStrategy: NatStrategy, tcpPort, udpPort: Port, clientId: string
): tuple[ip: Option[IpAddress], tcpPort, udpPort: Option[Port]] =
  ## Setup NAT port mapping and get external IP address.
  ## If any of this fails, we don't return any IP address but do return the
  ## original ports as best effort.
  ## TODO: Allow for tcp or udp port mapping to be optional.
  if extIp.isNone:
    extIp = getExternalIP(natStrategy)
  if extIp.isSome:
    let ip = extIp.get
    let extPorts = (
      {.gcsafe.}:
        redirectPorts(
          strategy, tcpPort = tcpPort, udpPort = udpPort, description = clientId
        )
    )
    if extPorts.isSome:
      let (extTcpPort, extUdpPort) = extPorts.get()
      (ip: some(ip), tcpPort: some(extTcpPort), udpPort: some(extUdpPort))
    else:
      warn "UPnP/NAT-PMP available but port forwarding failed"
      (ip: none(IpAddress), tcpPort: some(tcpPort), udpPort: some(udpPort))
  else:
    warn "UPnP/NAT-PMP not available"
    (ip: none(IpAddress), tcpPort: some(tcpPort), udpPort: some(udpPort))

proc setupAddress*(
    natConfig: NatConfig, bindIp: IpAddress, tcpPort, udpPort: Port, clientId: string
): tuple[ip: Option[IpAddress], tcpPort, udpPort: Option[Port]] {.gcsafe.} =
  ## Set-up of the external address via any of the ways as configured in
  ## `NatConfig`. In case all fails an error is logged and the bind ports are
  ## selected also as external ports, as best effort and in hope that the
  ## external IP can be figured out by other means at a later stage.
  ## TODO: Allow for tcp or udp bind ports to be optional.

  if natConfig.hasExtIp:
    # any required port redirection must be done by hand
    return (some(natConfig.extIp), some(tcpPort), some(udpPort))

  case natConfig.nat
  of NatStrategy.NatAny:
    let (prefSrcIp, prefSrcStatus) = getRoutePrefSrc(bindIp)

    case prefSrcStatus
    of NoRoutingInfo, PrefSrcIsPublic, BindAddressIsPublic:
      return (prefSrcIp, some(tcpPort), some(udpPort))
    of PrefSrcIsPrivate, BindAddressIsPrivate:
      return setupNat(natConfig.nat, tcpPort, udpPort, clientId)
  of NatStrategy.NatNone:
    let (prefSrcIp, prefSrcStatus) = getRoutePrefSrc(bindIp)

    case prefSrcStatus
    of NoRoutingInfo, PrefSrcIsPublic, BindAddressIsPublic:
      return (prefSrcIp, some(tcpPort), some(udpPort))
    of PrefSrcIsPrivate:
      error "No public IP address found. Should not use --nat:none option"
      return (none(IpAddress), some(tcpPort), some(udpPort))
    of BindAddressIsPrivate:
      error "Bind IP is not a public IP address. Should not use --nat:none option"
      return (none(IpAddress), some(tcpPort), some(udpPort))
  of NatStrategy.NatUpnp, NatStrategy.NatPmp:
    return setupNat(natConfig.nat, tcpPort, udpPort, clientId)

proc nattedAddress*(
    natConfig: NatConfig, addrs: seq[MultiAddress], udpPort: Port
): tuple[libp2p, discovery: seq[MultiAddress]] =
  ## Takes a NAT configuration, sequence of multiaddresses and UDP port and returns:
  ## - Modified multiaddresses with NAT-mapped addresses for libp2p
  ## - Discovery addresses with NAT-mapped UDP ports

  var discoveryAddrs = newSeq[MultiAddress](0)
  let newAddrs = addrs.mapIt:
    block:
      # Extract IP address and port from the multiaddress
      let (ipPart, port) = getAddressAndPort(it)
      if ipPart.isSome and port.isSome:
        # Try to setup NAT mapping for the address
        let (newIP, tcp, udp) =
          setupAddress(natConfig, ipPart.get, port.get, udpPort, "codex")
        if newIP.isSome:
          # NAT mapping successful - add discovery address with mapped UDP port
          discoveryAddrs.add(getMultiAddrWithIPAndUDPPort(newIP.get, udp.get))
          # Remap original address with NAT IP and TCP port
          it.remapAddr(ip = newIP, port = tcp)
        else:
          # NAT mapping failed - use original address
          echo "Failed to get external IP, using original address", it
          discoveryAddrs.add(getMultiAddrWithIPAndUDPPort(ipPart.get, udpPort))
          it
      else:
        # Invalid multiaddress format - return as is
        it
  (newAddrs, discoveryAddrs)
