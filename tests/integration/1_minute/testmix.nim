import std/json
import std/sequtils

import pkg/libp2p/[multiaddress, peerid]
import pkg/libp2p_mix
import pkg/libp2p_mix_transport/address/parse
import pkg/questionable/results
import pkg/results

import ../multinodes
import ../nat/composehelper

multinodesuite "Mix startup":
  # We can only test the extip path here as non-extip requires public addresses.
  test "should publish a mix address when Mix is enabled and nat:extip is set",
    NodeConfigs(
      clients: StorageConfigs
        .init(nodes = 2)
        .withExtIp(1, "127.0.0.1")
        .withListenPort(1, 40401)
        .withMixEnabled().some
    ):
    check eventuallyInfo(
      clients()[1].client, info{"addrs"}.getElems.anyIt("mix-transport" in it.getStr)
    )

    let
      info = (await clients()[1].client.info()).get
      mixAddresses = info{"addrs"}.getElems.filterIt("mix-transport" in it.getStr)

    check mixAddresses.len == 1

    let
      mixAddress = mixAddresses[0].getStr
      mixInfo = MixPubInfo.fromMixAddress(
        MultiAddress.init(mixAddress).get, Opt.none(PeerId)
      ).get

    check mixInfo.multiAddr == MultiAddress.init("/ip4/127.0.0.1/tcp/40401").get

  test "a nat:auto node starts with Mix enabled",
    NodeConfigs(clients: StorageConfigs.init(nodes = 2).withMixEnabled().some):
    let info = (await clients()[1].client.info()).get

    check info["mixPubKey"].getStr().len > 0
