## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[json, os, tables]

import pkg/chronicles
import pkg/libp2p
import pkg/libp2p/wire
import pkg/libp2p/crypto/crypto
import pkg/libp2p/crypto/secp
import pkg/libp2p_mix
import pkg/libp2p_mix/[curve25519, mix_node]
import pkg/libp2p_mix_transport/address/parse
import pkg/libp2p/crypto/curve25519 as libp2p_curve25519
import pkg/questionable/results
import pkg/stew/byteutils

import ../errors
import ./addrutils

logScope:
  topics = "storage mixidentity"

const PoolFormatVersion = 1

const MixIdentityFileSize = 2 * FieldElementSize

type MixPool* = Table[PeerId, MixPubInfo]

proc mixUnsetMultiAddr*(): MultiAddress =
  ## Placeholder multiaddr for a mix node that has not yet been assigned a real multiaddr.
  ## Use a proc here to avoid GC-safe compilation issues.
  MultiAddress.init("/ip4/0.0.0.0/tcp/0").expect("valid")

proc pickMixCompatibleMultiAddr*(addrs: openArray[MultiAddress]): Opt[MultiAddress] =
  ## Mix only supports /ip4/*/tcp/* or /ip4/*/udp/*/quic-v1 multiaddrs,
  ## either direct or in a circuit relay.
  for ma in addrs:
    if TCP_IP4.match(ma) or QUIC_V1_IP4.match(ma):
      return Opt.some(ma)

    if ma.isCircuitRelayMA() and
    # Check for the prefix of the relay address, which must be /ip4/*/tcp/* or /ip4/*/udp/*/quic-v1
    (TCP_IP4.matchPartial(ma) or QUIC_V1_IP4.matchPartial(ma)):
      return Opt.some(ma)

  Opt.none(MultiAddress)

proc addressMapper*(proto: MixProtocol): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    result = listenAddrs
    # The address in nodeInfo should always be up-to-date, so we
    # just take that one.
    let mixAddress = proto.localMixPubInfo.toMixAddress().valueOr:
      error "Failed to get Mix address", err = error
      return

    trace "derived new mix transport address", address = mixAddress
    result.add(mixAddress)

