import std/options
import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/tables
from pkg/chronicles import LogLevel
import pkg/storage/conf
import pkg/confutils
import pkg/confutils/defs
import libp2p except setup
import pkg/questionable
import ./clioption

export clioption
export confutils

type
  StorageConfigs* = object
    configs*: seq[StorageConfig]

  StorageConfig* = object
    cliOptions: Table[StartUpCmd, Table[string, CliOption]]
    debugEnabled*: bool

  StorageConfigError* = object of CatchableError

proc cliArgs*(
  config: StorageConfig
): seq[string] {.gcsafe, raises: [StorageConfigError].}

proc raiseStorageConfigError(msg: string) {.raises: [StorageConfigError].} =
  raise newException(StorageConfigError, msg)

template convertError(body) =
  try:
    body
  except CatchableError as e:
    raiseStorageConfigError e.msg

proc init*(_: type StorageConfigs, nodes = 1): StorageConfigs {.raises: [].} =
  StorageConfigs(configs: newSeq[StorageConfig](nodes))

func nodes*(self: StorageConfigs): int =
  self.configs.len

proc checkBounds(self: StorageConfigs, idx: int) {.raises: [StorageConfigError].} =
  if idx notin 0 ..< self.configs.len:
    raiseStorageConfigError "index must be in bounds of the number of nodes"

proc buildConfig(
    config: StorageConfig, msg: string
): StorageConf {.raises: [StorageConfigError].} =
  proc postFix(msg: string): string =
    if msg.len > 0:
      ": " & msg
    else:
      ""

  try:
    return StorageConf.load(cmdLine = config.cliArgs, quitOnFailure = false)
  except ConfigurationError as e:
    raiseStorageConfigError msg & e.msg.postFix

proc addCliOption*(
    config: var StorageConfig, group = StartUpCmd.noCmd, cliOption: CliOption
) {.raises: [StorageConfigError].} =
  var options = config.cliOptions.getOrDefault(group)
  options[cliOption.key] = cliOption # overwrite if already exists
  config.cliOptions[group] = options
  discard config.buildConfig("Invalid cli arg " & $cliOption)

proc addCliOption*(
    config: var StorageConfig, group = StartUpCmd.noCmd, key: string, value = ""
) {.raises: [StorageConfigError].} =
  config.addCliOption(group, CliOption(key: key, value: value))

proc addCliOption*(
    config: var StorageConfig, cliOption: CliOption
) {.raises: [StorageConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, cliOption)

proc addCliOption*(
    config: var StorageConfig, key: string, value = ""
) {.raises: [StorageConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, CliOption(key: key, value: value))

proc cliArgs*(
    config: StorageConfig
): seq[string] {.gcsafe, raises: [StorageConfigError].} =
  ## converts StorageConfig cli options and command groups in a sequence of args
  ## and filters out cli options by node index if provided in the CliOption
  var args: seq[string] = @[]

  convertError:
    for cmd in StartUpCmd:
      if config.cliOptions.hasKey(cmd):
        if cmd != StartUpCmd.noCmd:
          args.add $cmd
        var opts = config.cliOptions[cmd].values.toSeq
        args = args.concat(opts.map(o => $o))

    return args

proc logFile*(config: StorageConfig): ?string {.raises: [StorageConfigError].} =
  let built = config.buildConfig("Invalid storage config cli params")
  built.logFile

proc logLevel*(config: StorageConfig): LogLevel {.raises: [StorageConfigError].} =
  convertError:
    let built = config.buildConfig("Invalid storage config cli params")
    return parseEnum[LogLevel](built.logLevel.toUpperAscii)

proc debug*(
    self: StorageConfigs, idx: int, enabled = true
): StorageConfigs {.raises: [StorageConfigError].} =
  ## output log in stdout for a specific node in the group

  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].debugEnabled = enabled
  return startConfig

proc debug*(self: StorageConfigs, enabled = true): StorageConfigs {.raises: [].} =
  ## output log in stdout for all nodes in group
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.debugEnabled = enabled
  return startConfig

proc withLogFile*(
    self: StorageConfigs, idx: int
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(
    self: StorageConfigs
): StorageConfigs {.raises: [StorageConfigError].} =
  ## typically called from test, sets config such that a log file should be
  ## created
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(
    self: var StorageConfig, logFile: string
) {.raises: [StorageConfigError].} =
  #: StorageConfigs =
  ## typically called internally from the test suite, sets a log file path to
  ## be created during the test run, for a specified node in the group
  # var config = self
  self.addCliOption("--log-file", logFile)
  # return startConfig

proc withLogLevel*(
    self: StorageConfig, level: LogLevel | string
): StorageConfig {.raises: [StorageConfigError].} =
  var config = self
  config.addCliOption("--log-level", $level)
  return config

proc withLogLevel*(
    self: StorageConfigs, idx: int, level: LogLevel | string
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-level", $level)
  return startConfig

proc withLogLevel*(
    self: StorageConfigs, level: LogLevel | string
): StorageConfigs {.raises: [StorageConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-level", $level)
  return startConfig

proc withBlockTtl*(
    self: StorageConfig, ttl: int
): StorageConfig {.raises: [StorageConfigError].} =
  var config = self
  config.addCliOption("--block-ttl", $ttl)
  return config

proc withBlockTtl*(
    self: StorageConfigs, idx: int, ttl: int
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--block-ttl", $ttl)
  return startConfig

proc withBlockTtl*(
    self: StorageConfigs, ttl: int
): StorageConfigs {.raises: [StorageConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--block-ttl", $ttl)
  return startConfig

proc withBlockMaintenanceInterval*(
    self: StorageConfig, interval: int
): StorageConfig {.raises: [StorageConfigError].} =
  var config = self
  config.addCliOption("--block-mi", $interval)
  return config

proc withBlockMaintenanceInterval*(
    self: StorageConfigs, idx: int, interval: int
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--block-mi", $interval)
  return startConfig

proc withBlockMaintenanceInterval*(
    self: StorageConfigs, interval: int
): StorageConfigs {.raises: [StorageConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--block-mi", $interval)
  return startConfig

proc withExtIp*(
    self: StorageConfigs, idx: int, ip = "127.0.0.1"
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--nat", "extip:" & ip)
  return startConfig

proc withMixEnabled*(
    self: StorageConfigs
): StorageConfigs {.raises: [StorageConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--mix-enabled")
  return startConfig

proc withListenPort*(
    self: StorageConfigs, idx: int, port: int
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx
  var startConfig = self
  startConfig.configs[idx].addCliOption("--listen-port", $port)
  return startConfig

proc withApiCorsOrigin*(
    self: StorageConfigs, idx: int, origin: string
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx
  var startConfig = self
  startConfig.configs[idx].addCliOption("--api-cors-origin", origin)
  return startConfig

# For testing, a node with extip (not behind nat) with autonat server
# enabled is a bootstrap node
proc isBootstrapNode*(config: StorageConfig): bool {.raises: [].} =
  let opts = config.cliOptions.getOrDefault(StartUpCmd.noCmd)

  try:
    if "--nat" in opts and "extip" in opts["--nat"].value and "--autonat-server" in opts:
      return true
  except KeyError:
    warn "Failed to look at the extip config"
    return false

  return false

proc withAutonatServer*(
    self: StorageConfigs, idx: int
): StorageConfigs {.raises: [StorageConfigError].} =
  self.checkBounds idx
  var startConfig = self
  startConfig.configs[idx].addCliOption("--autonat-server")
  return startConfig
