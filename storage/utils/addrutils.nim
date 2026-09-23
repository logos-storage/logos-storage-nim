## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/net
import std/strutils
import std/options

import pkg/libp2p
import pkg/libp2p/wire
import pkg/stew/endians2

func remapAddr*(
    address: MultiAddress,
    ip: Option[IpAddress] = IpAddress.none,
    port: Option[Port] = Port.none,
    protocol: Option[string] = string.none,
): MultiAddress =
  ## Remap addresses to new IP, port, and/or transport protocol (e.g. "tcp" → "udp")
  ##
  ## Assumes a /ip4|ip6/<ip>/tcp|udp/<port> address: anything else crashes (Defect).

  var parts = ($address).split("/")

  parts[2] =
    if ip.isSome:
      $ip.get
    else:
      parts[2]

  parts[3] =
    if protocol.isSome:
      protocol.get
    else:
      parts[3]

  parts[4] =
    if port.isSome:
      $port.get
    else:
      parts[4]

  MultiAddress.init(parts.join("/")).expect("Should construct multiaddress")

func getTcpPort*(ma: MultiAddress): Option[Port] =
  ## Extracts the TCP port from a multiaddress; none when there is no TCP part.
  let tcpPart = ma[multiCodec("tcp")]
  if tcpPart.isErr:
    return Port.none
  let portBytes = tcpPart.get().protoArgument()
  if portBytes.isErr or portBytes.get().len != 2:
    return Port.none
  some(Port(fromBytesBE(uint16, portBytes.get())))

proc hasPublicRelayTransport*(ma: MultiAddress): bool =
  ## True when ``ma`` is a circuit address whose relay is publicly dialable.
  let relayWireStr = ($ma).split("/p2p/")[0]
  let relayWireAddr = MultiAddress.init(relayWireStr).valueOr:
    return false
  relayWireAddr.isPublicMA()

proc isDialableCircuitMA*(ma: MultiAddress): bool =
  ## True when ``ma`` is a circuit address reachable through a public relay.
  ma.isCircuitRelayMA() and ma.hasPublicRelayTransport()

proc dialableAddressPolicy*(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  # Use with switchBuilder.withAddressPolicy.
  # Filter the peerInfo.addrs updated by libp2p without
  # declaring another address mapper.
  if ma.isCircuitRelayMA():
    ma.hasPublicRelayTransport()
  else:
    ma.isPublicMA()

proc getMultiAddrWithIpAndTcpPort*(ip: IpAddress, port: Port): MultiAddress =
  ## Creates a MultiAddress with the specified IP address and TCP port
  ##
  ## Parameters:
  ##   - ip: A valid IP address (IPv4 or IPv6)
  ##   - port: The TCP port number
  ##
  ## Returns:
  ##   A MultiAddress in the format "/ip4/<address>/tcp/<port>" or "/ip6/<address>/tcp/<port>"

  let ipFamily = if ip.family == IpAddressFamily.IPv4: "/ip4/" else: "/ip6/"
  return MultiAddress.init(ipFamily & $ip & "/tcp/" & $port).expect(
      "Failed to construct multiaddress with IP and TCP port"
    )
