## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[net, os, parseopt, sequtils, sets, strformat, strutils]

import pkg/chronos
import pkg/chronicles
import
  pkg/libp2p/[builders, cid, multiaddress, peerid, peerinfo, routing_record, switch]
import pkg/libp2p/crypto/crypto
import pkg/libp2p/crypto/secp
import pkg/libp2p/protocols/protocol
import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/libp2p/stream/connection
import pkg/libp2p_mix
import pkg/libp2p_mix/[curve25519, mix_node]
import pkg/libp2p/crypto/curve25519 as libp2p_curve25519
import pkg/results

import pkg/storage/dht_proxy/protocol
import pkg/storage/utils/spr

when defined(posix):
  import std/posix

const MixIdentityFileSize = 2 * FieldElementSize

when not defined(mixVersion):
  {.error: "mixVersion must be set at build time via -d:mixVersion:<value>".}
const mixVersion* {.strdefine.} = ""

logScope:
  topics = "mix relay dht"

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine msg
  quit(1)

proc readBin(path: string): seq[byte] =
  if not fileExists(path):
    fail "File not found: " & path
  try:
    cast[seq[byte]](readFile(path))
  except IOError as exc:
    fail "Failed to read " & path & ": " & exc.msg

proc loadMixKeys(path: string): tuple[pub, priv: FieldElement] =
  let raw = readBin(path)
  if raw.len != MixIdentityFileSize:
    fail(
      "Invalid mix-identity size at " & path & " (expected " & $MixIdentityFileSize &
        ", got " & $raw.len & ")"
    )
  let
    pub = bytesToFieldElement(raw.toOpenArray(0, FieldElementSize - 1)).valueOr:
      fail "Failed to parse mix pub key in " & path & ": " & error
    priv = bytesToFieldElement(
      raw.toOpenArray(FieldElementSize, MixIdentityFileSize - 1)
    ).valueOr:
      fail "Failed to parse mix priv key in " & path & ": " & error
  if libp2p_curve25519.public(priv) != pub:
    fail "Mix identity in " & path & " is inconsistent: pub does not match priv"
  (pub: pub, priv: priv)

proc loadLibp2pKey(path: string): PrivateKey =
  let bytes = readBin(path)
  PrivateKey.init(bytes).valueOr:
    fail "Failed to parse libp2p key in " & path & ": " & $error

proc writeBin(path: string, data: openArray[byte]) =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  try:
    writeFile(path, cast[string](@data))
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except IOError as exc:
    fail "Failed to write " & path & ": " & exc.msg
  except OSError as exc:
    fail "Failed to set permissions on " & path & ": " & exc.msg

proc generateKeys(dataDir: string) =
  let
    mixIdentityPath = dataDir / "mix-identity"
    libp2pKeyPath = dataDir / "key"

  if not dirExists(dataDir):
    try:
      createDir(dataDir)
    except OSError as exc:
      fail "Failed to create --data-dir " & dataDir & ": " & exc.msg

  let rng = newRng()
  if rng.isNil:
    fail "Failed to create RNG"

  let (mixPriv, mixPub) = generateKeyPair().valueOr:
    fail "Failed to generate mix keypair: " & error
  writeBin(mixIdentityPath, fieldElementToBytes(mixPub) & fieldElementToBytes(mixPriv))

  let libp2pPair = SkKeyPair.random(rng)
  let libp2pPriv = PrivateKey(scheme: Secp256k1, skkey: libp2pPair.seckey)
  let libp2pBytes = libp2pPriv.getBytes().valueOr:
    fail "Failed to serialize libp2p key: " & $error
  writeBin(libp2pKeyPath, libp2pBytes)

  notice "Generated fresh identity",
    dataDir = dataDir, mixIdentity = mixIdentityPath, libp2pKey = libp2pKeyPath

type DhtProxyProtocol = ref object of LPProtocol
  kad: KadDHT
  inFlight: int
  maxInFlight: int

