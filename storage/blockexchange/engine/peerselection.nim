## Policies for choosing the peers queried for content availability.
## The caller selects the transport's peer store before invoking the policy.

import std/[sets, sequtils, random]
import pkg/libp2p/peerid
import ../peers

type
  PresencePeerSelectionPolicy* = ref object of RootObj
  ProviderPriorityPolicy* = ref object of PresencePeerSelectionPolicy
    providersOnly: bool

method needsProviderTracking*(
    policy: PresencePeerSelectionPolicy
): bool {.base, gcsafe, raises: [].} =
  false

method selectInitialPresencePeers*(
    policy: PresencePeerSelectionPolicy,
    peers: PeerContextStore,
    providers: HashSet[PeerId],
    limit: int,
): seq[PeerContext] {.base, gcsafe, raises: [].} =
  result = peers.toSeq()
  if result.len > limit:
    shuffle(result)
    result.setLen(limit)

method selectPresencePeers*(
    policy: PresencePeerSelectionPolicy,
    peers: PeerContextStore,
    providers: HashSet[PeerId],
): seq[PeerContext] {.base, gcsafe, raises: [].} =
  peers.toSeq()

method needsProviderTracking*(
    policy: ProviderPriorityPolicy
): bool {.gcsafe, raises: [].} =
  true

method selectPresencePeers*(
    policy: ProviderPriorityPolicy, peers: PeerContextStore, providers: HashSet[PeerId]
): seq[PeerContext] {.gcsafe, raises: [].} =
  let connected = peers.toSeq()
  result = connected.filterIt(it.id in providers)
  if not policy.providersOnly:
    result.add(connected.filterIt(it.id notin providers))

method selectInitialPresencePeers*(
    policy: ProviderPriorityPolicy,
    peers: PeerContextStore,
    providers: HashSet[PeerId],
    limit: int,
): seq[PeerContext] {.gcsafe, raises: [].} =
  result = policy.selectPresencePeers(peers, providers)
  if result.len > limit:
    result.setLen(limit)

proc newPresencePeerSelectionPolicy*(): PresencePeerSelectionPolicy =
  ## Master's selection: shuffle only an oversized initial candidate list.
  PresencePeerSelectionPolicy()

proc newProviderPriorityPolicy*(providersOnly = false): ProviderPriorityPolicy =
  ## Prioritize known providers. Excluding other peers is a separate opt-in.
  ProviderPriorityPolicy(providersOnly: providersOnly)
