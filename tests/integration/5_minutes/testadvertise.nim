from pkg/libp2p import `==`, `$`, Cid
import pkg/questionable/results
import ../twonodes

twonodessuite "Advertise":
  test "upload is advertised by default", twoNodesConfig:
    let cid = (await client1.upload("some file contents")).get

    check (await client1.getAdvertise(cid)).get

  test "upload with advertise false is not advertised", twoNodesConfig:
    let cid = (await client1.upload("some file contents", advertise = false)).get

    check not (await client1.getAdvertise(cid)).get

  test "toggle advertise state", twoNodesConfig:
    let cid = (await client1.upload("some file contents")).get

    (await client1.setAdvertise(cid, false)).get
    check not (await client1.getAdvertise(cid)).get

    (await client1.setAdvertise(cid, true)).get
    check (await client1.getAdvertise(cid)).get

  test "advertise state survives a node restart", twoNodesConfig:
    let cid = (await client1.upload("some file contents", advertise = false)).get

    await node1.restart()

    check not (await node1.client.getAdvertise(cid)).get

  test "advertise state is removed with the deleted dataset", twoNodesConfig:
    let cid = (await client1.upload("some file contents", advertise = false)).get

    (await client1.delete(cid)).get

    check (await client1.getAdvertise(cid)).isErr

  test "peers cannot download a dataset that is not advertised", twoNodesConfig:
    let cid = (await client1.upload("some file contents", advertise = false)).get

    check (await client2.downloadManifestOnly(cid)).isErr
