import std/[net, options]
import pkg/libp2p/multiaddress
import ../asynctest
import ../../storage/utils/addrutils

const relayId = "16Uiu2HAkyRvHo1AyyQY1xiHC8QbYjXCHkZbneVC8dBtJjp1SZcGD"

proc circuitAddr(relayIp: string): MultiAddress =
  MultiAddress
    .init("/ip4/" & relayIp & "/tcp/8070/p2p/" & relayId & "/p2p-circuit")
    .expect("valid")

suite "addrutils - getTcpPort":
  test "extracts port from ipv4 tcp address":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    check getTcpPort(ma) == some(Port(5000))

  test "extracts port from ipv6 tcp address":
    let ma = MultiAddress.init("/ip6/::1/tcp/8080").expect("valid")
    check getTcpPort(ma) == some(Port(8080))

  test "returns none for udp address":
    let ma = MultiAddress.init("/ip4/1.2.3.4/udp/5000").expect("valid")
    check getTcpPort(ma) == Port.none

  test "extracts port 0":
    let ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").expect("valid")
    check getTcpPort(ma) == some(Port(0))

suite "addrutils - remapAddr":
  test "replaces protocol tcp with udp":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(protocol = some("udp"), port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/udp/9000").expect("valid")

  test "replaces only port, keeping protocol":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(port = some(Port(9000)))
    check remapped == MultiAddress.init("/ip4/1.2.3.4/tcp/9000").expect("valid")

  test "replaces only ip, keeping protocol and port":
    let ma = MultiAddress.init("/ip4/1.2.3.4/tcp/5000").expect("valid")
    let remapped = ma.remapAddr(ip = some(parseIpAddress("8.8.8.8")))
    check remapped == MultiAddress.init("/ip4/8.8.8.8/tcp/5000").expect("valid")

suite "addrutils - hasPublicRelayTransport":
  test "true when the relay has a public ip":
    check circuitAddr("204.168.234.45").hasPublicRelayTransport()

  test "false when the relay is loopback":
    check not circuitAddr("127.0.0.1").hasPublicRelayTransport()

  test "false when the relay is a private ip":
    check not circuitAddr("172.17.0.1").hasPublicRelayTransport()

suite "addrutils - dialableAddressPolicy":
  test "keeps a public direct address":
    check MultiAddress
      .init("/ip4/204.168.234.45/tcp/8070")
      .expect("valid")
      .dialableAddressPolicy()

  test "drops a loopback direct address":
    check not MultiAddress
      .init("/ip4/127.0.0.1/tcp/8070")
      .expect("valid")
      .dialableAddressPolicy()

  test "drops a private direct address":
    check not MultiAddress
      .init("/ip4/192.168.100.103/tcp/8070")
      .expect("valid")
      .dialableAddressPolicy()

  test "keeps a circuit address through a public relay":
    check circuitAddr("204.168.234.45").dialableAddressPolicy()

  test "drops a circuit address through a private relay":
    check not circuitAddr("172.17.0.1").dialableAddressPolicy()

suite "addrutils - isPublicNetwork":
  let
    publicAddr = MultiAddress.init("/ip4/204.168.234.45/tcp/8070").expect("valid")
    loopbackAddr = MultiAddress.init("/ip4/127.0.0.1/tcp/8070").expect("valid")
    privateAddr = MultiAddress.init("/ip4/10.1.0.85/tcp/8070").expect("valid")

  test "true when one address is public":
    check isPublicNetwork(@[loopbackAddr, publicAddr])

  test "false when every address is loopback or private":
    check not isPublicNetwork(@[loopbackAddr, privateAddr])
