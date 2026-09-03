## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/os

{.push warning[UnusedImport]: off.}
import std/terminal # Is not used in tests
{.pop.}

import std/options
import std/parseutils
import std/strutils
import std/typetraits
import std/net

import pkg/chronos
import pkg/chronicles/helpers
import pkg/chronicles/topics_registry
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/json_serialization
import pkg/toml_serialization
import pkg/toml_serialization/lexer
import pkg/metrics
import pkg/metrics/chronos_httpserver
import pkg/stew/byteutils
import pkg/libp2p except NATConfig
import pkg/questionable
import pkg/questionable/results

import ./storagetypes
import ./utils/spr
import ./discovery
import ./logutils
import ./stores
import ./units
import ./utils
import ./nat
import ./presets
import ./utils/natutils

from ./blockexchange/engine/downloadmanager import DefaultBlockRetries
from ./dht_proxy/protocol import DefaultMaxInFlightLookups

export
  units, net, storagetypes, defs, logutils, presets, completeCmdArg, parseCmdArg,
  NatConfig

export
  DefaultQuotaBytes, DefaultBlockTtl, DefaultBlockInterval, DefaultNumBlocksPerInterval,
  DefaultBlockRetries

const DefaultNatScheduleInterval* = 2.minutes

type ThreadCount* = distinct Natural

proc `==`*(a, b: ThreadCount): bool {.borrow.}

proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Storage"
    elif defined(macosx):
      "Library" / "Application Support" / "Storage"
    else:
      ".cache" / "storage"

  getHomeDir() / dataDir

const
  storage_enable_api_debug_peers* {.booldefine.} = false
  storage_enable_log_counter* {.booldefine.} = false

  DefaultThreadCount* = ThreadCount(0)
  DefaultApiBindAddress* = "127.0.0.1"

