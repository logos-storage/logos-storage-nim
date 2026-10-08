import std/net
import ../asynctest
import ./helpers
import ./examples
import ../../storage/conf
import ../../storage/nat

proc validConfig(): StorageConf =
  StorageConf(
    bootstrapNodes: @[SignedPeerRecord.example],
    nat: defaultNatConfig(),
    natMaxQueueSize: 3,
    natNumPeersToAsk: 5,
    natMinConfidence: 0.7,
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

  test "rejects a node without bootstrap node and without extip":
    var config = validConfig()
    config.bootstrapNodes = @[]

    check config.validateAutonatConfig().isErr

  test "accepts a node without bootstrap node with extip":
    var config = validConfig()
    config.bootstrapNodes = @[]
    config.nat = nat.NatConfig(hasExtIp: true, extIp: parseIpAddress("1.2.3.4"))

    check config.validateAutonatConfig().isOk

  test "rejects nat-max-queue-size below 1":
    var config = validConfig()
    config.natMaxQueueSize = 0

    check config.validateAutonatConfig().isErr

  test "accepts nat-max-queue-size of 1":
    var config = validConfig()
    config.natMaxQueueSize = 1

    check config.validateAutonatConfig().isOk

  test "rejects nat-num-peers-to-ask below 1":
    var config = validConfig()
    config.natNumPeersToAsk = 0

    check config.validateAutonatConfig().isErr

  test "accepts nat-num-peers-to-ask of 1":
    var config = validConfig()
    config.natNumPeersToAsk = 1

    check config.validateAutonatConfig().isOk

  test "rejects nat-observed-addr-min-count below 1":
    var config = validConfig()
    config.natObservedAddrMinCount = 0

    check config.validateAutonatConfig().isErr

  test "accepts nat-observed-addr-min-count of 1":
    var config = validConfig()
    config.natObservedAddrMinCount = 1

    check config.validateAutonatConfig().isOk

  test "rejects negative nat-min-confidence":
    var config = validConfig()
    config.natMinConfidence = -0.1

    check config.validateAutonatConfig().isErr

  test "rejects nat-min-confidence above 1":
    var config = validConfig()
    config.natMinConfidence = 1.1

    check config.validateAutonatConfig().isErr

  test "accepts nat-min-confidence bounds":
    var config = validConfig()

    config.natMinConfidence = 0.0
    check config.validateAutonatConfig().isOk

    config.natMinConfidence = 1.0
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

  test "rejects an invalid multiaddress":
    expect ConfigurationError:
      discard parseCmdArg(MultiAddress, "not-a-multiaddress")

  test "rejects an invalid signed peer record":
    expect ConfigurationError:
      discard parseCmdArg(SignedPeerRecord, "not-an-spr")
