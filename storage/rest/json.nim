import std/importutils
from std/times import getTime, toUnix

import pkg/chronos
import pkg/questionable
import pkg/libp2p
import pkg/libp2p_mix
import pkg/libp2p_mix/curve25519
import pkg/stew/byteutils
import pkg/libp2p/protocols/connectivity/autonatv2/service
import pkg/libp2p/services/autorelayservice
import ../node
import ../discovery
import ../nat
import ../conf
import ../utils/json
import ../manifest
import ../units

export json

type
  RestContent* = object
    cid* {.serialize.}: Cid
    manifest* {.serialize.}: Manifest

  RestContentList* = object
    content* {.serialize.}: seq[RestContent]

  RestNode* = object
    peerId* {.serialize.}: PeerId
    addresses* {.serialize.}: seq[MultiAddress]
    lastSeen* {.serialize.}: Option[int64]

  RestRoutingTable* = object
    localNode* {.serialize.}: RestNode
    nodes* {.serialize.}: seq[RestNode]

  RestPeerRecord* = object
    peerId* {.serialize.}: PeerId
    seqNo* {.serialize.}: uint64
    addresses* {.serialize.}: seq[AddressInfo]

  RestRepoStore* = object
    totalBlocks* {.serialize.}: Natural
    quotaMaxBytes* {.serialize.}: NBytes
    quotaUsedBytes* {.serialize.}: NBytes
    quotaReservedBytes* {.serialize.}: NBytes

  VersionInfo* = object
    version* {.serialize.}: string
    revision* {.serialize.}: string

  NatDebugInfo* = object
    reachability* {.serialize.}: string
    clientMode* {.serialize.}: bool
    relayRunning* {.serialize.}: bool
    portMapping* {.serialize.}: string

  DebugInfo* = object # Peer's ID
    id* {.serialize.}: PeerId
    # peer addresses known by the libp2p switch
    addrs* {.serialize.}: seq[MultiAddress]
    # signed peer record (URI form)
    spr* {.serialize.}: string
    # libp2p public key
    libp2pPubKey* {.serialize.}: string
    # mix public key (for nodes that support mix)
    mixPubKey* {.serialize.}: Option[FieldElement]
    # DHT routing table
    table* {.serialize.}: RestRoutingTable
    storage* {.serialize.}: VersionInfo
    # NAT reachability, relay and port-mapping status
    nat* {.serialize.}: NatDebugInfo
    # active peer connections
    connections* {.serialize.}: JsonNode
    # are DHT queries going over mix?
    privateQueries* {.serialize.}: bool

proc init*(_: type RestContentList, content: seq[RestContent]): RestContentList =
  RestContentList(content: content)

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(cid: cid, manifest: manifest)

proc init*(_: type RestNode, peerId: PeerId, addresses: seq[MultiAddress]): RestNode =
  RestNode(peerId: peerId, addresses: addresses)

proc init*(_: type RestNode, peerRecord: PeerRecord): RestNode =
  var addrs: seq[MultiAddress]
  for a in peerRecord.addresses:
    addrs.add(a.address)
  RestNode.init(peerRecord.peerId, addrs)

proc init*(_: type RestNode, peer: RoutingPeer): RestNode =
  var node = RestNode.init(peer.record)
  let secondsSinceSeen = (Moment.now() - peer.lastSeen).seconds
  node.lastSeen = some(getTime().toUnix() - secondsSinceSeen)
  node

proc init*(_: type RestRoutingTable, discovery: Discovery): RestRoutingTable =
  let table = discovery.routingTable()
  var nodes: seq[RestNode]
  for peer in table.peers:
    nodes.add(RestNode.init(peer))
  RestRoutingTable(localNode: RestNode.init(table.localNode), nodes: nodes)

proc init*(_: type RestPeerRecord, peerRecord: PeerRecord): RestPeerRecord =
  RestPeerRecord(
    peerId: peerRecord.peerId, seqNo: peerRecord.seqNo, addresses: peerRecord.addresses
  )

proc init*(
    _: type DebugInfo,
    node: StorageNodeRef,
    autonat: Option[AutonatV2Service],
    autoRelay: Option[AutoRelayService],
    natMapper: Option[NatPortMapper],
): DebugInfo =
  let
    peerInfo = node.switch.peerInfo
    peerId = peerInfo.peerId
    libp2pPubKeyBytes = peerInfo.publicKey.getRawBytes()

  # Cause there's no canonical way to get your own key from MixProtocol
  # that I'm aware of.
  privateAccess(MixProtocol)

  DebugInfo(
    id: peerId,
    addrs: peerInfo.addrs,
    spr: node.discovery.getSpr().valueOr(""),
    table: RestRoutingTable.init(node.discovery),
    storage: VersionInfo(version: $storageVersion, revision: $storageRevision),
    # Serialization has no error contract in nim-serde, so we need to
    # handle this here.
    libp2pPubKey:
      if libp2pPubKeyBytes.isErr:
        $libp2pPubKeyBytes.error
      else:
        byteutils.toHex(libp2pPubKeyBytes.get),
    mixPubKey:
      if node.discovery.mixProto.isNil():
        none(FieldElement)
      else:
        # It's a bug if we don't have the peer in the pool, so let it throw an exception.
        some(node.discovery.mixProto.mixNodeInfo.mixPubKey),
    nat: NatDebugInfo(
      reachability: reachabilityStr(autonat),
      clientMode: not node.discovery.isServerMode(),
      relayRunning: autoRelay.isSome and autoRelay.get.isRunning,
      portMapping: portMappingStr(natMapper),
    ),
    connections: peerConnections(node.switch),
    privateQueries: node.discovery.isPrivateQueriesEnabled,
  )