type
  StartUpCmd* {.pure.} = enum
    noCmd
    persistence

  LogKind* {.pure.} = enum
    Auto = "auto"
    Colors = "colors"
    NoColors = "nocolors"
    Json = "json"
    None = "none"

  RepoKind* = enum
    repoFS = "fs"
    repoSQLite = "sqlite"
    repoLevelDb = "leveldb"

  StorageConf* = object
    configFile* {.
      desc: "Loads the configuration from a TOML file",
      defaultValueDesc: "none",
      defaultValue: InputFile.none,
      name: "config-file"
    .}: Option[InputFile]

    logLevel* {.defaultValue: "info", desc: "Sets the log level", name: "log-level".}:
      string

    logFormat* {.
      desc:
        "Specifies what kind of logs should be written to stdout (auto, " &
        "colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: LogKind.Auto,
      name: "log-format"
    .}: LogKind

    metricsEnabled* {.
      desc: "Enable the metrics server", defaultValue: false, name: "metrics"
    .}: bool

    metricsAddress* {.
      desc: "Listening address of the metrics server",
      defaultValue: defaultAddress(config),
      defaultValueDesc: "127.0.0.1",
      name: "metrics-address"
    .}: IpAddress

    metricsPort* {.
      desc: "Listening HTTP port of the metrics server",
      defaultValue: 8008,
      name: "metrics-port"
    .}: Port

    dataDir* {.
      desc: "The directory where Storage will store configuration and data",
      defaultValue: defaultDataDir(),
      defaultValueDesc: "",
      abbr: "d",
      name: "data-dir"
    .}: OutDir

    listenIp* {.
      desc: "IP address to listen on for remote peer connections, can be ipv4 or ipv6",
      defaultValue: "0.0.0.0".parseIpAddress,
      defaultValueDesc: "Listens on all addresses.",
      abbr: "i",
      name: "listen-ip"
    .}: IpAddress

    listenPort* {.
      desc:
        "TCP port to listen on for remote peer connections. Selects a random port if none is specified.",
      defaultValue: 0,
      defaultValueDesc: "Listens on a random free port.",
      abbr: "l",
      name: "listen-port"
    .}: Port

    nat* {.
      desc:
        "Specify method to use for determining public address. " &
        "Must be one of: auto, extip:<IP>.",
      defaultValue: defaultNatConfig(),
      defaultValueDesc: "auto",
      name: "nat"
    .}: NatConfig

    netPrivKeyFile* {.
      desc: "Source of network (secp256k1) private key file path or name",
      defaultValue: "key",
      name: "net-privkey"
    .}: string

    bootstrapNodes* {.
      desc:
        "Specifies one or more bootstrap nodes to use when " &
        "connecting to the network. When specified, overrides " &
        "the network preset option.",
      abbr: "b",
      name: "bootstrap-node"
    .}: seq[SignedPeerRecord]

    noBootstrapNode* {.
      desc:
        "Pass this switch to not bootstrap the node at all. This " &
        "is typically only useful if you are creating a new Logos Storage " & "network.",
      name: "no-bootstrap-node",
      defaultValue: false
    .}: bool

    network* {.
      desc: "The network to connect to. Options are: \n" & NetworkPresetsDescription,
      name: "network",
      defaultValue: DefaultNetworkPreset
    .}: NetworkPreset

    dhtMixProxies* {.
      desc: "Peers used as dht-proxy destinations when Mix is enabled",
      name: "dht-mix-proxy"
    .}: seq[SignedPeerRecord]

    mixEnabled* {.
      desc:
        "Route DHT provider lookups through the Mix protocol via the " &
        "dht-mix-proxy. Hides the requester's identity from the proxy",
      defaultValue: false,
      name: "mix-enabled"
    .}: bool

    mixPool* {.
      desc: "Path to the Mix relay pool JSON file", defaultValue: "", name: "mix-pool"
    .}: string

    mixPoolJson* {.
      desc:
        "Inline JSON content of the Mix relay pool." &
        "Takes precedence over --mix-pool when non-empty",
      defaultValue: "",
      name: "mix-pool-json"
    .}: string

    dhtProxyMaxInFlight* {.
      desc:
        "Max concurrent DHT proxy lookups handled by this node " &
        "(omit to use the protocol default: " & $DefaultMaxInFlightLookups & ")",
      defaultValue: int.none,
      name: "dht-proxy-max-inflight"
    .}: Option[int]

    maxPeers* {.
      desc: "The maximum number of peers to connect to",
      defaultValue: 160,
      name: "max-peers"
    .}: int

    numThreads* {.
      desc:
        "Number of worker threads (\"0\" = use as many threads as there are CPU cores available)",
      defaultValue: DefaultThreadCount,
      name: "num-threads"
    .}: ThreadCount

    agentString* {.
      defaultValue: "Logos Storage",
      desc: "Node agent string which is used as identifier in network",
      name: "agent-string"
    .}: string

    apiBindAddress* {.
      desc: "The REST API bind address",
      defaultValue: string.none,
      defaultValueDesc: DefaultApiBindAddress,
      name: "api-bindaddr",
      hidden
    .}: Option[string]

    apiPort* {.
      desc: "The REST Api port",
      defaultValue: 8080.Port,
      defaultValueDesc: "8080",
      name: "api-port",
      abbr: "p",
      hidden
    .}: Port

    apiCorsAllowedOrigin* {.
      desc:
        "The REST Api CORS allowed origin for downloading data. " &
        "'*' will allow all origins, '' will allow none.",
      defaultValue: string.none,
      defaultValueDesc: "Disallow all cross origin requests to download data",
      name: "api-cors-origin",
      hidden
    .}: Option[string]

    repoKind* {.
      desc: "Backend for main repo store (fs, sqlite, leveldb)",
      defaultValueDesc: "fs",
      defaultValue: repoFS,
      name: "repo-kind"
    .}: RepoKind

    storageQuota* {.
      desc: "The size of the total storage quota dedicated to the node",
      defaultValue: DefaultQuotaBytes,
      defaultValueDesc: $DefaultQuotaBytes,
      name: "storage-quota",
      abbr: "q"
    .}: NBytes

    blockTtl* {.
      desc: "Default block timeout in seconds - 0 disables the ttl",
      defaultValue: DefaultBlockTtl,
      defaultValueDesc: $DefaultBlockTtl,
      name: "block-ttl",
      abbr: "t"
    .}: Duration

    blockMaintenanceInterval* {.
      desc:
        "Time interval in seconds - determines frequency of block " &
        "maintenance cycle: how often blocks are checked " & "for expiration and cleanup",
      defaultValue: DefaultBlockInterval,
      defaultValueDesc: $DefaultBlockInterval,
      name: "block-mi"
    .}: Duration

    blockMaintenanceNumberOfBlocks* {.
      desc: "Number of blocks to check every maintenance cycle",
      defaultValue: DefaultNumBlocksPerInterval,
      defaultValueDesc: $DefaultNumBlocksPerInterval,
      name: "block-mn"
    .}: int

    blockRetries* {.
      desc: "Number of times to retry fetching a block before giving up",
      defaultValue: DefaultBlockRetries,
      defaultValueDesc: $DefaultBlockRetries,
      name: "block-retries"
    .}: int

    discoveryTableIpLimit* {.
      desc: "Maximum number of nodes with the same IP in the discovery routing table",
      defaultValue: 10'u,
      defaultValueDesc: "10",
      name: "discovery-table-ip-limit",
      hidden
    .}: uint

    discoveryBucketIpLimit* {.
      desc:
        "Maximum number of nodes with the same IP per bucket in the discovery routing table",
      defaultValue: 2'u,
      defaultValueDesc: "2",
      name: "discovery-bucket-ip-limit",
      hidden
    .}: uint

    logFile* {.
      desc: "Logs to file", defaultValue: string.none, name: "log-file", hidden
    .}: Option[string]

    natScheduleInterval* {.
      desc: "Interval between AutoNAT reachability checks",
      defaultValue: DefaultNatScheduleInterval,
      defaultValueDesc: $DefaultNatScheduleInterval,
      name: "nat-schedule-interval"
    .}: Duration

    natNumPeersToAsk* {.
      desc: "Number of peers to contact per AutoNAT round",
      defaultValue: 3,
      name: "nat-num-peers-to-ask"
    .}: int

    natMaxQueueSize* {.
      desc: "Number of past AutoNAT results kept to calculate confidence",
      defaultValue: 3,
      name: "nat-max-queue-size"
    .}: int

    natMinConfidence* {.
      # With maxQueueSize=3, 0.6 confirms reachability on a 2/3 majority
      # (2/3=0.667) instead of a 3/3 unanimous round, tolerating one inconsistent
      # peer.
      desc: "Minimum confidence threshold to confirm reachability",
      defaultValue: 0.6,
      name: "nat-min-confidence"
    .}: float

    natObservedAddrMinCount* {.
      desc:
        "Minimum number of times that an address must show up in identify replies" &
        "before it is used as the node's dialable address",
      defaultValue: 1,
      name: "nat-observed-addr-min-count"
    .}: int

    natMaxRelays* {.
      desc: "Maximum number of relay servers to reserve slots on simultaneously",
      defaultValue: 2,
      name: "nat-max-relays"
    .}: int

    natPortMappingDiscoverTimeout* {.
      desc: "Timeout in milliseconds for UPnP/NAT-PMP/PCP device discovery",
      defaultValue: 500,
      name: "nat-port-mapping-discover-timeout"
    .}: int

    natPortMappingTimeout* {.
      desc: "Timeout in milliseconds for creating a port mapping on the router",
      defaultValue: 500,
      name: "nat-port-mapping-timeout"
    .}: int

    natPortMappingRecheckPeriod* {.
      desc: "Period in milliseconds between rechecks of existing port mappings",
      defaultValue: 300000,
      name: "nat-port-mapping-recheck-period"
    .}: int

    autonatServer* {.
      desc: "Enable AutoNAT server to help other nodes check their reachability",
      defaultValue: false,
      name: "autonat-server",
      hidden
    .}: bool

    isRelayServer* {.
      desc: "Enable circuit relay server (hop) - use on publicly reachable nodes only",
      defaultValue: false,
      name: "relay-server",
      hidden
    .}: bool

