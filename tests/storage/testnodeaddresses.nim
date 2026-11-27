import std/os
import std/sequtils

import pkg/libp2p_mix
import pkg/libp2p_mix_transport/address/parse
import pkg/libp2p/crypto/crypto
import ../../storage/rng as storage_rng
import pkg/chronos
import pkg/confutils
import pkg/questionable/results

import ../asynctest
import ./helpers
import ./examples
import ../../storage/conf
import ../../storage/discovery
import ../../storage/node
import ../../storage/storage
import ../../storage/utils/spr

suite "StorageServer - extip":
  let dataDir = getTempDir() / "StorageServerTest"

  setup:
    createDir(dataDir / "repo")

  teardown:
    removeDir(dataDir)

  test "an extip node only announces its extip address during the startup":
    let
      port = await nextFreePort(40500)
      config = StorageConf.load(
        cmdLine =
          @["--data-dir=" & dataDir, "--nat=extip:7.7.7.2", "--listen-port=" & $port],
        quitOnFailure = false,
      )
      server = StorageServer.new(config, PrivateKey.example)

    var announced: seq[seq[string]]
    server.node.switch.peerInfo.addObserver(
      proc(p: PeerInfo) {.gcsafe, raises: [].} =
        announced.add(p.addrs.mapIt($it))
    )

    await server.start()
    await server.stop()
    await server.close()

    check announced.deduplicate() == @[@["/ip4/7.7.7.2/tcp/" & $port]]

  test "a startup observer sees the signed extip Mix address already in the live identity":
    let
      port = await nextFreePort(40500)
      config = StorageConf.load(
        cmdLine = @[
          "--data-dir=" & dataDir,
          "--nat=extip:7.7.7.2",
          "--listen-port=" & $port,
          "--mix-enabled=true",
        ],
        quitOnFailure = false,
      )
      key = PrivateKey.random(Secp256k1, storage_rng.Rng.instance().libp2pRng).tryGet()
      server = StorageServer.new(config, key)

    var published: seq[MultiAddress]
    server.node.switch.peerInfo.addObserver(
      proc(p: PeerInfo) {.gcsafe, raises: [].} =
        for entry in p.signedPeerRecord.data.addresses:
          if entry.address.isMTAddress():
            let live =
              server.node.discovery.mixProto.localMixPubInfo.expect("Mix identity")
            doAssert entry.address == live.toMixAddress().expect("live Mix address")
            published.add(live.multiAddr)
    )

    await server.start()
    await server.stop()
    await server.close()
    check published.mapIt($it).deduplicate() == @["/ip4/7.7.7.2/tcp/" & $port]

suite "StorageServer - Kad address policy":
  let
    dataDir = getTempDir() / "StorageServerTest"
    publicAddr = MultiAddress.init("/ip4/204.168.234.45/tcp/8070").expect("valid")
    privateAddr = MultiAddress.init("/ip4/10.1.0.85/tcp/8070").expect("valid")

  setup:
    createDir(dataDir / "repo")

  teardown:
    removeDir(dataDir)

  test "on a public network, the DHT only keeps the public address of a peer":
    let peer = newStandardSwitch().peerInfo
    peer.addrs = @[publicAddr, privateAddr]

    let
      config = StorageConf.load(
        cmdLine =
          @["--data-dir=" & dataDir, "--bootstrap-node=" & peer.toSpr().tryGet()],
        quitOnFailure = false,
      )
      server = StorageServer.new(config, PrivateKey.example)
      dhtAddrs = server.node.discovery.routingTable().peers[0].record.addresses.mapIt(
        $it.address
      )

    await server.close()

    check dhtAddrs == @[$publicAddr]
