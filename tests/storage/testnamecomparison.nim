import pkg/libp2p
import pkg/libp2p/protocols/kademlia
import pkg/questionable/results

import pkg/unittest2

import ../checktest
import ./examples
import ./helpers/mockclock
import ../../storage/naming/record
import ../../storage/naming/dht

const
  # 10:00:00 UTC on 11 November 2026
  currentTime = 1794391200'i64
  # 10:00:00 UTC on 12 November 2026
  tenOClock = 1794477600'i64
  # 14:00:00 UTC on 12 November 2026
  twoOClock = 1794492000'i64

proc newRecord(seqnum: uint64, expiration: int64, label = "catalog"): NameRecord =
  NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: Cid.example,
    seqnum: seqnum,
    expiration: expiration,
  )

checksuite "Name record selector":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    key = @(name(publicKey, "catalog").tryGet())
    selector = NameRecordSelector()

  proc signedBytes(seqnum: uint64, expiration: int64): seq[byte] =
    let signed = SignedNameRecord.init(privateKey, newRecord(seqnum, expiration))

    signed.tryGet().encode()

  test "selects the newest name record wherever it is in the list":
    let
      newest = EntryRecord(value: signedBytes(43'u64, tenOClock))
      older = EntryRecord(value: signedBytes(42'u64, twoOClock))
      oldest = EntryRecord(value: signedBytes(41'u64, twoOClock))

    check selector.select(key, @[newest, older, oldest]).tryGet() == 0
    check selector.select(key, @[older, newest, oldest]).tryGet() == 1
    check selector.select(key, @[oldest, older, newest]).tryGet() == 2

  test "the received name record replaces the stored one when seqnums are equal":
    let
      expiresEarlier = EntryRecord(value: signedBytes(42'u64, tenOClock))
      expiresLater = EntryRecord(value: signedBytes(42'u64, twoOClock))

    check selector.select(key, @[expiresEarlier, expiresLater]).tryGet() == 0
    check selector.select(key, @[expiresLater, expiresEarlier]).tryGet() == 0

  test "skips a name record that doesn't decode":
    let
      undecodable = EntryRecord(value: @[1'u8, 2, 3])
      older = EntryRecord(value: signedBytes(41'u64, twoOClock))
      valid = EntryRecord(value: signedBytes(42'u64, tenOClock))

    check selector.select(key, @[undecodable, valid]).tryGet() == 1
    check selector.select(key, @[older, undecodable, valid]).tryGet() == 2

  test "fails when no name record decodes":
    let undecodable = EntryRecord(value: @[1'u8, 2, 3])

    check selector.select(key, @[undecodable, undecodable]).isErr

  test "fails on an empty list":
    check selector.select(key, newSeq[EntryRecord]()).isErr

checksuite "Name record validator":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    catalogName = name(publicKey, "catalog").tryGet()
    key = nameKey(catalogName)

  proc signedBytes(label = "catalog", expiration = currentTime + 3600): seq[byte] =
    let signed = SignedNameRecord.init(privateKey, newRecord(42'u64, expiration, label))

    signed.tryGet().encode()

  proc cidKey(codec: MultiCodec, hashCodec: MultiCodec, digest: seq[byte]): seq[byte] =
    let
      hash = MultiHash.init(hashCodec, digest).tryGet()
      cid = Cid.init(CIDv1, codec, hash).tryGet()

    cid.data.buffer

  test "nameFromNameKey gives back the name of nameKey":
    check nameFromNameKey(key).tryGet() == catalogName

  test "the key is a CIDv1 with the storage-name codec and a SHA2-256 multihash":
    let
      cid = Cid.init(key).tryGet()
      hash = cid.mhash().tryGet()

    check cid.version == CIDv1
    check cid.mcodec == multiCodec("storage-name")
    check hash.mcodec == multiCodec("sha2-256")
    check hash.data.buffer[hash.dpos ..< hash.dpos + hash.size] == @catalogName

  test "accepts a valid name record under the name key":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check validator.isValid(key, EntryRecord(value: signedBytes()))

  test "refuses a key that is not a CID":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key[0 ..< 5], EntryRecord(value: signedBytes()))

  test "refuses a CIDv1 with the right digest and another codec":
    let
      validator = NameRecordValidator(clock: MockClock.new(currentTime))
      otherKey = cidKey(multiCodec("raw"), multiCodec("sha2-256"), @catalogName)

    check nameFromNameKey(otherKey).isErr
    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a CID with the right codec and another hash function":
    let
      validator = NameRecordValidator(clock: MockClock.new(currentTime))
      otherKey =
        cidKey(multiCodec("storage-name"), multiCodec("blake2b-256"), @catalogName)

    check nameFromNameKey(otherKey).isErr
    check not validator.isValid(otherKey, EntryRecord(value: signedBytes()))

  test "refuses a valid name record stored under the name of another label":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key, EntryRecord(value: signedBytes(label = "release")))

  test "refuses a name record once the clock is past its expiration":
    let
      clock = MockClock.new(currentTime)
      validator = NameRecordValidator(clock: clock)
      record = EntryRecord(value: signedBytes(expiration = currentTime + 3600))

    check validator.isValid(key, record)

    clock.set(currentTime + 3601)

    check not validator.isValid(key, record)