func defaultAddress*(conf: StorageConf): IpAddress =
  result = static parseIpAddress("127.0.0.1")

func defaultNatConfig*(): NatConfig =
  result = NatConfig(hasExtIp: false, nat: NatStrategy.NatAuto)

func validateAutonatConfig*(config: StorageConf): ?!void =
  # An autonat or relay server must be Reachable, assumed with extIp.
  # In other words, a node cannot be autonat server AND autonat client.
  # Currently, only bootstrap nodes should be autonat servers.
  if config.autonatServer and not config.nat.hasExtIp:
    return failure "--autonat-server requires --nat=extip:<IP>"

  if config.isRelayServer and not config.nat.hasExtIp:
    return failure "--relay-server requires --nat=extip:<IP>"

  if config.noBootstrapNode and not config.nat.hasExtIp:
    return failure(
      "--no-bootstrap-node requires --nat=extip:<IP>: without bootstrap peers " &
        "AutoNAT has no one to probe and the node can never become reachable"
    )

  if config.natMaxQueueSize < 1:
    return failure "--nat-max-queue-size must be at least 1"

  if config.natNumPeersToAsk < 1:
    return failure "--nat-num-peers-to-ask must be at least 1"

  if config.natObservedAddrMinCount < 1:
    return failure "--nat-observed-addr-min-count must be at least 1"

  if config.natMinConfidence < 0.0 or config.natMinConfidence > 1.0:
    return failure "--nat-min-confidence must be between 0 and 1"

  if config.natScheduleInterval <= 0.seconds:
    return failure "--nat-schedule-interval must be greater than 0"

  if config.natMaxRelays < 1:
    return failure "--nat-max-relays must be at least 1"

  if config.natPortMappingDiscoverTimeout < 1:
    return failure "--nat-port-mapping-discover-timeout must be greater than 0"

  if config.natPortMappingTimeout < 1:
    return failure "--nat-port-mapping-timeout must be greater than 0"

  if config.natPortMappingRecheckPeriod < 1:
    return failure "--nat-port-mapping-recheck-period must be greater than 0"

  success()

