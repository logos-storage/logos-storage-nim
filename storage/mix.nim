import pkg/libp2p_mix_transport
import pkg/libp2p_mix/mix_node
import pkg/libp2p/[multiaddress, peerid]
import pkg/results
import pkg/libp2p_mix_transport/address/parse
import ./downloadtransport

export libp2p_mix_transport, downloadtransport

func mixAddresses*(
    peer: PeerId, addresses: openArray[MultiAddress]
): seq[MultiAddress] =
  ## Retain only Mix addresses whose embedded identity matches the provider.
  for address in addresses:
    if MixPubInfo.fromMixAddress(address, Opt.some(peer)).isOk:
      result.add(address)

proc directAddresses*(addresses: openArray[MultiAddress]): seq[MultiAddress] =
  ## A Mix advertisement is not an ordinary address to pass to Switch.dial.
  for address in addresses:
    if not address.isMTAddress:
      result.add(address)