proc handleFindProviders(
    self: DhtProxyProtocol, queryBytes: seq[byte]
): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
  let c = Cid.init(queryBytes).valueOr:
    warn "Invalid CID in lookup request"
    return LookupResponse(code: LookupCode.ErrInvalidCid)

  let providers =
    try:
      await self.kad.getProviders(c.toKey())
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "kad getProviders raised", err = exc.msg
      return LookupResponse(code: LookupCode.ErrInternal)

  if providers.len == 0:
    return LookupResponse(code: LookupCode.NotFound)

  var encoded = newSeqOfCap[seq[byte]](providers.len)
  for provider in providers:
    if provider.id.isNone:
      continue

    let peerId = PeerId.init(provider.id.get()).valueOr:
      continue
    encoded.add(PeerRecord.init(peerId, provider.addrs).encode())

  if encoded.len == 0:
    return LookupResponse(code: LookupCode.ErrInternal)

  let packed = packProviders(encoded, MaxLookupResponseBytes).valueOr:
    return LookupResponse(code: error)

  LookupResponse(code: LookupCode.Ok, providers: packed)

proc handleLookupRequest(
    self: DhtProxyProtocol, conn: Connection
) {.async: (raises: [CancelledError]).} =
  try:
    if self.inFlight >= self.maxInFlight:
      debug "DHT proxy at capacity, replying ErrTooBusy",
        inFlight = self.inFlight, max = self.maxInFlight
      await conn.writeLp(LookupResponse(code: LookupCode.ErrTooBusy).encode())
      return

    inc self.inFlight
    defer:
      dec self.inFlight

    let
      reqBytes = await conn.readLp(MaxLookupRequestBytes)
      req = LookupRequest.decode(reqBytes).valueOr:
        warn "Failed to decode lookup request"
        await conn.writeLp(LookupResponse(code: LookupCode.ErrDecodeFailed).encode())
        return

    let resp =
      case req.queryType
      of FindProviders:
        await self.handleFindProviders(req.queryBytes)

    await conn.writeLp(resp.encode())
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Stream error", err = exc.msg
  except CatchableError as exc:
    warn "Handler error", err = exc.msg

proc new(
    T: type DhtProxyProtocol, kad: KadDHT, maxInFlight: int = DefaultMaxInFlightLookups
): DhtProxyProtocol =
  let self = DhtProxyProtocol(kad: kad, maxInFlight: maxInFlight)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    try:
      await self.handleLookupRequest(conn)
    finally:
      await noCancel conn.close()

  self.handler = handler
  self.codec = DhtProxyCodec
  self

type Conf = object
  dataDir: string
  listenIp: string
  listenPort: int
  bootstrapNodes: seq[SignedPeerRecord]
  logLevel: string
  logFile: string
  generate: bool
  noDhtProxy: bool
  maxInFlight: int
  maxConnections: int

proc usage(): string =
  """
mix_relay_dht — standalone Mix relay + DHT proxy daemon.

Usage:
  mix_relay_dht --data-dir=<dir> --listen-ip=<addr> --listen-port=<port>
                [--bootstrap-node=<spr> ...] [--log-level=<lvl>] [--generate]

Options:
  --data-dir=<dir>           Directory holding identity files (key + mix-identity).
  --listen-ip=<addr>         Public IPv4 to bind/announce for libp2p TCP.
  --listen-port=<n>          libp2p TCP port (Mix relay + DHT proxy + Kad share this).
  --bootstrap-node=<spr>     Repeatable. Signed peer record (spr:...) of a Kad bootstrap peer.
  --log-level=<lvl>          TRACE | DEBUG | INFO | NOTICE | WARN | ERROR | FATAL | NONE
                             (default: INFO)
  --log-file=<path>          Write logs to <path> instead of stdout.
  --generate                 Generate fresh identity files if data-dir is empty.
  --no-dht-proxy             Run as a pure Mix relay.
                             Conflicts with --bootstrap-node.
  --max-inflight=<n>         Max concurrent DHT proxy lookups (default: 100).
  --max-connections=<n>      Max libp2p connections (in + out) (default: 160).
  -h, --help                 Show this help.
  -v, --version              Show version and revision.
"""

