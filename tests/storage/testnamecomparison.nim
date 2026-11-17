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

proc newRecord(
    sequenceNumber: uint64, expiration: int64, label = "catalog"
): NameRecord =
  NameRecord(
    version: NameRecordVersion,
    label: label,
    cid: Cid.example,
    sequenceNumber: sequenceNumber,
    expiration: expiration,
  )

checksuite "Name record selector":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    key = @(name(publicKey, "catalog").tryGet())
    selector = NameRecordSelector()

  proc signedBytes(sequenceNumber: uint64, expiration: int64): seq[byte] =
    let signed =
      SignedNameRecord.init(privateKey, newRecord(sequenceNumber, expiration))

    signed.tryGet().encode().tryGet()

  test "selects the newest record wherever it is in the list":
    let
      newest = EntryRecord(value: signedBytes(43'u64, tenOClock))
      older = EntryRecord(value: signedBytes(42'u64, twoOClock))
      oldest = EntryRecord(value: signedBytes(41'u64, twoOClock))

    check selector.select(key, @[newest, older, oldest]).tryGet() == 0
    check selector.select(key, @[older, newest, oldest]).tryGet() == 1
    check selector.select(key, @[oldest, older, newest]).tryGet() == 2

  test "selects the record that expires later when sequence numbers are equal":
    let
      expiresEarlier = EntryRecord(value: signedBytes(42'u64, tenOClock))
      expiresLater = EntryRecord(value: signedBytes(42'u64, twoOClock))

    check selector.select(key, @[expiresEarlier, expiresLater]).tryGet() == 1
    check selector.select(key, @[expiresLater, expiresEarlier]).tryGet() == 0

  test "keeps the first record when both have the same fields":
    let
      first = EntryRecord(value: signedBytes(42'u64, tenOClock))
      second = EntryRecord(value: signedBytes(42'u64, tenOClock))

    check selector.select(key, @[first, second]).tryGet() == 0

  test "skips a record that doesn't decode":
    let
      undecodable = EntryRecord(value: @[1'u8, 2, 3])
      older = EntryRecord(value: signedBytes(41'u64, twoOClock))
      valid = EntryRecord(value: signedBytes(42'u64, tenOClock))

    check selector.select(key, @[undecodable, valid]).tryGet() == 1
    check selector.select(key, @[older, undecodable, valid]).tryGet() == 2

  test "fails when no record decodes":
    let undecodable = EntryRecord(value: @[1'u8, 2, 3])

    check selector.select(key, @[undecodable, undecodable]).isErr

  test "fails on an empty list":
    check selector.select(key, newSeq[EntryRecord]()).isErr

checksuite "Name record validator":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    catalogName = name(publicKey, "catalog").tryGet()
    key = @catalogName

  proc signedBytes(label = "catalog", expiration = currentTime + 3600): seq[byte] =
    let signed = SignedNameRecord.init(privateKey, newRecord(42'u64, expiration, label))

    signed.tryGet().encode().tryGet()

  test "accepts a valid record under its name":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check validator.isValid(key, EntryRecord(value: signedBytes()))

  test "refuses a key shorter than 32 bytes":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key[0 ..< 31], EntryRecord(value: signedBytes()))

  test "refuses a key longer than 32 bytes":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key & @[0'u8], EntryRecord(value: signedBytes()))

  test "refuses a valid record stored under the name of another label":
    let validator = NameRecordValidator(clock: MockClock.new(currentTime))

    check not validator.isValid(key, EntryRecord(value: signedBytes(label = "release")))

  test "refuses a record once the clock is past its expiration":
    let
      clock = MockClock.new(currentTime)
      validator = NameRecordValidator(clock: clock)
      record = EntryRecord(value: signedBytes(expiration = currentTime + 3600))

    check validator.isValid(key, record)

    clock.set(currentTime + 3601)

    check not validator.isValid(key, record)
