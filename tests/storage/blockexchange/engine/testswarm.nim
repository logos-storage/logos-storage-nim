import std/[options, sets, tables]

import pkg/unittest2
import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/peerid

import pkg/storage/blockexchange/engine/swarm
import pkg/storage/blockexchange/engine/peertracker
import pkg/storage/blockexchange/peers/peercontext
import pkg/storage/blockexchange/peers/peerstats
import pkg/storage/blockexchange/protocol/message
import pkg/storage/blockexchange/utils
import pkg/storage/storagetypes

import ../../examples

const
  TestBlockSize = DefaultBlockSize.uint32
  TestBatchBytes = computeBatchSize(TestBlockSize).uint64 * TestBlockSize.uint64

suite "BlockAvailability":
  test "unknown availability":
    let avail = BlockAvailability.unknown()
    check avail.kind == bakUnknown
    check avail.hasBlock(0) == false
    check avail.hasBlock(100) == false
    check avail.hasRange(0, 10) == false
    check avail.hasAnyInRange(0, 10) == false

  test "complete availability":
    let avail = BlockAvailability.complete()
    check avail.kind == bakComplete
    check avail.hasBlock(0) == true
    check avail.hasBlock(100) == true
    check avail.hasBlock(uint64.high) == true
    check avail.hasRange(0, 1000) == true
    check avail.hasAnyInRange(0, 1000) == true

  test "ranges availability - hasBlock":
    let avail = BlockAvailability.fromRanges(
      @[
        IndexRange(start: 10'u64, count: 20'u64),
        IndexRange(start: 50'u64, count: 10'u64),
      ]
    )
    check avail.kind == bakRanges

    check avail.hasBlock(10) == true
    check avail.hasBlock(29) == true
    check avail.hasBlock(30) == false

    check avail.hasBlock(50) == true
    check avail.hasBlock(59) == true
    check avail.hasBlock(60) == false

    check avail.hasBlock(0) == false
    check avail.hasBlock(9) == false
    check avail.hasBlock(35) == false

  test "ranges availability - hasRange":
    let avail = BlockAvailability.fromRanges(
      @[
        IndexRange(start: 10'u64, count: 20'u64),
        IndexRange(start: 50'u64, count: 10'u64),
      ]
    )

    check avail.hasRange(10, 20) == true
    check avail.hasRange(15, 10) == true

    check avail.hasRange(10, 21) == false
    check avail.hasRange(25, 10) == false

    check avail.hasRange(50, 10) == true
    check avail.hasRange(55, 5) == true

    check avail.hasRange(25, 30) == false

  test "ranges availability - hasAnyInRange":
    let avail = BlockAvailability.fromRanges(
      @[
        IndexRange(start: 10'u64, count: 20'u64),
        IndexRange(start: 50'u64, count: 10'u64),
      ]
    )

    check avail.hasAnyInRange(5, 10) == true
    check avail.hasAnyInRange(25, 10) == true

    check avail.hasAnyInRange(45, 10) == true

    check avail.hasAnyInRange(30, 20) == false

    check avail.hasAnyInRange(0, 5) == false

    check avail.hasAnyInRange(100, 10) == false

  test "bitmap availability - hasBlock":
    let avail = BlockAvailability.fromBitmap(@[0x55'u8], 8)
    check avail.kind == bakBitmap

    check avail.hasBlock(0) == true
    check avail.hasBlock(1) == false
    check avail.hasBlock(2) == true
    check avail.hasBlock(3) == false
    check avail.hasBlock(4) == true
    check avail.hasBlock(5) == false
    check avail.hasBlock(6) == true
    check avail.hasBlock(7) == false

    check avail.hasBlock(8) == false
    check avail.hasBlock(100) == false

  test "bitmap availability - hasRange":
    let avail = BlockAvailability.fromBitmap(@[0xF0'u8], 8)

    check avail.hasRange(4, 4) == true
    check avail.hasRange(4, 2) == true
    check avail.hasRange(0, 4) == false
    check avail.hasRange(2, 4) == false

  test "bitmap availability - hasAnyInRange":
    let avail = BlockAvailability.fromBitmap(@[0xF0'u8], 8)

    check avail.hasAnyInRange(0, 8) == true
    check avail.hasAnyInRange(0, 4) == false
    check avail.hasAnyInRange(3, 2) == true
    check avail.hasAnyInRange(6, 4) == true

  test "merge unknown with complete":
    let
      unknown = BlockAvailability.unknown()
      complete = BlockAvailability.complete()

    check unknown.merge(complete).kind == bakComplete
    check complete.merge(unknown).kind == bakComplete

  test "merge unknown with ranges":
    let
      unknown = BlockAvailability.unknown()
      ranges = BlockAvailability.fromRanges(@[IndexRange(start: 10'u64, count: 20'u64)])
      merged = unknown.merge(ranges)
    check merged.kind == bakRanges
    check merged.hasBlock(15) == true

  test "merge ranges with ranges":
    let
      r1 = BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 10'u64)])
      r2 = BlockAvailability.fromRanges(@[IndexRange(start: 20'u64, count: 10'u64)])
      merged = r1.merge(r2)

    check merged.kind == bakRanges
    check merged.hasBlock(5) == true
    check merged.hasBlock(25) == true
    check merged.hasBlock(15) == false

  test "merge overlapping ranges":
    let
      r1 = BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 15'u64)])
      r2 = BlockAvailability.fromRanges(@[IndexRange(start: 10'u64, count: 15'u64)])
      merged = r1.merge(r2)

    check merged.kind == bakRanges
    check merged.ranges.len == 1
    check merged.ranges[0].start == 0
    check merged.ranges[0].count == 25

  test "merge bitmap with ranges converts bitmap to ranges":
    let
      bitmap = BlockAvailability.fromBitmap(@[0x0F'u8], 8)
      ranges = BlockAvailability.fromRanges(@[IndexRange(start: 6'u64, count: 2'u64)])
      merged = bitmap.merge(ranges)

    check merged.kind == bakRanges
    check merged.ranges.len == 2
    check merged.ranges[0] == IndexRange(start: 0'u64, count: 4'u64)
    check merged.ranges[1] == IndexRange(start: 6'u64, count: 2'u64)

suite "SwarmPeer":
  test "touch updates lastSeen":
    let
      peer = SwarmPeer.new(BlockAvailability.unknown())
      before = peer.lastSeen
    peer.touch()
    check peer.lastSeen >= before

  test "updateAvailability merges":
    let peer = SwarmPeer.new(
      BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 10'u64)])
    )
    peer.updateAvailability(
      BlockAvailability.fromRanges(@[IndexRange(start: 20'u64, count: 10'u64)])
    )

    check peer.availability.hasBlock(5) == true
    check peer.availability.hasBlock(25) == true
    check peer.availability.hasBlock(15) == false

  test "recordFailure and resetFailures":
    let peer = SwarmPeer.new(BlockAvailability.unknown())
    check peer.failureCount == 0

    peer.recordFailure()
    check peer.failureCount == 1

    peer.recordFailure()
    check peer.failureCount == 2

    peer.resetFailures()
    check peer.failureCount == 0

suite "Swarm":
  var swarm: Swarm

  setup:
    swarm = Swarm.new()

  test "addPeer and getPeer":
    let peerId = PeerId.example
    check swarm.addPeer(peerId, BlockAvailability.complete()) == true

    let peerOpt = swarm.getPeer(peerId)
    check peerOpt.isSome
    check peerOpt.get().availability.kind == bakComplete

  test "addPeer respects deltaMax":
    let config =
      SwarmConfig(deltaMin: 1, deltaMax: 2, deltaTarget: 2, maxPeerFailures: 3)
    swarm = Swarm.new(config)

    check swarm.addPeer(PeerId.example, BlockAvailability.complete()) == true
    check swarm.addPeer(PeerId.example, BlockAvailability.complete()) == true
    check swarm.addPeer(PeerId.example, BlockAvailability.complete()) == false

    check swarm.peerCount() == 2

  test "removePeer":
    let peerId = PeerId.example
    discard swarm.addPeer(peerId, BlockAvailability.complete())

    let removed = swarm.removePeer(peerId)
    check removed.isSome
    check swarm.getPeer(peerId).isNone

  test "banPeer prevents re-adding":
    let peerId = PeerId.example
    discard swarm.addPeer(peerId, BlockAvailability.complete())

    swarm.banPeer(peerId)
    check swarm.getPeer(peerId).isNone
    check swarm.addPeer(peerId, BlockAvailability.complete()) == false

  test "updatePeerAvailability":
    let peerId = PeerId.example
    discard swarm.addPeer(
      peerId, BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 10'u64)])
    )

    swarm.updatePeerAvailability(
      peerId, BlockAvailability.fromRanges(@[IndexRange(start: 20'u64, count: 10'u64)])
    )

    let peer = swarm.getPeer(peerId).get()
    check peer.availability.hasBlock(5) == true
    check peer.availability.hasBlock(25) == true

  test "recordPeerFailure returns true when max reached":
    let config =
      SwarmConfig(deltaMin: 1, deltaMax: 10, deltaTarget: 5, maxPeerFailures: 2)
    swarm = Swarm.new(config)

    let peerId = PeerId.example
    discard swarm.addPeer(peerId, BlockAvailability.complete())

    check swarm.recordPeerFailure(peerId) == false
    check swarm.recordPeerFailure(peerId) == true

  test "peersWithRange":
    let
      peer1 = PeerId.example
      peer2 = PeerId.example

    discard swarm.addPeer(peer1, BlockAvailability.complete())
    discard swarm.addPeer(
      peer2, BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 100'u64)])
    )

    let peersForRange = swarm.peersWithRange(0, 50)
    check peersForRange.len == 2

    let peersForLargeRange = swarm.peersWithRange(0, 150)
    check peersForLargeRange.len == 1

  test "peersWithAnyInRange":
    let
      peer1 = PeerId.example
      peer2 = PeerId.example

    discard swarm.addPeer(
      peer1, BlockAvailability.fromRanges(@[IndexRange(start: 0'u64, count: 50'u64)])
    )
    discard swarm.addPeer(
      peer2, BlockAvailability.fromRanges(@[IndexRange(start: 100'u64, count: 50'u64)])
    )

    let peers1 = swarm.peersWithAnyInRange(25, 50)
    check peers1.len == 1

    let peers2 = swarm.peersWithAnyInRange(75, 50)
    check peers2.len == 1

    let peers3 = swarm.peersWithAnyInRange(60, 30)
    check peers3.len == 0

  test "peersNeeded":
    let config =
      SwarmConfig(deltaMin: 2, deltaMax: 10, deltaTarget: 5, maxPeerFailures: 3)
    swarm = Swarm.new(config)

    check swarm.peersNeeded() == shBelowMin

    discard swarm.addPeer(PeerId.example, BlockAvailability.complete())
    check swarm.peersNeeded() == shBelowMin

    discard swarm.addPeer(PeerId.example, BlockAvailability.complete())
    check swarm.peersNeeded() == shBelowTarget

    discard swarm.addPeer(PeerId.example, BlockAvailability.complete())
    discard swarm.addPeer(PeerId.example, BlockAvailability.complete())
    discard swarm.addPeer(PeerId.example, BlockAvailability.complete())
    check swarm.peersNeeded() == shHealthy

  test "Should replace the unknown peer seen longest ago":
    let config =
      SwarmConfig(deltaMin: 1, deltaMax: 2, deltaTarget: 2, maxPeerFailures: 3)
    swarm = Swarm.new(config)

    let
      older = PeerId.example
      newer = PeerId.example
      joining = PeerId.example
    discard swarm.addPeer(older, BlockAvailability.unknown())
    discard swarm.addPeer(newer, BlockAvailability.unknown())
    swarm.getPeer(older).get().lastSeen = Moment.now() - 10.seconds

    check swarm.replaceUnknownPeer(
      joining, BlockAvailability.complete(), initHashSet[PeerId]()
    )
    check swarm.getPeer(older).isNone
    check swarm.getPeer(newer).isSome
    check swarm.getPeer(joining).isSome

  test "Should not replace a peer with a batch in flight":
    let config =
      SwarmConfig(deltaMin: 1, deltaMax: 2, deltaTarget: 2, maxPeerFailures: 3)
    swarm = Swarm.new(config)

    let
      busyPeer = PeerId.example
      idlePeer = PeerId.example
      joining = PeerId.example
    discard swarm.addPeer(busyPeer, BlockAvailability.unknown())
    discard swarm.addPeer(idlePeer, BlockAvailability.unknown())
    swarm.getPeer(busyPeer).get().lastSeen = Moment.now() - 10.seconds

    check swarm.replaceUnknownPeer(
      joining, BlockAvailability.complete(), [busyPeer].toHashSet
    )
    check swarm.getPeer(busyPeer).isSome
    check swarm.getPeer(idlePeer).isNone
    check swarm.getPeer(joining).isSome

  test "Should not let a banned peer replace an unknown one":
    let config =
      SwarmConfig(deltaMin: 1, deltaMax: 1, deltaTarget: 1, maxPeerFailures: 3)
    swarm = Swarm.new(config)

    let
      unknownPeer = PeerId.example
      banned = PeerId.example
    discard swarm.addPeer(unknownPeer, BlockAvailability.unknown())
    swarm.banPeer(banned)

    check not swarm.replaceUnknownPeer(
      banned, BlockAvailability.complete(), initHashSet[PeerId]()
    )
    check swarm.getPeer(unknownPeer).isSome
    check swarm.getPeer(banned).isNone

suite "BDP Peer Selection":
  var peerCtxs: seq[PeerContext]

  setup:
    peerCtxs = @[]
    for i in 0 ..< 5:
      let ctx = PeerContext.new(PeerId.example)
      peerCtxs.add(ctx)

  test "Should return none for empty peers":
    var
      emptyTracker = PeerInFlightTracker.new()
      emptyPenalties = initTable[PeerId, float]()
    let res = selectByBDP(@[], TestBatchBytes, emptyTracker, emptyPenalties)
    check res.isNone

  test "Should return single peer":
    var
      emptyTracker = PeerInFlightTracker.new()
      emptyPenalties = initTable[PeerId, float]()
    let res = selectByBDP(@[peerCtxs[0]], TestBatchBytes, emptyTracker, emptyPenalties)
    check res.isSome
    check res.get == peerCtxs[0]

  test "Should prefer untried peers (round-robin)":
    for peer in peerCtxs:
      check peer.stats.throughputBps().isNone

    var
      emptyTracker = PeerInFlightTracker.new()
      emptyPenalties = initTable[PeerId, float]()
    let res = selectByBDP(peerCtxs, TestBatchBytes, emptyTracker, emptyPenalties)
    check res.isSome

  test "Should select peer with capacity":
    peerCtxs[0].stats.recordRequest(1000, 65536)
    peerCtxs[1].stats.recordRequest(1000, 65536)

    var
      tracker = PeerInFlightTracker.new()
      emptyPenalties = initTable[PeerId, float]()
    for i in 0 ..< 10:
      tracker.track(peerCtxs[1].id, newFuture[void]())

    let res = selectByBDP(peerCtxs, TestBatchBytes, tracker, emptyPenalties)
    check res.isSome

  test "Should deprioritize peer with timeout penalty":
    peerCtxs[0].stats.recordRequest(1000, 65536)
    peerCtxs[1].stats.recordRequest(1000, 65536)
    waitFor sleepAsync(MinThroughputDuration)
    peerCtxs[0].stats.recordRequest(1000, 65536)
    peerCtxs[1].stats.recordRequest(1000, 65536)

    check peerCtxs[0].stats.throughputBps().isSome
    check peerCtxs[1].stats.throughputBps().isSome

    var
      emptyTracker = PeerInFlightTracker.new()
      penalties = initTable[PeerId, float]()
    penalties[peerCtxs[0].id] = 1.0 * TimeoutPenaltyWeight

    let res = selectByBDP(
      @[peerCtxs[0], peerCtxs[1]],
      TestBatchBytes,
      emptyTracker,
      penalties,
      explorationProb = 0.0,
    )
    check res.isSome
    check res.get == peerCtxs[1]

  test "Should still select penalized peer when only option":
    peerCtxs[0].stats.recordRequest(1000, 65536)
    waitFor sleepAsync(MinThroughputDuration)
    peerCtxs[0].stats.recordRequest(1000, 65536)

    var
      emptyTracker = PeerInFlightTracker.new()
      penalties = initTable[PeerId, float]()
    penalties[peerCtxs[0].id] = 3.0 * TimeoutPenaltyWeight

    let res = selectByBDP(@[peerCtxs[0]], TestBatchBytes, emptyTracker, penalties)
    check res.isSome
    check res.get == peerCtxs[0]

  test "Should prefer peer with fewer timeouts":
    peerCtxs[0].stats.recordRequest(1000, 65536)
    peerCtxs[1].stats.recordRequest(1000, 65536)
    waitFor sleepAsync(MinThroughputDuration)
    peerCtxs[0].stats.recordRequest(1000, 65536)
    peerCtxs[1].stats.recordRequest(1000, 65536)

    var
      emptyTracker = PeerInFlightTracker.new()
      penalties = initTable[PeerId, float]()
    penalties[peerCtxs[0].id] = 2.0 * TimeoutPenaltyWeight
    penalties[peerCtxs[1].id] = 1.0 * TimeoutPenaltyWeight

    let res = selectByBDP(
      @[peerCtxs[0], peerCtxs[1]],
      TestBatchBytes,
      emptyTracker,
      penalties,
      explorationProb = 0.0,
    )
    check res.isSome
    check res.get == peerCtxs[1]
