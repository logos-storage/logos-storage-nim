import std/net
import ../asynctest
import ./helpers
import ../../storage/conf
import ../../storage/nat

proc validConfig(): StorageConf =
  StorageConf(
    nat: defaultNatConfig(),
    natObservedAddrMinCount: 1,
    natScheduleInterval: DefaultNatScheduleInterval,
    natMaxRelays: 2,
    natPortMappingDiscoverTimeout: 500,
    natPortMappingTimeout: 500,
    natPortMappingRecheckPeriod: 300000,
  )

suite "Conf - validateAutonatConfig":
  test "accepts a valid config":
    check validConfig().validateAutonatConfig().isOk

  test "rejects autonat server without extip":
    var config = validConfig()
    config.autonatServer = true

    check config.validateAutonatConfig().isErr

  test "accepts autonat server with extip":
    var config = validConfig()
    config.autonatServer = true
    config.nat = nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))

    check config.validateAutonatConfig().isOk

  test "rejects relay server without extip":
    var config = validConfig()
    config.isRelayServer = true

    check config.validateAutonatConfig().isErr

  test "accepts relay server with extip":
    var config = validConfig()
    config.isRelayServer = true
    config.nat = nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))

    check config.validateAutonatConfig().isOk

  test "rejects no-bootstrap-node without extip":
    var config = validConfig()
    config.noBootstrapNode = true

    check config.validateAutonatConfig().isErr

  test "accepts no-bootstrap-node with extip":
    var config = validConfig()
    config.noBootstrapNode = true
    config.nat = nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))

    check config.validateAutonatConfig().isOk

  test "rejects nat-observed-addr-min-count below 1":
    var config = validConfig()
    config.natObservedAddrMinCount = 0

    check config.validateAutonatConfig().isErr

  test "accepts nat-observed-addr-min-count of 1":
    var config = validConfig()
    config.natObservedAddrMinCount = 1

    check config.validateAutonatConfig().isOk

  test "rejects nat-schedule-interval of zero":
    var config = validConfig()
    config.natScheduleInterval = 0.seconds

    check config.validateAutonatConfig().isErr

  test "rejects nat-max-relays below 1":
    var config = validConfig()
    config.natMaxRelays = 0

    check config.validateAutonatConfig().isErr

  test "rejects nat-port-mapping-discover-timeout of zero":
    var config = validConfig()
    config.natPortMappingDiscoverTimeout = 0

    check config.validateAutonatConfig().isErr

  test "rejects nat-port-mapping-timeout of zero":
    var config = validConfig()
    config.natPortMappingTimeout = 0

    check config.validateAutonatConfig().isErr

  test "rejects nat-port-mapping-recheck-period of zero":
    var config = validConfig()
    config.natPortMappingRecheckPeriod = 0

    check config.validateAutonatConfig().isErr

suite "Conf - parseCmdArg":
  test "rejects an invalid NAT config":
    expect ConfigurationError:
      discard parseCmdArg(NatConfig, "none")

  test "rejects an invalid thread count":
    expect ConfigurationError:
      discard parseCmdArg(ThreadCount, "abc")

  test "rejects a thread count below two":
    expect ConfigurationError:
      discard parseCmdArg(ThreadCount, "1")

  test "rejects an invalid duration":
    expect ConfigurationError:
      discard parseCmdArg(Duration, "forever")

  test "rejects an invalid number of bytes":
    expect ConfigurationError:
      discard parseCmdArg(NBytes, "many")

  test "rejects an invalid network preset":
    expect ConfigurationError:
      discard parseCmdArg(NetworkPreset, "unknown")

  test "rejects an invalid multiaddress":
    expect ConfigurationError:
      discard parseCmdArg(MultiAddress, "not-a-multiaddress")

  test "rejects an invalid signed peer record":
    expect ConfigurationError:
      discard parseCmdArg(SignedPeerRecord, "not-an-spr")