proc getStorageVersion(): string =
  let tag = strip(staticExec("git describe --tags --abbrev=0"))
  if tag.isEmptyOrWhitespace:
    return "untagged build"
  return tag

proc getStorageRevision(): string =
  # using a slice in a static context breaks nimsuggest for some reason
  var res = strip(staticExec("git rev-parse --short HEAD"))
  return res

proc getNimBanner(): string =
  staticExec("nim --version | grep Version")

const
  storageVersion* = getStorageVersion()
  storageRevision* = getStorageRevision()
  nimBanner* = getNimBanner()

  storageFullVersion* =
    "Storage version:  " & storageVersion & "\p" & "Storage revision: " & storageRevision &
    "\p"

proc parseCmdArg*(
    T: typedesc[MultiAddress], input: string
): MultiAddress {.raises: [ConfigurationError].} =
  let res =
    try:
      MultiAddress.init(input)
    except LPError as exc:
      raise newException(
        ConfigurationError, "Invalid MultiAddress uri " & input & ": " & exc.msg
      )

  if res.isErr:
    raise newException(
      ConfigurationError, "Invalid MultiAddress " & input & ": " & res.error()
    )

  res.get()

proc parse*(T: type ThreadCount, p: string): Result[ThreadCount, string] =
  try:
    let count = parseInt(p)
    if count != 0 and count < 2:
      return err("Invalid number of threads: " & p)
    return ok(ThreadCount(count))
  except ValueError as e:
    return err("Invalid number of threads: " & p & ", error=" & e.msg)

proc parseCmdArg*(
    T: type ThreadCount, input: string
): T {.raises: [ConfigurationError].} =
  let val = ThreadCount.parse(input)
  if val.isErr:
    raise newException(ConfigurationError, val.error())
  return val.get()

proc parseCmdArg*(
    T: type SignedPeerRecord, uri: string
): T {.raises: [ConfigurationError].} =
  let res = SignedPeerRecord.parse(uri)
  if res.isErr:
    raise newException(
      ConfigurationError, "Cannot parse the signed peer " & uri & ": " & res.error.msg
    )
  return res.get()

