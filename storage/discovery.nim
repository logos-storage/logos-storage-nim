## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/random
import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/wire
import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/libp2p_mix
import pkg/questionable
import pkg/questionable/results

import ./rng as storage_rng
import ./utils/mixidentity
import ./errors
import ./logutils
import ./utils/spr
import ./dht_proxy/client as dht_proxy_client

export routing_record

# TODO: If generics in methods had not been
# deprecated, this could have been implemented
# much more elegantly.

logScope:
  topics = "storage discovery"

const
  ProvideTimeout = 1.minutes
  LookupTimeout = 1.minutes

type
  Discovery* = ref object of RootObj
    kad*: KadDHT # libp2p Kademlia DHT
    switch: Switch # local libp2p switch
    peerId: PeerId # the peer id of the local node
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])]
      # kept to re-seed the routing table when it goes empty
    mixProto*: MixProtocol
    dhtMixProxies*: seq[SignedPeerRecord]
    privateQueries: bool

  RoutingPeer* = object
    record*: PeerRecord
    lastSeen*: Moment

proc toRecords(providers: HashSet[Provider]): seq[PeerRecord] =
  var records = newSeqOfCap[PeerRecord](providers.len)
  for provider in providers:
    if provider.id.isNone:
      continue

    let peerId = PeerId.init(provider.id.get()).valueOr:
      continue

    records.add(PeerRecord.init(peerId, provider.addrs, seqNo = 0))
  records

proc storedPeerRecord(d: Discovery, peerId: PeerId): ?PeerRecord =
  let sprBook = d.switch.peerStore[SPRBook]
  if peerId notin sprBook:
    return PeerRecord.none

  let record = SignedPeerRecord.decode(sprBook[peerId]).valueOr:
    return PeerRecord.none

  record.data.some

proc findPeer*(
    d: Discovery, peerId: PeerId
): Future[?PeerRecord] {.async: (raises: [CancelledError]).} =
  ## Find peer using the given Discovery object
  ##

  try:
    let info = (await d.kad.findPeer(peerId)).valueOr:
      return PeerRecord.none

    let stored = d.storedPeerRecord(info.peerId)
    if stored.isSome:
      return stored

    return PeerRecord.init(info.peerId, info.addrs, seqNo = 0).some
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Error finding peer", peerId = peerId, exc = exc.msg

  return PeerRecord.none

method findViaMix*(
    d: Discovery, cid: Cid
): Future[?!seq[PeerRecord]] {.base, async: (raises: [CancelledError]).} =
  var candidates = d.dhtMixProxies
  shuffle(candidates)

  for record in candidates:
    let proxy = record.data
    let res = await dht_proxy_client.lookupProviders(d.mixProto, proxy, cid)
    if res.isErr:
      warn "Mix lookup proxy failed", cid, proxy = proxy.peerId, err = res.error.msg
      continue
    return success res.get

  failure("All Mix lookup proxies failed (candidates=" & $candidates.len & ")")

method findDirect*(
    d: Discovery, cid: Cid
): Future[?!seq[PeerRecord]] {.base, async: (raises: [CancelledError]).} =
  try:
    let providers = await d.kad.getProviders(cid.toKey()).wait(LookupTimeout)
    var records = providers.toRecords()
    shuffle(records)
    return success records
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error finding providers for block " & $cid & ": " & exc.msg)

method find*(
    d: Discovery, cid: Cid
): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]), base.} =
  let providers =
    # Note that the invariant checks in `togglePrivateQueries` ensure that
    # `d.privateQueries` is only true when `d.mixProto` and `d.dhtMixProxies`
    # are set; i.e., it never happens that privateQueries is set to true but
    # we branch onto the else case which is non-private.
    if d.privateQueries and not d.mixProto.isNil and d.dhtMixProxies.len > 0:
      (await d.findViaMix(cid)).valueOr:
        warn "Mix lookup failed", cid, err = error.msg
        return @[]
    else:
      (await d.findDirect(cid)).valueOr:
        warn "Direct lookup failed", cid, err = error.msg
        return @[]
  providers.filterIt(not (it.peerId == d.peerId))

