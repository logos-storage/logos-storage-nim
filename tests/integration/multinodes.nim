import std/httpclient
import std/os
import std/strutils
import std/sugar
import std/times
import pkg/storage/conf
import pkg/storage/logutils
import pkg/chronos/transports/stream
import pkg/questionable
import ./storageconfig
import ./storageprocess
import ./nodeconfigs
import ./utils
import ../asynctest
import ../checktest

export asynctest
export storageprocess
export storageconfig
export nodeconfigs

{.push raises: [].}

type
  RunningNode* = ref object
    role*: Role
    node*: NodeProcess

  Role* {.pure.} = enum
    Client

  MultiNodeSuiteError = object of CatchableError
  SuiteTimeoutError = object of MultiNodeSuiteError

const StorageApiPort {.intdefine.}: int = 8080
const TestId {.strdefine.}: string = "TestId"
const StorageLogToFile {.booldefine.}: bool = false
const StorageLogLevel {.strdefine.}: string = ""
const StorageLogsDir {.strdefine.}: string = ""

proc raiseMultiNodeSuiteError(
    msg: string, parent: ref CatchableError = nil
) {.raises: [MultiNodeSuiteError].} =
  raise newException(MultiNodeSuiteError, msg, parent)

template withLock(lock: AsyncLock, body: untyped) =
  if lock.isNil:
    lock = newAsyncLock()

  await lock.acquire()
  try:
    body
  finally:
    try:
      lock.release()
    except AsyncLockError as parent:
      raiseMultiNodeSuiteError "lock error", parent

proc sanitize(pathSegment: string): string =
  var sanitized = pathSegment
  for invalid in invalidFilenameChars.items:
    sanitized = sanitized.replace(invalid, '_').replace(' ', '_')
  sanitized

proc getTempDirName*(starttime: string, role: Role, roleIdx: int): string =
  getTempDir() / "Storage" / sanitize($starttime) / sanitize($role & "_" & $roleIdx)

