import pkg/chronos
import pkg/libp2p except setup
import pkg/datastore
import pkg/questionable/results

import ../../asynctest
import ../../checktest
import ../helpers
import ../helpers/mockclock
import ../helpers/failingdatastore
import ../examples
import ./namenodes
import ../../../storage/discovery
import ../../../storage/namespaces
import ../../../storage/naming/record
import ../../../storage/naming/dht
import ../../../storage/naming/publisher {.all.}

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64
  oneHour = 60 * 60

asyncchecksuite "Name publisher":
  var
    publishers: seq[NamePublisher]
    clock: MockClock
    server: TestNode
    bootstrapNodes: seq[TestNode]
    metaDs: Datastore
    publisher: NamePublisher

  let
    nodes = TestNodes()
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    cid = Cid.example
    otherCid = Cid.example

  teardown:
    for startedPublisher in publishers:
      await startedPublisher.stop()

    publishers = @[]

    await nodes.stop()

  proc newMetaDs(): Datastore =
    SQLiteDatastore.new(Memory).tryGet()

  proc newPublisher(
      node: TestNode,
      metaDs: Datastore,
      clock: Clock,
      signingKey: PrivateKey = privateKey,
  ): NamePublisher =
    let publisher = NamePublisher.new(node.disc, metaDs, signingKey, clock)
    publishers.add(publisher)

    publisher

  proc nameKeyFromLabel(label: string): seq[byte] =
    nameKey(name(publicKey, label).tryGet())

  # Reads the name record of a label from the DHT and validates it
  proc getFromDht(
      node: TestNode, label: string
  ): Future[SignedNameRecord] {.async: (raises: [CancelledError, CatchableError]).} =
    let key = nameKeyFromLabel(label)

    let bytes = (await node.disc.getValue(key)).tryGet()

    validate(name(publicKey, label).tryGet(), bytes, clock.now()).tryGet()

  # Expiration of the name record of a label in the DHT, 0 when there is none
  proc getExpiration(
      node: TestNode, label: string
  ): Future[int64] {.async: (raises: [CancelledError, CatchableError]).} =
    let bytes = (await node.disc.getValue(nameKeyFromLabel(label))).valueOr:
      return 0

    let signed = validate(name(publicKey, label).tryGet(), bytes, clock.now()).valueOr:
      return 0

    signed.data.expiration

  setup:
    clock = MockClock.new(currentTime)

    server = await nodes.startNode(clock, isServer = true)
    bootstrapNodes = @[server]
    metaDs = newMetaDs()
    publisher = newPublisher(server, metaDs, clock)

  test "publishes with the current time as seqnum by default":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.data.version == NameRecordVersion
    check signed.data.label == "catalog"
    check signed.data.cid == cid
    check signed.data.seqnum == currentTime.uint64

  test "publishes with the given seqnum":
    let seqnum = 7'u64

    let signed =
      (await publisher.publish("catalog", cid, seqnum = Opt.some(seqnum))).tryGet()

    check signed.data.seqnum == seqnum

  test "the expiration is 8 hours after the current time":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.data.expiration == currentTime + NameRecordLifetime
    check signed.data.expiration == currentTime + 8 * 60 * 60

  test "the name record is signed with the private key of the publisher":
    let signed = (await publisher.publish("catalog", cid)).tryGet()

    check signed.envelope.publicKey == publicKey
    check name(signed) == name(publicKey, "catalog").tryGet()

  test "the publisher advertises the name record under the name key":
    let
      published = (await publisher.publish("catalog", cid)).tryGet()
      nameKey = nameKeyFromLabel("catalog")

    let bytes = (await server.disc.getValue(nameKey)).tryGet()

    check bytes == published.encode()

  test "refuses a seqnum lower than the stored one":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let refused = await publisher.publish("catalog", otherCid, Opt.some(9'u64))

    check refused.isErr

    # The DHT still holds the first name record
    let read = await reader.getFromDht("catalog")

    check read.data.seqnum == 10'u64
    check read.data.cid == cid

  test "accepts the same CID for an existing seqnum":
    check (await publisher.publish("catalog", cid, Opt.some(10'u64))).isOk

    let again = await publisher.publish("catalog", cid, Opt.some(10'u64))

    check again.isOk
    check again.tryGet().data.seqnum == 10'u64

  test "refuses a different CID for an existing seqnum":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(42'u64))).isOk

    let refused = await publisher.publish("catalog", otherCid, Opt.some(42'u64))

    check refused.isErr

    # The DHT still holds the first name record
    let read = await reader.getFromDht("catalog")

    check read.data.seqnum == 42'u64
    check read.data.cid == cid

  test "succeeds and keeps the name record stored when advertising it fails":
    # The publisher is a fresh node that lost its previous name record,
    # with seqnum 10.
    # Advertising fails because the DHT has a newer name record, but the name
    # record stays stored locally.
    let
      newer = NameRecord(
        version: NameRecordVersion,
        label: "catalog",
        cid: otherCid,
        seqnum: 10'u64,
        expiration: currentTime + oneHour,
      )
      newerBytes = newer.sign(privateKey).tryGet().encode()

    check (await server.disc.putValue(nameKeyFromLabel("catalog"), newerBytes)).isOk
    check (await publisher.publish("catalog", cid, Opt.some(5'u64))).isOk

    let stored = (await publisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].data.cid == cid
    check stored[0].data.seqnum == 5'u64

  test "publish returns an error when reading the stored name record fails":
    let
      failingDs = FailingDatastore.new(newMetaDs())
      failingPublisher = newPublisher(server, failingDs, clock)

    failingDs.failGet = true

    check (await failingPublisher.publish("catalog", cid)).isErr

  test "publish returns an error when the stored name record doesn't decode":
    let key = persistenceKeyFromName(name(publicKey, "catalog").tryGet())

    check (await metaDs.put(key, @[0xAB'u8, 0xCD])).isOk
    check (await publisher.publish("catalog", cid)).isErr

  test "publish returns an error and advertises nothing when storing fails":
    let
      failingDs = FailingDatastore.new(newMetaDs())
      failingPublisher = newPublisher(server, failingDs, clock)

    failingDs.failPut = true

    check (await failingPublisher.publish("catalog", cid)).isErr
    check (await server.disc.getValue(nameKeyFromLabel("catalog"))).isErr

  test "refuses an empty label":
    check (await publisher.publish("", cid)).isErr

  test "refuses a cid longer than 128 bytes":
    # 4 bytes of header and 125 bytes of digest: a CID of 129 bytes
    let
      hash = MultiHash.digest("identity", newSeq[byte](125)).tryGet()
      longCid = Cid.init(CIDv1, multiCodec("raw"), hash).tryGet()

    check (await publisher.publish("catalog", longCid)).isErr

  test "unpublish deletes the name record":
    check (await publisher.publish("catalog", cid)).isOk

    check (await publisher.unpublish("catalog")).isOk
    check (await publisher.getNameRecords()).tryGet().len == 0

  test "unpublish keeps the other labels":
    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", cid)).isOk

    check (await publisher.unpublish("catalog")).isOk

    let stored = (await publisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].data.label == "release"

  test "unpublish refuses an empty label":
    check (await publisher.unpublish("")).isErr

  test "unpublish returns an error when deleting fails":
    let
      failingDs = FailingDatastore.new(newMetaDs())
      failingPublisher = newPublisher(server, failingDs, clock)

    check (await failingPublisher.publish("catalog", cid)).isOk

    failingDs.failDelete = true

    check (await failingPublisher.unpublish("catalog")).isErr

  test "republishAll extends the expiration with the same CID and seqnum":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)
    let seqnum = 3'u64

    let published = (await publisher.publish("catalog", cid, Opt.some(seqnum))).tryGet()

    clock.advance(oneHour)

    await publisher.republishAll()

    let read = await reader.getFromDht("catalog")

    check read.data.cid == cid
    check read.data.seqnum == seqnum
    check read.data.expiration == currentTime + oneHour + NameRecordLifetime
    check read.data.expiration > published.data.expiration
    check read.envelope.publicKey == publicKey

  test "republishAll republishes every stored name record":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", otherCid)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    let
      catalog = await reader.getFromDht("catalog")
      release = await reader.getFromDht("release")

    check catalog.data.expiration == currentTime + oneHour + NameRecordLifetime
    check release.data.expiration == currentTime + oneHour + NameRecordLifetime

  test "start republishes the stored name records right away after a restart":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)
    let seqnum = 3'u64

    check (await publisher.publish("catalog", cid, Opt.some(seqnum))).isOk

    await publisher.stop()

    clock.advance(oneHour)

    let after = newPublisher(server, metaDs, clock)
    after.start()

    let expected = currentTime + oneHour + NameRecordLifetime

    check eventually(
      (await reader.getExpiration("catalog")) == expected, timeout = 10_000
    )

  test "republishAll keeps going when one name record fails":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid)).isOk
    check (await publisher.publish("release", cid)).isOk

    # Make the name record that republishAll reads first fail, then check that
    # republishAll goes on to the next one
    let
      stored = (await publisher.getNameRecords()).tryGet()
      failingLabel = stored[0].data.label
      nextLabel = stored[1].data.label

    # The DHT holds a newer name record for this label, so advertising it fails
    let
      newer = NameRecord(
        version: NameRecordVersion,
        label: failingLabel,
        cid: otherCid,
        seqnum: currentTime.uint64 + 10,
        expiration: currentTime + oneHour,
      )
      newerBytes = newer.sign(privateKey).tryGet().encode()

    check (await server.disc.putValue(nameKeyFromLabel(failingLabel), newerBytes)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    check (await reader.getExpiration(nextLabel)) ==
      currentTime + oneHour + NameRecordLifetime

  test "republishAll skips the name records signed by another key":
    let
      reader =
        await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)
      otherKey = PrivateKey.example
      otherPublicKey = otherKey.getPublicKey().tryGet()
      otherPublisher = newPublisher(server, metaDs, clock, otherKey)

    check (await publisher.publish("catalog", cid)).isOk

    await otherPublisher.republishAll()

    # The name record of the other key is not in the DHT
    let otherNameKey = nameKey(name(otherPublicKey, "catalog").tryGet())

    check (await reader.disc.getValue(otherNameKey)).isErr

    # The name record is persisted in the store
    let stored = (await otherPublisher.getNameRecords()).tryGet()

    check stored.len == 1
    check stored[0].envelope.publicKey == publicKey

  test "republishAll advertises nothing when reading the stored name records fails":
    let
      failingDs = FailingDatastore.new(newMetaDs())
      failingPublisher = newPublisher(server, failingDs, clock)

    let published = (await failingPublisher.publish("catalog", cid)).tryGet()

    failingDs.failQuery = true
    clock.advance(oneHour)

    await failingPublisher.republishAll()

    # The DHT still holds the expiration of the publication
    check (await server.getExpiration("catalog")) == published.data.expiration

  test "republishAll republishes the name records read before a read error":
    let
      failingDs = FailingDatastore.new(newMetaDs())
      failingPublisher = newPublisher(server, failingDs, clock)

    check (await failingPublisher.publish("catalog", cid)).isOk

    failingDs.failSecondNext = true
    clock.advance(oneHour)

    await failingPublisher.republishAll()

    check (await server.getExpiration("catalog")) ==
      currentTime + oneHour + NameRecordLifetime

  test "republishAll skips a stored name record that doesn't decode":
    # The query reads the keys in order, and "0" comes before the hex keys of
    # the names, so republishAll reads this name record first
    let key = Key.init(StorageNamesNamespace & "/0").tryGet()

    check (await metaDs.put(key, @[0xAB'u8, 0xCD])).isOk
    check (await publisher.publish("catalog", cid)).isOk

    clock.advance(oneHour)

    await publisher.republishAll()

    check (await server.getExpiration("catalog")) ==
      currentTime + oneHour + NameRecordLifetime

  test "the loop republishes every 4 hours":
    let reader =
      await nodes.startNode(clock, isServer = false, bootstrap = bootstrapNodes)

    check (await publisher.publish("catalog", cid, Opt.some(3'u64))).isOk

    publisher.start()

    # Ensure that the republish loop is actually a loop
    for round in 1 .. 2:
      # Wait until the loop waits for the next republish
      check eventually(clock.isWaiting, timeout = 10_000)

      clock.advance(RepublishInterval)

      let expected = currentTime + round * RepublishInterval + NameRecordLifetime

      check eventually(
        (await reader.getExpiration("catalog")) == expected, timeout = 10_000
      )

  test "stop stops the loop":
    publisher.start()

    check eventually(clock.isWaiting, timeout = 10_000)

    await publisher.stop()

    check not clock.isWaiting

  test "a second start keeps the running loop":
    publisher.start()

    check eventually(clock.isWaiting, timeout = 10_000)

    publisher.start()

    await publisher.stop()

    # stop cancels one loop: a second loop would still wait for the clock
    check not eventually(clock.isWaiting, timeout = 1_000)

  test "start after stop starts the loop again":
    publisher.start()

    check eventually(clock.isWaiting, timeout = 10_000)

    await publisher.stop()

    publisher.start()

    check eventually(clock.isWaiting, timeout = 10_000)
