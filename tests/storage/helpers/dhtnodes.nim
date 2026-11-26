import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/protocols/kademlia
import storage/clock
import storage/discovery
import storage/naming/dht

import ./switchutils

type
  TestNode* = object
    switch*: Switch
    disc*: Discovery

  TestNodes* = ref object ## The nodes a test starts, so that its teardown can stop them
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

proc startNode*(
    nodes: TestNodes, clock: Clock, isServer: bool, bootstrap: seq[TestNode] = @[]
): Future[TestNode] {.async: (raises: [CancelledError, LPError]).} =
  ## Starts a node whose DHT keeps only the valid name records
  return await nodes.startNode(
    isServer, bootstrap, NameRecordValidatorRef(clock: clock), NameRecordSelectorRef()
  )

proc stop*(nodes: TestNodes) {.async: (raises: [CancelledError]).} =
  for node in nodes.started:
    await node.switch.stop()

  nodes.started = @[]