proc parseBootstrapNode(raw: string): SignedPeerRecord =
  SignedPeerRecord.parse(raw).valueOr:
    fail "Invalid --bootstrap-node record: " & raw & " (" & error.msg & ")"

proc parseConf(): Conf =
  result = Conf(
    dataDir: "",
    listenIp: "",
    listenPort: 0,
    bootstrapNodes: @[],
    logLevel: "INFO",
    logFile: "",
    generate: false,
    noDhtProxy: false,
    maxInFlight: DefaultMaxInFlightLookups,
    maxConnections: 160,
  )
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "help", "h":
        stdout.writeLine usage()
        quit(0)
      of "version", "v":
        stdout.writeLine mixVersion
        quit(0)
      of "data-dir":
        result.dataDir = expandTilde(p.val)
      of "listen-ip":
        result.listenIp = p.val
      of "listen-port":
        try:
          result.listenPort = parseInt(p.val)
        except ValueError:
          fail "--listen-port must be an integer, got: " & p.val
      of "bootstrap-node":
        result.bootstrapNodes.add(parseBootstrapNode(p.val))
      of "log-level":
        try:
          discard parseEnum[LogLevel](p.val)
        except ValueError:
          fail "Invalid --log-level: " & p.val &
            " (use TRACE|DEBUG|INFO|NOTICE|WARN|ERROR|FATAL|NONE)"
        result.logLevel = p.val
      of "log-file":
        result.logFile = expandTilde(p.val)
      of "generate":
        result.generate = true
      of "no-dht-proxy":
        result.noDhtProxy = true
      of "max-inflight":
        try:
          result.maxInFlight = parseInt(p.val)
        except ValueError:
          fail "--max-inflight must be an integer, got: " & p.val
        if result.maxInFlight < 1:
          fail "--max-inflight must be >= 1, got: " & $result.maxInFlight
      of "max-connections":
        try:
          result.maxConnections = parseInt(p.val)
        except ValueError:
          fail "--max-connections must be an integer, got: " & p.val
        if result.maxConnections < 1:
          fail "--max-connections must be >= 1, got: " & $result.maxConnections
      else:
        fail "Unknown flag: --" & p.key
    of cmdArgument:
      stderr.writeLine usage()
      quit(1)

  if result.dataDir.len == 0:
    fail "--data-dir=<dir> is required"
  if result.listenIp.len == 0:
    fail "--listen-ip=<addr> is required"
  if result.listenPort == 0:
    fail "--listen-port=<port> is required"
  if result.listenPort < 1 or result.listenPort > 65535:
    fail "--listen-port out of range: " & $result.listenPort & " (must be 1..65535)"

  if result.noDhtProxy and result.bootstrapNodes.len > 0:
    fail "--no-dht-proxy conflicts with --bootstrap-node"

var shutdownRequested = false

proc requestShutdown() =
  shutdownRequested = true

proc controlCHandler() {.noconv.} =
  requestShutdown()

when defined(posix):
  proc sigtermHandler(signal: cint) {.noconv.} =
    requestShutdown()

proc runRelayOnly(
    conf: Conf,
    switch: Switch,
    mixProto: MixProtocol,
    peerId: PeerId,
    tcpAddr: MultiAddress,
) {.async: (raises: [CatchableError]).} =
  try:
    await mixProto.start()
  except CatchableError as exc:
    raise newException(CatchableError, "MixProtocol start failed: " & exc.msg)
  switch.mount(mixProto)

  try:
    await switch.start()
  except CatchableError as exc:
    raise newException(CatchableError, "libp2p switch start failed: " & exc.msg)

  notice "Mix relay started (no DHT proxy)",
    peerId = peerId, tcp = $tcpAddr, dataDir = conf.dataDir

  try:
    while not shutdownRequested:
      await sleepAsync(200.milliseconds)
  finally:
    notice "Stopping"
    await switch.stop()
    notice "Stopped"

