import pkg/unittest2
import pkg/libp2p/peerid
import pkg/storage/blockexchange/engine/activedownload
import ../../examples

suite "Presence queries and swarm admission":
  var download: ActiveDownload
  var peer: PeerId

  setup:
    var config = SwarmConfig.defaultConfig()
    config.deltaMax = 1
    download = ActiveDownload(ctx: DownloadContext(swarm: Swarm.new(config)))
    peer = PeerId.example

  test "Default queries a new peer even when the swarm is full":
    check download.ctx.swarm.addPeer(PeerId.example, BlockAvailability.unknown())
    check download.addPeerIfAbsent(peer, BlockAvailability.unknown())
    check download.ctx.swarm.getPeer(peer).isNone

  test "Admission-only policy skips a new peer when the swarm is full":
    check download.ctx.swarm.addPeer(PeerId.example, BlockAvailability.unknown())
    check not download.addPeerIfAbsent(
      peer, BlockAvailability.unknown(), PresenceQueryPolicy.QueryAdmittedPeers
    )
    check download.ctx.swarm.getPeer(peer).isNone

  test "Policies differ for a banned peer without changing the ban":
    download.ctx.swarm.banPeer(peer)
    check download.addPeerIfAbsent(peer, BlockAvailability.unknown())
    check not download.addPeerIfAbsent(
      peer, BlockAvailability.unknown(), PresenceQueryPolicy.QueryAdmittedPeers
    )
    check download.ctx.swarm.getPeer(peer).isNone

  test "Both policies admit and query a new peer when capacity is available":
    for policy in PresenceQueryPolicy:
      check download.addPeerIfAbsent(peer, BlockAvailability.unknown(), policy)
      check download.ctx.swarm.getPeer(peer).isSome
      discard download.ctx.swarm.removePeer(peer)

  test "Both policies query an existing incomplete peer in a full swarm":
    check download.ctx.swarm.addPeer(peer, BlockAvailability.unknown())
    for policy in PresenceQueryPolicy:
      check download.addPeerIfAbsent(peer, BlockAvailability.unknown(), policy)

  test "Both policies skip an existing complete peer":
    check download.ctx.swarm.addPeer(peer, BlockAvailability.complete())
    for policy in PresenceQueryPolicy:
      check not download.addPeerIfAbsent(peer, BlockAvailability.unknown(), policy)
