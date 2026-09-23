import std/[random, sets, sequtils]
import pkg/unittest2
import pkg/libp2p/peerid
import pkg/storage/blockexchange/peers
import pkg/storage/blockexchange/engine/peerselection
import ../../examples

suite "Presence peer selection":
  var peers: PeerContextStore
  var providers: HashSet[PeerId]
  var connected: seq[PeerContext]

  setup:
    peers = PeerContextStore.new()
    for i in 0 ..< 6:
      peers.add(PeerContext.new(PeerId.example))
    connected = peers.toSeq()
    providers = toHashSet([connected[4].id, connected[1].id])

  teardown:
    randomize()

  test "Default initial selection matches master's shuffle and truncation":
    var expected = peers.toSeq()
    randomize(1729)
    shuffle(expected)
    expected.setLen(3)
    let nextRandom = rand(100000)
    randomize(1729)
    let actual =
      newPresencePeerSelectionPolicy().selectInitialPresencePeers(peers, providers, 3)
    check actual == expected
    check rand(100000) == nextRandom

  test "Default keeps order and consumes no randomness when all peers fit":
    randomize(1729)
    let nextRandom = rand(100000)
    randomize(1729)
    check newPresencePeerSelectionPolicy().selectInitialPresencePeers(
      peers, providers, 6
    ) == connected
    check rand(100000) == nextRandom

  test "Default later queries include every peer in store order":
    let policy = newPresencePeerSelectionPolicy()
    check policy.selectPresencePeers(peers, providers) == connected
    check not policy.needsProviderTracking

  test "Provider priority preserves fallback peers":
    let policy = newProviderPriorityPolicy()
    let selected = policy.selectPresencePeers(peers, providers)
    check selected ==
      @[
        connected[1],
        connected[4],
        connected[0],
        connected[2],
        connected[3],
        connected[5],
      ]
    check policy.needsProviderTracking

  test "Provider priority truncates only the initial list":
    let policy = newProviderPriorityPolicy()
    check policy.selectInitialPresencePeers(peers, providers, 1) == @[connected[1]]
    check policy.selectPresencePeers(peers, providers).len == connected.len

  test "Provider-only eligibility requires explicit opt-in":
    let policy = newProviderPriorityPolicy(providersOnly = true)
    check policy.selectPresencePeers(peers, providers) == @[connected[1], connected[4]]
    check policy.selectPresencePeers(peers, initHashSet[PeerId]()).len == 0