proc runWithDhtProxy(
    conf: Conf,
    switch: Switch,
    mixProto: MixProtocol,
    peerId: PeerId,
    tcpAddr: MultiAddress,
) {.async: (raises: [CatchableError]).} =
  let
    kadBootstrap = conf.bootstrapNodes.mapIt(it.toPeerIdAndAddrs())
    kad = KadDHT.new(switch, bootstrapNodes = kadBootstrap, rng = newRng())
  let proxyProto = DhtProxyProtocol.new(kad, maxInFlight = conf.maxInFlight)

  try:
    await mixProto.start()
  except CatchableError as exc:
    raise newException(CatchableError, "MixProtocol start failed: " & exc.msg)
  switch.mount(mixProto)

  try:
    await proxyProto.start()
  except CatchableError as exc:
    raise newException(CatchableError, "DhtProxyProtocol start failed: " & exc.msg)
  switch.mount(proxyProto)

  switch.mount(kad)

  try:
    await switch.start()
  except CatchableError as exc:
    raise newException(CatchableError, "libp2p switch start failed: " & exc.msg)

  try:
    await kad.start()
  except CatchableError as exc:
    raise newException(CatchableError, "Kad DHT start failed: " & exc.msg)

  let spr = switch.peerInfo.toSpr()
  if spr.isErr:
    raise newException(
      ValueError, "Failed to build node signed peer record: " & spr.error.msg
    )

  let
    nodeSprStr = spr.get()
    mixNodeSprPath = conf.dataDir / "mix_node.spr"
    dhtSprPath = conf.dataDir / "dht.spr"

  try:
    writeFile(mixNodeSprPath, nodeSprStr)
  except IOError as exc:
    raise newException(
      CatchableError,
      "Failed to write mix node SPR file " & mixNodeSprPath & ": " & exc.msg,
    )

  try:
    writeFile(dhtSprPath, nodeSprStr)
  except IOError as exc:
    raise newException(
      CatchableError, "Failed to write DHT SPR file " & dhtSprPath & ": " & exc.msg
    )

  notice "Mix relay and DHT proxy started",
    peerId = peerId, tcp = $tcpAddr, dataDir = conf.dataDir
  notice "DHT bootstrap SPR", spr = nodeSprStr, file = dhtSprPath
  notice "Mix node SPR", spr = nodeSprStr, file = mixNodeSprPath

  try:
    while not shutdownRequested:
      await sleepAsync(200.milliseconds)
  finally:
    notice "Stopping"
    try:
      await noCancel kad.stop()
    except CatchableError as exc:
      warn "Kad DHT close error", err = exc.msg
    await switch.stop()
    notice "Stopped"