template multinodesuite*(suiteName: string, body: untyped) =
  asyncchecksuite suiteName:
    var running {.inject, used.}: seq[RunningNode]
    var bootstrapNodes: seq[string]
    let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
    var currentTestName = ""
    var nodeConfigs: NodeConfigs
    var snapshot: JsonNode
    var lastUsedStorageApiPort = StorageApiPort
    var storagePortLock: AsyncLock

    template test(tname, startNodeConfigs, tbody) =
      currentTestName = tname
      nodeConfigs = startNodeConfigs
      test tname:
        tbody

    proc updatePort(url: var string, port: int) =
      let parts = url.split(':')
      url = @[parts[0], parts[1], $port].join(":")

    proc newStorageProcess(
        roleIdx: int, conf: StorageConfig, role: Role
    ): Future[NodeProcess] {.async: (raises: [MultiNodeSuiteError, CancelledError]).} =
      let nodeIdx = running.len
      var config = conf
      let datadir = getDataDir(TestId, currentTestName, $starttime, $role, some roleIdx)

      try:
        if config.logFile.isSome or StorageLogToFile:
          try:
            let updatedLogFile = getLogFile(
              StorageLogsDir, starttime, suiteName, currentTestName, $role, some roleIdx
            )
            config.withLogFile(updatedLogFile)
          except IOError as e:
            raiseMultiNodeSuiteError(
              "failed to start " & $role &
                " because logfile path could not be obtained: " & e.msg,
              e,
            )
          except OSError as e:
            raiseMultiNodeSuiteError(
              "failed to start " & $role &
                " because logfile path could not be obtained: " & e.msg,
              e,
            )

        when StorageLogLevel != "":
          config.addCliOption("--log-level", StorageLogLevel)

        var apiPort: int
        withLock(storagePortLock):
          apiPort = await nextFreePort(lastUsedStorageApiPort + nodeIdx)
          config.addCliOption("--api-bindaddr", DefaultApiBindAddress)
          config.addCliOption("--api-port", $apiPort)
          lastUsedStorageApiPort = apiPort

        if bootstrapNodes.len == 0:
          # Without this flag the node would bootstrap on the default
          # network preset.
          config.addCliOption("--no-bootstrap-node")
        else:
          for bootstrapNode in bootstrapNodes:
            config.addCliOption("--bootstrap-node", bootstrapNode)

        config.addCliOption("--data-dir", datadir)
      except StorageConfigError as e:
        raiseMultiNodeSuiteError "invalid cli option, error: " & e.msg

      try:
        let node = await StorageProcess.startNode(
          config.cliArgs, config.debugEnabled, $role & $roleIdx
        )
        await node.waitUntilStarted()
        trace "node started", nodeName = $role & $roleIdx
        return node
      except StorageConfigError as e:
        raiseMultiNodeSuiteError "failed to get cli args from config: " & e.msg, e
      except NodeProcessError as e:
        raiseMultiNodeSuiteError "node not started, error: " & e.msg, e

    proc clients(): seq[StorageProcess] {.used.} =
      return collect:
        for r in running:
          if r.role == Role.Client:
            StorageProcess(r.node)

    proc startClientNode(conf: StorageConfig): Future[NodeProcess] {.async.} =
      let clientIdx = clients().len
      return await newStorageProcess(clientIdx, conf, Role.Client)

    proc teardownImpl() {.async.} =
      for nodes in @[clients()]:
        for node in nodes:
          await node.stop() # also stops rest client
          try:
            node.removeDataDir()
          except StorageProcessError as e:
            error "Failed to remove data dir during teardown", error = e.msg

      running = @[]
      bootstrapNodes = @[]

    template failAndTeardownOnError(message: string, tryBody: untyped) =
      try:
        tryBody
      except CancelledError as e:
        await teardownImpl()
        when declared(teardownAllIMPL):
          teardownAllIMPL()
        fail()
        quit(1)
      except CatchableError as er:
        fatal message, error = er.msg
        echo "[FATAL] ", message, ": ", er.msg
        await teardownImpl()
        when declared(teardownAllIMPL):
          teardownAllIMPL()
        fail()
        quit(1)

    proc updateBootstrapNodes(
        node: StorageProcess
    ): Future[void] {.async: (raises: [MultiNodeSuiteError]).} =
      try:
        without ninfo =? await node.client.info():
          # raise CatchableError instead of Defect (with .get or !) so we
          # can gracefully shutdown and prevent zombies
          raiseMultiNodeSuiteError "Failed to get node info"
        bootstrapNodes.add ninfo["spr"].getStr()
      except CatchableError as e:
        raiseMultiNodeSuiteError "Failed to get node info: " & e.msg, e

    setupAll:
      # When this file is run with `-d:chronicles_sinks=textlines[file]`, we
      # need to set the log file path at runtime, otherwise chronicles didn't seem to
      # create a log file even when using an absolute path
      when defaultChroniclesStream.outputs is (FileOutput,) and StorageLogsDir.len > 0:
        let logFile =
          StorageLogsDir / sanitize(
            getAppFilename().extractFilename & ".chronicles.log"
          )
        let success = defaultChroniclesStream.outputs[0].open(logFile, fmAppend)
        doAssert success, "Failed to open log file: " & logFile

    setup:
      trace "Setting up test", suite = suiteName, test = currentTestName, nodeConfigs
      if var clients =? nodeConfigs.clients:
        failAndTeardownOnError "failed to start client nodes":
          # Only the first node (bootstrap) gets a known extip. Other nodes use
          # nat=auto so AutoNAT can run and determine their reachability.
          clients = clients.withExtIp(0).withAutonatServer(0)
          for config in clients.configs:
            let node = await startClientNode(config)
            running.add RunningNode(role: Role.Client, node: node)
            if config.isBootstrapNode:
              await StorageProcess(node).updateBootstrapNodes()

    teardown:
      await teardownImpl()
      trace "Test completed", suite = suiteName, test = currentTestName

    body
