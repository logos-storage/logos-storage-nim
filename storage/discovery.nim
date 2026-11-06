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
import std/tables

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/wire
import pkg/libp2p/extended_peer_record
import pkg/libp2p/protocols/kademlia except PeerRecord
import pkg/libp2p/protocols/service_discovery except PeerRecord
from pkg/libp2p/protocols/connectivity/autonatv2/types import AutonatV2Codec
from pkg/libp2p/protocols/connectivity/relay/utils import RelayV2HopCodec
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
  ServiceLookupTimeout = 1.minutes

  AutonatServiceId* = $AutonatV2Codec.DialRequest
  RelayServiceId* = RelayV2HopCodec

type
  Discovery* = ref object of RootObj
    kad*: KadDHT # libp2p Kademlia DHT
    serviceDiscovery*: ServiceDiscovery # libp2p Service discovery
    services: seq[string] # services this node provides
    switch: Switch # local libp2p switch
    peerId: PeerId # the peer id of the local node
    mixProto*: MixProtocol
    dhtMixProxies*: seq[SignedPeerRecord]

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
    d: Discovery, cid: Cid, useMix: bool = false
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]), base.} =
  let providers =
    if useMix:
      if d.mixProto.isNil or d.dhtMixProxies.len == 0:
        return failure(
          "Mix lookup requested but MixProtocol not enabled no Mix proxies configured"
        )
      else:
        (await d.findViaMix(cid)).valueOr:
          warn "Mix lookup failed", cid, err = error.msg
          return failure(error.msg)
    else:
      (await d.findDirect(cid)).valueOr:
        warn "Direct lookup failed", cid, err = error.msg
        return failure(error.msg)

  ok(providers.filterIt(not (it.peerId == d.peerId)))

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

method stopProviding*(d: Discovery, cid: Cid) {.base, gcsafe, raises: [].} =
  ## Stop announcing a block Cid
  ##
  d.kad.stopProviding(cid)

method stopProvidingAll*(d: Discovery) {.base, gcsafe, raises: [].} =
  ## Stop announcing every Cid this node provides by clearing the table
  ##
  d.kad.providerManager.providedKeys.provided.clear()

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

proc startAdvertising*(d: Discovery) =
  for serviceId in d.services:
    d.serviceDiscovery.startAdvertising(ServiceInfo(id: serviceId)).isOkOr:
      warn "Cannot advertise service", serviceId, err = error

proc stopAdvertising*(d: Discovery) {.async: (raises: []).} =
  for serviceId in d.services:
    await noCancel d.serviceDiscovery.stopAdvertising(serviceId)

proc setServerMode*(d: Discovery, isServer: bool) {.async: (raises: []).} =
  discard await d.kad.changeMode(isServer)
  if not await d.serviceDiscovery.changeMode(isServer):
    return

  if isServer:
    d.startAdvertising()
  else:
    await d.stopAdvertising()

func providedServices*(autonatServer: bool, relayServer: bool): seq[string] =
  if autonatServer:
    result.add(AutonatServiceId)
  if relayServer:
    result.add(RelayServiceId)

proc lookupServiceProviders(
    d: Discovery, serviceId: string
): Future[Result[seq[PeerRecord], string]] {.async: (raises: [CancelledError]).} =
  await d.serviceDiscovery.waitBootstrap()

  let ads = (await d.serviceDiscovery.lookup(ServiceInfo(id: serviceId))).valueOr:
    return err("Service lookup failed: " & error)

  var providers: seq[PeerRecord]
  for ad in ads:
    if ad.data.peerId == d.peerId or providers.anyIt(it.peerId == ad.data.peerId):
      continue
    providers.add(
      PeerRecord.init(ad.data.peerId, ad.data.addresses.mapIt(it.address), seqNo = 0)
    )
  ok(providers)

proc findServiceProviders*(
    d: Discovery, serviceId: string
): Future[Result[seq[PeerRecord], string]] {.async: (raises: [CancelledError]).} =
  try:
    return await d.lookupServiceProviders(serviceId).wait(ServiceLookupTimeout)
  except AsyncTimeoutError:
    return err("Service lookup timed out after " & $ServiceLookupTimeout)

proc connectServiceProviders*(
    d: Discovery, serviceId: string, limit: int, exclude: seq[PeerId]
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  proc connect(
      provider: PeerRecord
  ): Future[bool] {.async: (raises: [CancelledError]).} =
    try:
      await d.switch.connect(provider.peerId, provider.addresses.mapIt(it.address))
      return true
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Cannot connect to service provider",
        serviceId, peer = provider.peerId, err = exc.msg
      return false

  let providers = (await d.findServiceProviders(serviceId)).valueOr:
    warn "Unable to find service providers", serviceId, err = error
    return @[]

  var candidates = providers.filterIt(it.peerId notin exclude)
  shuffle(candidates)
  if candidates.len > limit:
    candidates.setLen(limit)

  debug "Service providers found",
    serviceId, found = providers.len, connecting = candidates.len

  let connects = candidates.mapIt(connect(it))
  try:
    await allFutures(connects)
  except CancelledError as exc:
    await noCancel allFutures(connects.mapIt(it.cancelAndWait()))
    raise exc

  var connected: seq[PeerId]
  for i, fut in connects:
    if fut.value():
      connected.add(candidates[i].peerId)

  if connected.len > 0:
    info "Connected to service providers", serviceId, connected = connected.len
  connected

proc isServerMode*(d: Discovery): bool =
  d.kad.isServer

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

proc new*(
    T: type Discovery,
    switch: Switch,
    bootstrapNodes: openArray[(PeerId, seq[MultiAddress])] = [],
    dhtMixProxies: openArray[SignedPeerRecord] = [],
    isServer = true,
    addressPolicy: PeerAddressPolicy = defaultAddressPolicy,
    providedServices: openArray[string] = [],
): Discovery =
  ## Create a new Discovery node instance backed by the libp2p Kademlia DHT
  ##

  var self = Discovery(
    switch: switch,
    peerId: switch.peerInfo.peerId,
    dhtMixProxies: @dhtMixProxies,
    services: @providedServices,
  )

  self.kad = KadDHT.new(
    switch,
    bootstrapNodes = @bootstrapNodes,
    config = KadDHTConfig.new(addressPolicy = addressPolicy),
    rng = storage_rng.libp2pRng(storage_rng.Rng.instance()),
    isServer = isServer,
  )

  self.serviceDiscovery = ServiceDiscovery.new(
    switch,
    bootstrapNodes = @bootstrapNodes,
    config = KadDHTConfig.new(
      ExtEntryValidator(), ExtEntrySelector(), addressPolicy = addressPolicy
    ),
    rng = storage_rng.libp2pRng(storage_rng.Rng.instance()),
    client = not isServer,
  )

  self