proc dialableMixAddressPolicy*(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  ## Replacement policy for `dialableAddressPolicy` which allows an address if either:
  ##  1. the address itself is dialable;
  ##  2. the address is a valid mix transport address, and its underlying multiaddr is
  ##     dialable.
  if dialableAddressPolicy(ma):
    return true

  let pubMixInfo = MixPubInfo.fromMixAddress(ma, Opt.none(PeerId)).valueOr:
    # not a valid mix address
    return false

  return dialableAddressPolicy(pubMixInfo.multiAddr)

proc loadOrGenerateMixKeys*(
    path: string
): ?!tuple[mixPub: FieldElement, mixPriv: FieldElement] =
  if fileExists(path):
    let raw =
      try:
        readFile(path)
      except IOError as exc:
        return failure("Failed to read mix-identity from " & path & ": " & exc.msg)

    if raw.len != MixIdentityFileSize:
      return failure(
        "Invalid mix-identity file size at " & path & " (expected " &
          $MixIdentityFileSize & ", got " & $raw.len & ")"
      )

    let
      pub = bytesToFieldElement(raw.toOpenArrayByte(0, FieldElementSize - 1)).valueOr:
        return failure("Bad mix pub key in " & path & ": " & error)
      priv = bytesToFieldElement(
        raw.toOpenArrayByte(FieldElementSize, 2 * FieldElementSize - 1)
      ).valueOr:
        return failure("Bad mix priv key in " & path & ": " & error)
    if libp2p_curve25519.public(priv) != pub:
      return
        failure("Mix identity in " & path & " is inconsistent: pub does not match priv")
    return success((mixPub: pub, mixPriv: priv))

  let (priv, pub) = generateKeyPair().valueOr:
    return failure("Failed to generate Mix keypair: " & error)

  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    try:
      createDir(dir)
    except OSError as exc:
      return failure("Failed to create directory " & dir & ": " & exc.msg)
    except IOError as exc:
      return failure("Failed to create directory " & dir & ": " & exc.msg)

  let blob = fieldElementToBytes(pub) & fieldElementToBytes(priv)

  try:
    writeFile(path, string.fromBytes(blob))
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except IOError as exc:
    return failure("Failed to write mix-identity to " & path & ": " & exc.msg)
  except OSError as exc:
    return failure("Failed to set permissions on " & path & ": " & exc.msg)

  success((mixPub: pub, mixPriv: priv))

proc buildMixNodeInfo*(
    mixPub, mixPriv: FieldElement,
    peerId: PeerId,
    multiAddr: MultiAddress,
    libp2pPriv: PrivateKey,
): ?!MixNodeInfo =
  if libp2pPriv.scheme != Secp256k1:
    return failure("Mix requires a Secp256k1 libp2p key; got " & $libp2pPriv.scheme)

  let libp2pPub = libp2pPriv.getPublicKey().valueOr:
    return failure("Failed to derive libp2p pub key: " & $error)

  if libp2pPub.scheme != Secp256k1:
    return failure("Unexpected libp2p pub key scheme: " & $libp2pPub.scheme)

  success initMixNodeInfo(
    peerId = peerId,
    multiAddr = multiAddr,
    mixPubKey = mixPub,
    mixPrivKey = mixPriv,
    libp2pPubKey = libp2pPub.skkey,
    libp2pPrivKey = libp2pPriv.skkey,
  )

proc pubInfoFromJson(node: JsonNode): ?!MixPubInfo =
  if node.kind != JObject:
    return failure("pool entry is not a JSON object")

  let
    peerIdNode = node.getOrDefault("peerId")
    multiAddrNode = node.getOrDefault("multiAddr")
    mixPubKeyNode = node.getOrDefault("mixPubKey")
    libp2pPubKeyNode = node.getOrDefault("libp2pPubKey")

  if peerIdNode.isNil:
    return failure("pool entry missing field 'peerId'")
  if multiAddrNode.isNil:
    return failure("pool entry missing field 'multiAddr'")
  if mixPubKeyNode.isNil:
    return failure("pool entry missing field 'mixPubKey'")
  if libp2pPubKeyNode.isNil:
    return failure("pool entry missing field 'libp2pPubKey'")

  let
    peerIdStr = peerIdNode.getStr()
    multiAddrStr = multiAddrNode.getStr()
    mixPubKeyHex = mixPubKeyNode.getStr()
    libp2pPubKeyHex = libp2pPubKeyNode.getStr()

  let peerId = PeerId.init(peerIdStr).valueOr:
    return failure("Invalid peerId in pool entry: " & peerIdStr & " (" & $error & ")")

  let multiAddr = MultiAddress.init(multiAddrStr).valueOr:
    return
      failure("Invalid multiAddr in pool entry: " & multiAddrStr & " (" & $error & ")")

  let mixPubKeyBytes =
    try:
      hexToSeqByte(mixPubKeyHex)
    except ValueError as exc:
      return failure("Invalid mixPubKey hex in pool entry: " & exc.msg)
  let mixPubKey = bytesToFieldElement(mixPubKeyBytes).valueOr:
    return failure("Invalid mixPubKey in pool entry: " & error)

  let libp2pPubKeyBytes =
    try:
      hexToSeqByte(libp2pPubKeyHex)
    except ValueError as exc:
      return failure("Invalid libp2pPubKey hex in pool entry: " & exc.msg)
  let libp2pPubKey = SkPublicKey.init(libp2pPubKeyBytes).valueOr:
    return failure("Invalid libp2pPubKey in pool entry: " & $error)

  success MixPubInfo.init(peerId, multiAddr, mixPubKey, libp2pPubKey)

proc loadRelayPubInfoTableFromJson*(poolJson: string): ?!MixPool =
  ## Expected format:
  ##   { "version": 1, "relays": [ { peerId, multiAddr, mixPubKey, libp2pPubKey }, ... ] }
  if poolJson.len == 0:
    return success initTable[PeerId, MixPubInfo]()

  let parsed =
    try:
      parseJson(poolJson)
    except CatchableError as exc:
      return failure("Failed to parse pool JSON: " & exc.msg)

  let versionNode = parsed.getOrDefault("version")
  if versionNode.isNil or versionNode.getInt() != PoolFormatVersion:
    return failure("Unsupported pool version (expected " & $PoolFormatVersion & ")")

  let relaysNode = parsed.getOrDefault("relays")
  if relaysNode.isNil or relaysNode.kind != JArray:
    return failure("Pool JSON missing 'relays' array")

  var t = initTable[PeerId, MixPubInfo]()
  for entry in relaysNode:
    let info = ?pubInfoFromJson(entry)
    t[info.peerId] = info

  success t

proc loadRelayPubInfoTableFromFile*(poolPath: string): ?!MixPool =
  if poolPath.len == 0:
    return success initTable[PeerId, MixPubInfo]()

  if not fileExists(poolPath):
    return failure("Mix pool file does not exist: " & poolPath)

  let poolJson =
    try:
      readFile(poolPath)
    except IOError as exc:
      return failure("Failed to read pool " & poolPath & ": " & exc.msg)

  loadRelayPubInfoTableFromJson(poolJson)

{.pop.}
