## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/questionable
import pkg/confutils
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/confutils/toml/defs as confTomlDefs
import pkg/confutils/toml/std/net as confTomlNet
import pkg/confutils/toml/std/uri as confTomlUri
import pkg/toml_serialization
import pkg/libp2p

import ./storage/conf
import ./storage/storage
import ./storage/logutils
import ./storage/units
import ./storage/utils/keyutils
import ./storage/storagetypes

export storage, conf, libp2p, chronos, logutils

when isMainModule:
  import std/os
  import pkg/confutils/defs
  import ./storage/utils/fileutils

  logScope:
    topics = "storage"

  when defined(posix):
    import system/ansi_c

  const StandaloneDefaultConfig = "api-bindaddr = \"" & DefaultApiBindAddress & "\""

  type StorageStatus {.pure.} = enum
    Stopped
    Stopping
    Running

  let config = StorageConf.load(
    version = storageFullVersion,
    envVarsPrefix = "storage",
    secondarySources = proc(
        config: StorageConf, sources: auto
    ) {.gcsafe, raises: [ConfigurationError].} =
      if configFile =? config.configFile:
        sources.addConfigFile(Toml, configFile)
      # Sources are read in order: the config file wins over these defaults
      sources.addConfigFileContent(Toml, StandaloneDefaultConfig),
  )

  let logFile = config.setupLogging()

  try:
    updateLogLevel(config.logLevel)
  except ValueError as err:
    try:
      stderr.write "Invalid value for --log-level. " & err.msg & "\n"
    except IOError:
      echo "Invalid value for --log-level. " & err.msg
    quit QuitFailure

  if err =? config.setupMetrics().errorOption:
    fatal "Failed to start metrics server", err = err.msg
    quit QuitFailure

  if not (checkAndCreateDataDir((config.dataDir).string)):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  trace "Data dir initialized", dir = $config.dataDir

  if not (checkAndCreateDataDir((config.dataDir / "repo"))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  trace "Repo dir initialized", dir = config.dataDir / "repo"

  var
    state: StorageStatus
    shutdown: Future[void]

  let
    keyPath =
      if isAbsolute(config.netPrivKeyFile):
        config.netPrivKeyFile
      else:
        config.dataDir / config.netPrivKeyFile

    privateKey = setupKey(keyPath).valueOr:
      fatal "Failed to set up the network private key", path = keyPath, err = error.msg
      quit QuitFailure

    server =
      try:
        StorageServer.new(config, privateKey, logFile)
      except Exception as exc:
        error "Failed to start Logos Storage", msg = exc.msg
        quit QuitFailure

  ## Ctrl+C handling
  proc doShutdown() =
    if state == StorageStatus.Stopping:
      return

    shutdown = server.shutdown()
    state = StorageStatus.Stopping

    notice "Stopping Logos Storage"

  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as exc:
        raiseAssert exc.msg
        # shouldn't happen
    notice "Shutting down after having received SIGINT"

    doShutdown()

  try:
    setControlCHook(controlCHandler)
  except Exception as exc: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = exc.msg

  # equivalent SIGTERM handler
  when defined(posix):
    proc SIGTERMHandler(signal: cint) {.noconv.} =
      notice "Shutting down after having received SIGTERM"

      doShutdown()

    c_signal(ansi_c.SIGTERM, SIGTERMHandler)

  try:
    waitFor server.start()
  except CatchableError as error:
    error "Logos Storage failed to start", error = error.msg
    # XXX ideally we'd like to issue a stop instead of quitting cold turkey,
    #   but this would mean we'd have to fix the implementation of all
    #   services so they won't crash if we attempt to stop them before they
    #   had a chance to start (currently you'll get a SISGSEV if you try to).
    quit QuitFailure

  state = StorageStatus.Running
  while state == StorageStatus.Running:
    try:
      # poll chronos
      chronos.poll()
    except Exception as exc:
      error "Unhandled exception in async proc, aborting", msg = exc.msg
      quit QuitFailure

  try:
    # signal handlers guarantee that the shutdown Future will
    # be assigned before state switches to Stopping
    waitFor shutdown
  except CatchableError as error:
    error "Logos Storage didn't shutdown correctly", error = error.msg
    quit QuitFailure

  notice "Exited Storage"