proc run(conf: Conf) {.async: (raises: [CatchableError]).} =
  let
    mixIdentityPath = conf.dataDir / "mix-identity"
    libp2pKeyPath = conf.dataDir / "key"
    mixIdentityExists = fileExists(mixIdentityPath)
    libp2pKeyExists = fileExists(libp2pKeyPath)

  if not mixIdentityExists and not libp2pKeyExists:
    if not conf.generate:
      fail(
        "No identity files in --data-dir " & conf.dataDir &
          ". Either provide them or pass --generate to create fresh keys."
      )
    generateKeys(conf.dataDir)
  elif mixIdentityExists xor libp2pKeyExists:
    fail(
      "Partial identity in --data-dir " & conf.dataDir &
        " (one of mix-identity / key is missing). Aborting."
    )
  elif conf.generate:
    warn "Ignoring --generate: identity files already exist in --data-dir",
      dataDir = conf.dataDir

  let
    (mixPub, mixPriv) = loadMixKeys(mixIdentityPath)
    libp2pPriv = loadLibp2pKey(libp2pKeyPath)

  if libp2pPriv.scheme != Secp256k1:
    raise newException(
      ValueError, "Mix requires a Secp256k1 libp2p key; got " & $libp2pPriv.scheme
    )

  let libp2pPub = libp2pPriv.getPublicKey().valueOr:
    raise newException(ValueError, "Failed to derive libp2p public key: " & $error)

  let peerId = PeerId.init(libp2pPub).valueOr:
    raise newException(ValueError, "Failed to derive peerId: " & $error)

  let listenIp =
    try:
      parseIpAddress(conf.listenIp)
    except ValueError as exc:
      raise newException(ValueError, "Invalid --listen-ip: " & exc.msg)

  let tcpAddr = MultiAddress.init(fmt"/ip4/{$listenIp}/tcp/{conf.listenPort}").valueOr:
    raise newException(ValueError, "Invalid libp2p multiaddr: " & $error)

  let nodeInfo = initMixNodeInfo(
    peerId = peerId,
    multiAddr = tcpAddr,
    mixPubKey = mixPub,
    mixPrivKey = mixPriv,
    libp2pPubKey = libp2pPub.skkey,
    libp2pPrivKey = libp2pPriv.skkey,
  )

  let switch = SwitchBuilder
    .new()
    .withPrivateKey(libp2pPriv)
    .withAddresses(@[tcpAddr])
    .withRng(newRng())
    .withNoise()
    .withYamux()
    .withMaxConnections(conf.maxConnections)
    .withTcpTransport({ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay})
    .build()

  let mixProto = MixProtocol.new(nodeInfo, switch)

  let maxReplyBytes = getMaxMessageSizeForCodec(DhtProxyCodec, 0).valueOr:
    raise
      newException(ValueError, "DhtProxyCodec does not fit Sphinx payload: " & error)
  mixProto.registerDestReadBehavior(DhtProxyCodec, readLp(maxReplyBytes))

  if conf.noDhtProxy:
    await runRelayOnly(conf, switch, mixProto, peerId, tcpAddr)
  else:
    await runWithDhtProxy(conf, switch, mixProto, peerId, tcpAddr)

var logFileHandle: File

proc setupLogging(conf: Conf) =
  proc writeAndFlush(f: File, msg: LogOutputStr) =
    try:
      f.write(msg)
      f.flushFile()
    except IOError as err:
      logLoggingFailure(cstring(msg), err)

  proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
    discard

  proc stdoutWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(stdout, msg)

  defaultChroniclesStream.outputs[1].writer = noOutput

  if conf.logFile.len == 0:
    defaultChroniclesStream.outputs[0].writer = stdoutWriter
    defaultChroniclesStream.outputs[2].writer = noOutput
    return

  try:
    logFileHandle = open(conf.logFile, fmWrite)
  except IOError as exc:
    fail "Failed to open --log-file " & conf.logFile & ": " & exc.msg

  proc fileWriter(logLevel: LogLevel, msg: LogOutputStr) =
    writeAndFlush(logFileHandle, msg)

  defaultChroniclesStream.outputs[0].writer = noOutput
  defaultChroniclesStream.outputs[2].writer = fileWriter

proc main() =
  let conf = parseConf()

  when defined(chronicles_runtime_filtering):
    setLogLevel(parseEnum[LogLevel](conf.logLevel))

  setupLogging(conf)

  try:
    setControlCHook(controlCHandler)
  except Exception as exc:
    warn "Cannot set ctrl-c handler", msg = exc.msg

  when defined(posix):
    discard posix.signal(SIGTERM, sigtermHandler)

  try:
    waitFor run(conf)
  except CatchableError as exc:
    fatal "Mix relay + DHT proxy aborted", err = exc.msg
    quit(1)

when isMainModule:
  main()
