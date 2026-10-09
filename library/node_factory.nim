## No FFI pragmas here, so the unit tests call `createStorage` directly.

import std/[options, strutils, net, os]
import std/parseutils
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import confutils/defs
import libp2p except NATConfig
import json_serialization
import json_serialization/std/[options, net]
import ../storage/conf
import ../storage/utils
import ../storage/utils/[keyutils, fileutils]
import ../storage/units

from ../storage/storage import StorageServer, new

logScope:
  topics = "libstorage"

proc readValue*[T: InputFile | InputDir | OutPath | OutDir | OutFile](
    r: var JsonReader, val: var T
) =
  val = T(r.readValue(string))

proc readValue*(r: var JsonReader, val: var MultiAddress) =
  val = MultiAddress.init(r.readValue(string)).get()

proc readValue*(r: var JsonReader, val: var NatConfig) =
  let res = NatConfig.parse(r.readValue(string))
  if res.isErr:
    raise
      newException(SerializationError, "Cannot parse the NAT config: " & res.error())
  val = res.get()

proc readValue*(r: var JsonReader, val: var ThreadCount) =
  val = ThreadCount(r.readValue(int))

proc readValue*(r: var JsonReader, val: var NBytes) =
  val = NBytes(r.readValue(int))

proc readValue*(r: var JsonReader, val: var Duration) =
  var dur: Duration
  let input = r.readValue(string)
  let count = parseDuration(input, dur)
  if count == 0:
    raise newException(SerializationError, "Cannot parse the duration: " & input)
  val = dur

proc readValue(r: var JsonReader, val: var NetworkPreset) =
  let name = r.readValue(string)
  let res = NetworkPresets.find(name)
  if res.isNone:
    raise newException(SerializationError, "Invalid network preset: " & name)
  val = res.get()

proc loadConf(configJson: string): Result[StorageConf, string] =
  try:
    let conf = StorageConf.load(
      version = storageFullVersion,
      envVarsPrefix = "storage",
      cmdLine = @[],
      quitOnFailure = false,
      secondarySources = proc(
          config: StorageConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        if configJson.len > 0:
          sources.addConfigFileContent(Json, configJson)
      ,
    )
    return ok(conf)
  except ConfigurationError:
    # We cannot use e.msg because it is not populated by config-utils
    return err("Failed to create Storage: unable to load configuration.")

proc createStorage*(
    configJson: string
): Future[Result[StorageServer, string]] {.async: (raises: []).} =
  var conf = loadConf(configJson).valueOr:
    return err(error)

  let logFile = conf.setupLogging()

  try:
    {.gcsafe.}:
      updateLogLevel(conf.logLevel)
  except ValueError as e:
    return err("Failed to create Storage: invalid value for log level: " & e.msg)

  if err =? conf.setupMetrics().errorOption:
    return err("Failed to start metrics server: " & err.msg)

  if not (checkAndCreateDataDir((conf.dataDir).string)):
    return err(
      "Failed to create Storage: unable to access/create data folder or data folder's permissions are insecure."
    )

  if not (checkAndCreateDataDir((conf.dataDir / "repo"))):
    return err(
      "Failed to create Storage: unable to access/create data folder or data folder's permissions are insecure."
    )

  let keyPath =
    if isAbsolute(conf.netPrivKeyFile):
      conf.netPrivKeyFile
    else:
      conf.dataDir / conf.netPrivKeyFile
  let privateKey = setupKey(keyPath)
  if privateKey.isErr:
    return err("Failed to create Storage: unable to get the private key.")
  let pk = privateKey.get()

  let server =
    try:
      StorageServer.new(conf, pk, logFile)
    except Exception as e:
      return err("Failed to create Storage: " & e.msg)

  return ok(server)
