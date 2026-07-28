## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/storage/discovery

type MockDiscovery* = ref object of Discovery
  findBlockProvidersHandler*: proc(d: MockDiscovery, cid: Cid): Future[seq[PeerRecord]] {.
    async: (raises: [CancelledError])
  .}

  publishBlockProvideHandler*:
    proc(d: MockDiscovery, cid: Cid): Future[void] {.async: (raises: [CancelledError]).}

proc new*(T: type MockDiscovery): MockDiscovery =
  MockDiscovery()

proc findPeer*(
    d: Discovery, peerId: PeerId
): Future[?PeerRecord] {.async: (raises: [CancelledError]).} =
  ## mock find a peer - always return none
  ##
  return none(PeerRecord)

method find*(
    d: MockDiscovery, cid: Cid
): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  if isNil(d.findBlockProvidersHandler):
    return

  return await d.findBlockProvidersHandler(d, cid)

method provide*(
    d: MockDiscovery, cid: Cid
): Future[void] {.async: (raises: [CancelledError]).} =
  if isNil(d.publishBlockProvideHandler):
    return

  await d.publishBlockProvideHandler(d, cid)

proc nullDiscovery*(): MockDiscovery =
  proc findBlockProvidersHandler(
      d: MockDiscovery, cid: Cid
  ): Future[seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
    return @[]

  proc publishBlockProvideHandler(
      d: MockDiscovery, cid: Cid
  ): Future[void] {.async: (raises: [CancelledError]).} =
    return

  return MockDiscovery(
    findBlockProvidersHandler: findBlockProvidersHandler,
    publishBlockProvideHandler: publishBlockProvideHandler,
  )

# Slightly more contrived Discovery mock to allow testing of the privacy toggle.
# Since we cannot declare `method` within blocks, we have to do this contortionism
# here.
type MixMockDiscovery* = ref object of Discovery
  privateRecord*: PeerRecord
  directRecord*: PeerRecord
  refCid*: Cid

proc new*(T: type MixMockDiscovery): MixMockDiscovery =
  MixMockDiscovery()

method findViaMix*(
    d: MixMockDiscovery, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  doAssert cid == d.refCid
  result = success(@[d.privateRecord])

method findDirect*(
    d: MixMockDiscovery, cid: Cid
): Future[?!seq[PeerRecord]] {.async: (raises: [CancelledError]).} =
  doAssert cid == d.refCid
  result = success(@[d.directRecord])
