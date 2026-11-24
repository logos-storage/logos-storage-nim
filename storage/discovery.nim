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
import pkg/libp2p_mix/mix_node
from pkg/libp2p_mix/sphinx import PathLength
import pkg/libp2p_mix_transport/address/parse
import pkg/questionable
import pkg/questionable/results

import ./rng as storage_rng
import ./utils/mixidentity
import ./errors
import ./logutils
import ./utils/spr
import ./dht_proxy/client as dht_proxy_client
import ./dht_proxy/protocol

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
  PutValueTimeout = 1.minutes
  ValueQuorum = 5
  # Seconds. The libp2p defaults, that a test build can shorten, for example
  # with -d:storage_kad_record_retention=3600
  KadRecordRetention {.intdefine: "storage_kad_record_retention".} = 24 * 60 * 60
  KadCleanupInterval {.intdefine: "storage_kad_cleanup_interval".} = 60 * 60

  StorageServiceId* = "/logos-storage/1.0.0"
  AutonatServiceId* = $AutonatV2Codec.DialRequest
  CircuitRelayServiceId* = RelayV2HopCodec
  MixServiceId* = MixProtocolID
  DhtProxyServiceId* = DhtProxyCodec

  MinMixRelays* = PathLength + 1
  MaxMixRelays = 1024
  MaxServiceProviders = 32

type
  ServiceProvider* = object
    record*: PeerRecord
    lastSeen*: Moment

  Discovery* = ref object of RootObj
    kad*: KadDHT # libp2p Kademlia DHT
    serviceDiscovery*: ServiceDiscovery # libp2p Service discovery
    providedServices: seq[string] # services this node provides
    addressPolicy: PeerAddressPolicy
    serviceLookupInterval: Duration
    serviceProviders: Table[string, Table[PeerId, ServiceProvider]]
    lastServiceLookup: Moment
    switch: Switch # local libp2p switch
    peerId: PeerId # the peer id of the local node
    mixProto*: MixProtocol
    staticMixRelays*: HashSet[PeerId]
    staticDhtMixProxies*: seq[PeerRecord]
    staticAutonatServers: seq[PeerRecord]
    staticCircuitRelayServers: seq[PeerRecord]

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

proc providersFor(d: Discovery, serviceId: string): var Table[PeerId, ServiceProvider] =
  d.serviceProviders.mgetOrPut(serviceId, initTable[PeerId, ServiceProvider]())

proc serviceProvidersOf(d: Discovery, serviceId: string): seq[PeerRecord] =
  toSeq(d.providersFor(serviceId).values).mapIt(it.record)

proc getServiceProviders*(d: Discovery): Table[string, seq[ServiceProvider]] =
  var providers: Table[string, seq[ServiceProvider]]
  for serviceId, table in d.serviceProviders:
    providers[serviceId] = toSeq(table.values)
  providers

proc withDiscovered(
    d: Discovery, staticProviders: seq[PeerRecord], serviceId: string
): seq[PeerRecord] =
  var providers = staticProviders
  for provider in d.serviceProvidersOf(serviceId):
    if not providers.anyIt(it.peerId == provider.peerId):
      providers.add(provider)
  providers

proc dhtMixProxies*(d: Discovery): seq[PeerRecord] =
  d.withDiscovered(d.staticDhtMixProxies, DhtProxyServiceId)

proc autonatServers*(d: Discovery): seq[PeerRecord] =
  ## Returns the list of Autonat servers.
  ## The nodes are expected to be directly reachable.
  ## Returns the static AutoNAT servers and the discovered ones.
  d.withDiscovered(d.staticAutonatServers, AutonatServiceId)

proc circuitRelayServers*(d: Discovery): seq[PeerRecord] =
  ## Returns the static circuit relay servers and the discovered ones.
  d.withDiscovered(d.staticCircuitRelayServers, CircuitRelayServiceId)

method findViaMix*(
    d: Discovery, cid: Cid
): Future[?!seq[PeerRecord]] {.base, async: (raises: [CancelledError]).} =
  var candidates = d.dhtMixProxies
  shuffle(candidates)

  for proxy in candidates:
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