func parse*(T: type NatConfig, p: string): Result[NatConfig, string] =
  case p.toLowerAscii
  of "auto":
    return ok(NatConfig(hasExtIp: false, nat: NatStrategy.NatAuto))
  else:
    if p.startsWith("extip:"):
      try:
        let ip = parseIpAddress(p[6 ..^ 1])
        return ok(NatConfig(hasExtIp: true, extIp: ip))
      except ValueError:
        let error = "Not a valid IP address: " & p[6 ..^ 1]
        return err(error)
    else:
      return err("Not a valid NAT option: " & p & ". Valid options: auto, extip:<IP>")

proc parseCmdArg*(T: type NatConfig, p: string): T {.raises: [ConfigurationError].} =
  let res = NatConfig.parse(p)
  if res.isErr:
    raise newException(ConfigurationError, res.error())
  return res.get()

proc completeCmdArg*(T: type NatConfig, val: string): seq[string] =
  return @[]

func parse*(T: type NBytes, p: string): Result[NBytes, string] =
  var num = 0'i64
  let count = parseSize(p, num, alwaysBin = true)
  if count == 0:
    return err("Invalid number of bytes: " & p)
  return ok(NBytes(num))

proc parseCmdArg*(T: type NBytes, val: string): T {.raises: [ConfigurationError].} =
  let res = NBytes.parse(val)
  if res.isErr:
    raise newException(ConfigurationError, res.error())
  return res.get()

proc parseCmdArg*(T: type Duration, val: string): T {.raises: [ConfigurationError].} =
  var dur: Duration
  let count = parseDuration(val, dur)
  if count == 0:
    raise newException(ConfigurationError, "Invalid duration: " & val)
  dur

proc parseCmdArg*(
    T: type NetworkPreset, p: string
): NetworkPreset {.raises: [ConfigurationError].} =
  let res = NetworkPresets.find(p)
  if res.isNone:
    raise newException(ConfigurationError, "Invalid network preset: " & p)
  return res.get()

proc readValue*(
    r: var TomlReader, val: var SignedPeerRecord
) {.raises: [SerializationError, IOError].} =
  let uri = r.readValue(string)
  try:
    val = SignedPeerRecord.parseCmdArg(uri)
  except CatchableError as err:
    r.lex.raiseTomlErr(err.msg)

proc readValue*(
    r: var JsonReader, val: var SignedPeerRecord
) {.raises: [SerializationError, IOError].} =
  let
    input = r.readValue(string)
    res = SignedPeerRecord.parse(input)

  if res.isErr:
    r.raiseUnexpectedValue("Invalid SignedPeerRecord: " & res.error.msg)

  val = res.get()

proc readValue*(
    r: var TomlReader, val: var MultiAddress
) {.raises: [SerializationError, IOError].} =
  let input = r.readValue(string)
  try:
    val = MultiAddress.parseCmdArg(input)
  except CatchableError as err:
    r.lex.raiseTomlErr(err.msg)

proc readValue*(
    r: var TomlReader, val: var NBytes
) {.raises: [SerializationError, IOError].} =
  var value = 0'i64
  var str = r.readValue(string)
  let count = parseSize(str, value, alwaysBin = true)
  if count == 0:
    r.lex.raiseTomlErr("Invalid number of bytes: " & str)
  val = NBytes(value)

proc readValue*(
    r: var TomlReader, val: var ThreadCount
) {.raises: [SerializationError, IOError].} =
  var str = r.readValue(string)
  try:
    val = parseCmdArg(ThreadCount, str)
  except CatchableError as err:
    r.lex.raiseTomlErr(err.msg)

proc readValue*(
    r: var TomlReader, val: var Duration
) {.raises: [SerializationError, IOError].} =
  var str = r.readValue(string)
  var dur: Duration
  let count = parseDuration(str, dur)
  if count == 0:
    r.lex.raiseTomlErr("Invalid duration: " & str)
  val = dur

proc readValue*(
    r: var TomlReader, val: var NatConfig
) {.raises: [SerializationError, IOError].} =
  let str = r.readValue(string)
  try:
    val = parseCmdArg(NatConfig, str)
  except CatchableError as err:
    r.lex.raiseTomlErr(err.msg)

proc readValue*(
    r: var TomlReader, val: var NetworkPreset
) {.raises: [SerializationError, IOError].} =
  let
    str = r.readValue(string)
    preset = NetworkPresets.find(str)
  if preset.isNone:
    r.lex.raiseTomlErr("Invalid network preset: " & str)

  val = preset.get()

