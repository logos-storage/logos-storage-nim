import pkg/libp2p
import pkg/storage/rng as storage_rng

proc newStandardSwitch*(
    transportFlags: set[ServerFlags] = {},
    sendSignedPeerRecord = false,
    addrs: MultiAddress =
      MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("invalid multiaddress"),
    maxConnections = 0,
    privateKey = Opt.none(PrivateKey),
): Switch =
  var builder = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(@[addrs])
    .withWildcardResolver(true)
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withIdentifyPusher(false)
    .withRng(storage_rng.Rng.instance().libp2pRng)
    .withNoise()
    .withMplex()
    .withTcpTransport(transportFlags)
  if maxConnections > 0:
    builder = builder.withMaxConnections(maxConnections)
  builder.build()

proc examplePeerInfo*(): PeerInfo =
  let switch = newStandardSwitch()
  switch.peerInfo.addrs =
    @[MultiAddress.init("/ip4/127.0.0.1/tcp/4001").expect("valid")]
  switch.peerInfo
