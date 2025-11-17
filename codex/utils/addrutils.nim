## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/strutils
import std/options

import pkg/libp2p
import pkg/stew/shims/net
import pkg/stew/endians2

func remapAddr*(
    address: MultiAddress,
    ip: Option[IpAddress] = IpAddress.none,
    port: Option[Port] = Port.none,
): MultiAddress =
  ## Remap addresses to new IP and/or Port
  ##

  var parts = ($address).split("/")

  parts[2] =
    if ip.isSome:
      $ip.get
    else:
      parts[2]

  parts[4] =
    if port.isSome:
      $port.get
    else:
      parts[4]

  MultiAddress.init(parts.join("/")).expect("Should construct multiaddress")

proc getMultiAddrWithIPAndUDPPort*(ip: IpAddress, port: Port): MultiAddress =
  ## Creates a MultiAddress with the specified IP address and UDP port
  ## 
  ## Parameters:
  ##   - ip: A valid IP address (IPv4 or IPv6)
  ##   - port: The UDP port number
  ##
  ## Returns:
  ##   A MultiAddress in the format "/ip4/<address>/udp/<port>" or "/ip6/<address>/udp/<port>"

  let ipFamily = if ip.family == IpAddressFamily.IPv4: "/ip4/" else: "/ip6/"
  return MultiAddress.init(ipFamily & $ip & "/udp/" & $port).expect("valid multiaddr")

proc getAddressAndPort*(
    ma: MultiAddress
): tuple[ip: Option[IpAddress], port: Option[Port]] =
  try:
    # Try IPv4 first
    let ipv4Result = ma[multiCodec("ip4")]
    let ip =
      if ipv4Result.isOk:
        let ipBytes = ipv4Result.get().protoArgument().expect("Invalid IPv4 format")
        let ipArray = [ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3]]
        some(IpAddress(family: IPv4, address_v4: ipArray))
      else:
        # Try IPv6 if IPv4 not found
        let ipv6Result = ma[multiCodec("ip6")]
        if ipv6Result.isOk:
          let ipBytes = ipv6Result.get().protoArgument().expect("Invalid IPv6 format")
          var ipArray: array[16, byte]
          for i in 0 .. 15:
            ipArray[i] = ipBytes[i]
          some(IpAddress(family: IPv6, address_v6: ipArray))
        else:
          none(IpAddress)

    # Get TCP Port
    let portResult = ma[multiCodec("tcp")]
    let port =
      if portResult.isOk:
        let portBytes = portResult.get().protoArgument().expect("Invalid port format")
        some(Port(fromBytesBE(uint16, portBytes)))
      else:
        none(Port)
    (ip: ip, port: port)
  except Exception:
    (ip: none(IpAddress), port: none(Port))