proc putValue*(
    d: Discovery, key: seq[byte], value: seq[byte]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store a value under a key on the closest server nodes
  ##
  try:
    let res = await d.kad.putValue(key, value).wait(PutValueTimeout)

    if res.isErr:
      return failure("Error putting value: " & res.error)

    return success()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error putting value: " & exc.msg)

proc getValue*(
    d: Discovery, key: seq[byte]
): Future[?!seq[byte]] {.async: (raises: [CancelledError]).} =
  ## Read the value stored under a key
  ##
  try:
    let res = await d.kad.getValue(key).wait(LookupTimeout)

    if res.isErr:
      return failure("Error getting value: " & res.error)

    return success res.get().value
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure("Error getting value: " & exc.msg)

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

proc advertisement(d: Discovery): Result[seq[byte], string] =
  let addrs = d.addressPolicy.dialableAddrs(
    d.switch.peerInfo.addrs, d.switch.peerStore.allowUndialableAddrs
  )
  if addrs.len == 0:
    return err("No dialable address to advertise")

  let
    services = @[StorageServiceId] & d.providedServices
    record = ExtendedPeerRecord.init(
      peerId = d.peerId,
      addresses = addrs,
      services = services.mapIt(ServiceInfo(id: it)),
    )
    signed = SignedExtendedPeerRecord.build(d.switch.peerInfo.privateKey, record).valueOr:
      return err("Cannot sign the advertisement: " & error)
  ok(signed.encode())

proc startAdvertisingServices*(d: Discovery) =
  if d.providedServices.len == 0:
    return

  let advert = d.advertisement().valueOr:
    warn "Cannot advertise services", services = d.providedServices, err = error
    return

  d.serviceDiscovery.startAdvertising(
    ServiceInfo(id: StorageServiceId), Opt.some(advert)
  ).isOkOr:
    warn "Cannot advertise services", services = d.providedServices, err = error

proc stopAdvertisingServices*(d: Discovery) {.async: (raises: []).} =
  await noCancel d.serviceDiscovery.stopAdvertising(StorageServiceId)

proc setServerMode*(d: Discovery, isServer: bool) {.async: (raises: []).} =
  discard await d.kad.changeMode(isServer)
  if not await d.serviceDiscovery.changeMode(isServer):
    return

  if isServer:
    d.startAdvertisingServices()
  else:
    await d.stopAdvertisingServices()

func providedServices*(
    autonatServer: bool, relayServer: bool, mixRelay = false, dhtProxyServer = false
): seq[string] =
  if autonatServer:
    result.add(AutonatServiceId)
  if relayServer:
    result.add(CircuitRelayServiceId)
  if mixRelay:
    result.add(MixServiceId)
  if dhtProxyServer:
    result.add(DhtProxyServiceId)

proc lookupServiceProviders(
    d: Discovery
): Future[Result[seq[Advertisement], string]] {.async: (raises: [CancelledError]).} =
  await d.serviceDiscovery.waitBootstrap()

  let ads = (await d.serviceDiscovery.lookup(ServiceInfo(id: StorageServiceId))).valueOr:
    return err("Service lookup failed: " & error)

  var providers: seq[Advertisement]
  for ad in ads:
    if ad.data.peerId == d.peerId or providers.anyIt(it.data.peerId == ad.data.peerId):
      continue
    providers.add(ad)
  ok(providers)

func maxProviders(serviceId: string): int =
  if serviceId == MixServiceId: MaxMixRelays else: MaxServiceProviders

proc leastSeen(
    d: Discovery, providers: Table[PeerId, ServiceProvider], now: Moment
): Opt[PeerId] =
  var
    peer = Opt.none(PeerId)
    oldest = now
  for peerId, provider in providers:
    if provider.lastSeen < oldest and not d.switch.isConnected(peerId):
      peer = Opt.some(peerId)
      oldest = provider.lastSeen
  peer

proc expireMixRelays(d: Discovery, now: Moment) =
  let expiry = 2 * d.serviceDiscovery.discoConfig.advertExpiry
  var expired: seq[PeerId]
  for peerId, provider in d.providersFor(MixServiceId):
    if now - provider.lastSeen > expiry:
      expired.add(peerId)
  for peerId in expired:
    d.providersFor(MixServiceId).del(peerId)

proc updateServiceProviders(d: Discovery, ads: seq[Advertisement]) =
  let now = Moment.now()
  var added: seq[(string, PeerId, PeerRecord)]

  for ad in ads:
    let record =
      PeerRecord.init(ad.data.peerId, ad.data.addresses.mapIt(it.address), seqNo = 0)
    for service in ad.data.services:
      if service.id == StorageServiceId:
        continue
      if ad.data.peerId in d.providersFor(service.id):
        d.providersFor(service.id)[ad.data.peerId] =
          ServiceProvider(record: record, lastSeen: now)
      else:
        added.add((service.id, ad.data.peerId, record))

  d.expireMixRelays(now)

  for (serviceId, peerId, record) in added:
    if d.providersFor(serviceId).len >= maxProviders(serviceId):
      let evicted = d.leastSeen(d.providersFor(serviceId), now).valueOr:
        continue
      d.providersFor(serviceId).del(evicted)
    d.providersFor(serviceId)[peerId] = ServiceProvider(record: record, lastSeen: now)

proc findServiceProviders*(
    d: Discovery, serviceId: string
): Future[Result[seq[PeerRecord], string]] {.async: (raises: [CancelledError]).} =
  if Moment.now() - d.lastServiceLookup < d.serviceLookupInterval:
    let providers = d.serviceProvidersOf(serviceId)
    if providers.len > 0:
      return ok(providers)

  let res =
    try:
      await d.lookupServiceProviders().wait(ServiceLookupTimeout)
    except AsyncTimeoutError:
      return err("Service lookup timed out after " & $ServiceLookupTimeout)

  let ads = res.valueOr:
    return err(error)

  d.updateServiceProviders(ads)
  d.lastServiceLookup = Moment.now()
  ok(d.serviceProvidersOf(serviceId))

proc removeServiceProvider*(d: Discovery, serviceId: string, peerId: PeerId) =
  d.providersFor(serviceId).del(peerId)

proc findMixRelays*(
    d: Discovery
): Future[Result[seq[MixPubInfo], string]] {.async: (raises: [CancelledError]).} =
  let providers = (await d.findServiceProviders(MixServiceId)).valueOr:
    return err(error)

  var relays: seq[MixPubInfo]
  for provider in providers:
    for address in provider.addresses:
      let relay = MixPubInfo.fromMixAddress(address.address, Opt.some(provider.peerId)).valueOr:
        continue
      relays.add(relay)
      break
  ok(relays)

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
    serviceLookupInterval = ZeroDuration,
    validator: EntryValidator = DefaultEntryValidator(),
    selector: EntrySelector = DefaultEntrySelector(),
): Discovery =
  ## Create a new Discovery node instance backed by the libp2p Kademlia DHT
  ##

  var self = Discovery(
    switch: switch,
    peerId: switch.peerInfo.peerId,
    staticDhtMixProxies: dhtMixProxies.mapIt(it.data),
    staticAutonatServers: bootstrapNodes.mapIt(PeerRecord.init(it[0], it[1], seqNo = 0)),
    staticCircuitRelayServers:
      bootstrapNodes.mapIt(PeerRecord.init(it[0], it[1], seqNo = 0)),
    providedServices: @providedServices,
    addressPolicy: addressPolicy,
    serviceLookupInterval: serviceLookupInterval,
  )

  self.kad = KadDHT.new(
    switch,
    bootstrapNodes = @bootstrapNodes,
    config = KadDHTConfig.new(
      addressPolicy = addressPolicy,
      quorum = ValueQuorum,
      recordExpirationInterval = chronos.seconds(KadRecordRetention),
      cleanupDataEntriesInterval = chronos.seconds(KadCleanupInterval),
      validator = validator,
      selector = selector,
    ),
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
