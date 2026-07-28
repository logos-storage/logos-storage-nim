## This file contains the lifecycle request type that will be handled.
## CREATE_NODE: create a new Logos Storage node with the provided config.json.
## START_NODE: start the provided Logos Storage node.
## STOP_NODE: stop the provided Logos Storage node.

import std/[options, strutils, net, os]
import std/parseutils
import contractabi/address
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import confutils/defs
import libp2p except NATConfig
import json_serialization
import json_serialization/std/[options, net]
import ../../alloc
import ../../../storage/conf
import ../../../storage/utils
import ../../../storage/utils/[keyutils, fileutils]
import ../../../storage/units

from ../../../storage/storage import StorageServer, new, start, stop, close

logScope:
  topics = "libstorage libstoragelifecycle"

type NodeLifecycleMsgType* = enum
  CREATE_NODE
  START_NODE
  STOP_NODE
  CLOSE_NODE

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

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring

proc createShared*(
    T: type NodeLifecycleRequest, op: NodeLifecycleMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared*(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createStorage(
    configJson: cstring
): Future[Result[StorageServer, string]] {.async: (raises: []).} =
  var conf: StorageConf

  try:
    conf = StorageConf.load(
      version = storageFullVersion,
      envVarsPrefix = "storage",
      cmdLine = @[],
      quitOnFailure = false,
      secondarySources = proc(
          config: StorageConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        if configJson.len > 0:
          sources.addConfigFileContent(Json, $(configJson))
      ,
    )
  except ConfigurationError as e:
    # We cannot use e.msg because it is not populated by config-utils
    return err("Failed to create Storage: unable to load configuration.")

  let logFile = conf.setupLogging()

  try:
    {.gcsafe.}:
      updateLogLevel(conf.logLevel)
  except ValueError as err:
    return err("Failed to create Storage: invalid value for log level: " & err.msg)

  if err =? conf.setupMetrics().errorOption:
    return err("Failed to start metrics server: " & err.msg)

  if not (checkAndCreateDataDir((conf.dataDir).string)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    return err(
      "Failed to create Storage: unable to access/create data folder or data folder's permissions are insecure."
    )

  if not (checkAndCreateDataDir((conf.dataDir / "repo"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
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
    except Exception as exc:
      return err("Failed to create Storage: " & exc.msg)

  return ok(server)

proc process*(
    self: ptr NodeLifecycleRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_NODE:
    storage[] = (
      await createStorage(
        self.configJson # , self.appCallbacks
      )
    ).valueOr:
      error "Failed to CREATE_NODE.", error = error
      return err($error)
  of START_NODE:
    if storage[].isNil:
      const msg = "Failed to START_NODE, the node is not created."
      error msg
      return err(msg)
    try:
      await storage[].start()
    except Exception as e:
      error "Failed to START_NODE.", error = e.msg
      return err(e.msg)
  of STOP_NODE:
    if storage[].isNil:
      const msg = "Failed to STOP_NODE, the node is not created."
      error msg
      return err(msg)
    try:
      await storage[].stop()
    except Exception as e:
      error "Failed to STOP_NODE.", error = e.msg
      return err(e.msg)
  of CLOSE_NODE:
    if storage[].isNil:
      const msg = "Failed to CLOSE_NODE, the node is not created."
      error msg
      return err(msg)

    # Set to nil. Even if the close fails, it could fail partially
    # and we don't want to keep a reference to a node that is in an unknown state.
    defer:
      storage[] = nil

    try:
      await storage[].close()
    except Exception as e:
      error "Failed to CLOSE_NODE.", error = e.msg
      return err(e.msg)

  return ok("")