method provide*(d: Discovery, cid: Cid) {.async: (raises: [CancelledError]), base.} =
  ## Provide a block Cid
  ##
  try:
    if not await d.kad.startProviding(cid).withTimeout(ProvideTimeout):
      warn "Timed out providing cid", cid
  except CancelledError as exc:
    warn "Error providing block", cid, exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error providing block", cid, exc = exc.msg

proc getSpr*(d: Discovery): ?!string =
  d.switch.peerInfo.toSpr()

proc updateLocalMultiAddr*(d: Discovery) =
  ## This is called when the announced addresses change, to update the local Mix
  ## address once AutoNAT or a relay reservation provides a dialable one.
  if d.mixProto.isNil:
    return

  let addrs = d.switch.peerInfo.addrs
  let mixAddr = pickMixCompatibleMultiAddr(addrs).valueOr:
    warn "No Mix-compatible address among announced addrs", addrs = addrs
    mixUnsetMultiAddr()

  let res = d.mixProto.setLocalMultiAddr(mixAddr)
  if res.isErr:
    # This case should not happen.
    # We checked above that the mix addr is valid,
    # and setLocalMultiAddr should only fail if the address is invalid.
    error "Failed to update Mix local address", address = mixAddr, err = res.error
  else:
    info "Mix local address updated", address = mixAddr

proc setServerMode*(d: Discovery, isServer: bool) {.async: (raises: []).} =
  discard await d.kad.changeMode(isServer)

proc isServerMode*(d: Discovery): bool =
  d.kad.isServer

proc hasBootstrapNodes*(d: Discovery): bool =
  d.bootstrapNodes.len > 0

proc routingTableEmpty*(d: Discovery): bool =
  for bucket in d.kad.rtable.buckets:
    if bucket.peers.len > 0:
      return false
  true

proc reseedRoutingTable*(d: Discovery) {.async: (raises: [CancelledError]).} =
  d.kad.updatePeers(d.bootstrapNodes)
  await d.kad.bootstrap(forceRefresh = true)

proc routingTable*(
    d: Discovery
): tuple[localNode: PeerRecord, peers: seq[RoutingPeer]] =
  var peers: seq[RoutingPeer]
  for bucket in d.kad.rtable.buckets:
    for nodeId in bucket.peers:
      let peerId = nodeId.toPeerId().valueOr:
        continue
      let record = d.kad.rtable.registry.get(nodeId).valueOr:
        continue
      peers.add(
        RoutingPeer(
          record:
            PeerRecord.init(peerId, d.switch.peerStore[AddressBook][peerId], seqNo = 0),
          lastSeen: record.lastSeen,
        )
      )
  (
    localNode: PeerRecord.init(d.peerId, d.switch.peerInfo.addrs, seqNo = 0),
    peers: peers,
  )

proc togglePrivateQueries*(d: Discovery, enabled: bool): ?!bool =
  if enabled and (d.mixProto.isNil or d.dhtMixProxies.len == 0):
    return failure("Cannot enable private queries: Mix is not configured")
  let old = d.privateQueries
  d.privateQueries = enabled
  success(old)

proc isPrivateQueriesEnabled*(d: Discovery): bool =
  d.privateQueries

proc new*(
    T: type Discovery,
    switch: Switch,
    bootstrapNodes: openArray[(PeerId, seq[MultiAddress])] = [],
    dhtMixProxies: openArray[SignedPeerRecord] = [],
    isServer = true,
): Discovery =
  ## Create a new Discovery node instance backed by the libp2p Kademlia DHT
  ##

  var self = Discovery(
    switch: switch,
    peerId: switch.peerInfo.peerId,
    bootstrapNodes: @bootstrapNodes,
    dhtMixProxies: @dhtMixProxies,
  )

  self.kad = KadDHT.new(
    switch,
    bootstrapNodes = self.bootstrapNodes,
    rng = storage_rng.libp2pRng(storage_rng.Rng.instance()),
    isServer = isServer,
  )

  self