# no idea why confutils needs this:
proc completeCmdArg*(T: type NBytes, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type Duration, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type ThreadCount, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type NetworkPreset, val: string): seq[string] =
  NetworkPresets.findByPrefix(val)

# silly chronicles, colors is a compile-time property
proc stripAnsi*(v: string): string =
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len: # look for [..m
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0' .. '9'} + {';'}:
            discard # keep looking
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found: # skip adding c
        continue
    res.add c
    inc i

  res

proc updateLogLevel*(logLevel: string) {.raises: [ValueError].} =
  # Updates log levels (without clearing old ones)
  let directives = logLevel.split(";")
  try:
    topics_registry.setLogLevel(parseEnum[LogLevel](directives[0].toUpperAscii))
  except ValueError:
    raise (ref ValueError)(
      msg:
        "Please specify one of: trace, debug, " & "info, notice, warn, error or fatal"
    )

  if directives.len > 1:
    for topicName, settings in parseTopicDirectives(directives[1 ..^ 1]):
      if not setTopicState(topicName, settings.state, settings.logLevel):
        warn "Unrecognized logging topic", topic = topicName

proc openLogFile(conf: StorageConf): Option[IoHandle] =
  if logFilePath =? conf.logFile and logFilePath.len > 0:
    let logFileHandle =
      openFile(logFilePath, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate})
    if logFileHandle.isErr:
      error "failed to open log file",
        path = logFilePath, errorCode = $logFileHandle.error
    else:
      return logFileHandle.option
  return IoHandle.none

proc setupLogging*(conf: StorageConf): Option[IoHandle] =
  let ioHandle =
    if conf.logFile.isSome:
      conf.openLogFile()
    else:
      IoHandle.none

  when defaultChroniclesStream.outputs.type.arity != 3:
    warn "Logging configuration options not enabled in the current build"
  else:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    proc writeAndFlush(f: File, msg: LogOutputStr) =
      try:
        f.write(msg)
        f.flushFile()
      except IOError as err:
        logLoggingFailure(cstring(msg), err)

    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, msg)

    proc noColorsFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, stripAnsi(msg))

    proc fileFlush(logLevel: LogLevel, msg: LogOutputStr) =
      if file =? ioHandle:
        if error =? file.writeFile(stripAnsi(msg).toBytes).errorOption:
          error "failed to write to log file", errorCode = $error

    defaultChroniclesStream.outputs[2].writer = noOutput
    if ioHandle.isSome:
      defaultChroniclesStream.outputs[2].writer = fileFlush

    defaultChroniclesStream.outputs[1].writer = noOutput

    let writer =
      case conf.logFormat
      of LogKind.Auto:
        if isatty(stdout): stdoutFlush else: noColorsFlush
      of LogKind.Colors:
        stdoutFlush
      of LogKind.NoColors:
        noColorsFlush
      of LogKind.Json:
        defaultChroniclesStream.outputs[1].writer = stdoutFlush
        noOutput
      of LogKind.None:
        noOutput

    when storage_enable_log_counter:
      var counter = 0.uint64
      proc numberedWriter(logLevel: LogLevel, msg: LogOutputStr) =
        inc(counter)
        let withoutNewLine = msg[0 ..^ 2]
        writer(logLevel, withoutNewLine & " count=" & $counter & "\n")

      defaultChroniclesStream.outputs[0].writer = numberedWriter
    else:
      defaultChroniclesStream.outputs[0].writer = writer

    return ioHandle

proc setupMetrics*(config: StorageConf): ?!void =
  if config.metricsEnabled:
    let metricsAddress = config.metricsAddress
    notice "Starting metrics HTTP server",
      url = "http://" & $metricsAddress & ":" & $config.metricsPort & "/metrics"
    let server = MetricsHttpServerRef.new($metricsAddress, config.metricsPort).valueOr:
      return failure($error)
    try:
      waitFor server.start()
    except MetricsError as exc:
      return failure(exc.msg)
    except CancelledError:
      return failure("Metrics server start was cancelled")
  success()
