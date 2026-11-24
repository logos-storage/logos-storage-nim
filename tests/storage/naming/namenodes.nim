import pkg/chronos
import pkg/libp2p

import storage/clock
import storage/naming/dht
import ../helpers/testnodes

export testnodes

proc startNode*(
    nodes: TestNodes, clock: Clock, isServer: bool, bootstrap: seq[TestNode] = @[]
): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
  ## Starts a node whose DHT keeps only the valid name records
  return await nodes.startNode(
    isServer, bootstrap, NameRecordValidatorRef(clock: clock), NameRecordSelectorRef()
  )
