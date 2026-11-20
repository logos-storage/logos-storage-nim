import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/protocols/kademlia
import storage/discovery

import ./switchutils

type
  TestNode* = object
    switch*: Switch
    disc*: Discovery

  TestNodes* = ref object
    ## The nodes a test starts, so that its teardown can stop them
    started: seq[TestNode]

proc startNode*(
    nodes: TestNodes,
    isServer: bool,
    bootstrap: seq[TestNode] = @[],
    validator: EntryValidator = DefaultEntryValidator(),
    selector: EntrySelector = DefaultEntrySelector(),
): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
  let
    switch = newStandardSwitch()
    bootstrapPeers =
      bootstrap.mapIt((it.switch.peerInfo.peerId, it.switch.peerInfo.addrs))
    disc = Discovery.new(
      switch,
      bootstrapNodes = bootstrapPeers,
      isServer = isServer,
      validator = validator,
      selector = selector,
    )

  switch.mount(disc.kad)

  await switch.start()

  let node = TestNode(switch: switch, disc: disc)
  nodes.started.add(node)

  node

proc stop*(nodes: TestNodes) {.async: (raises: [CancelledError]).} =
  for node in nodes.started:
    await node.switch.stop()

  nodes.started = @[]
