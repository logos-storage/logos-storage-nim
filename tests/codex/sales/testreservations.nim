import std/random
import std/times
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/datastore

import pkg/codex/stores
import pkg/codex/errors
import pkg/codex/sales
import pkg/codex/clock
import pkg/codex/utils/json

import ../../asynctest
import ../examples
import ../helpers

const CONCURRENCY_TESTS_COUNT = 1000

asyncchecksuite "Reservations module":
  var
    repo: RepoStore
    repoDs: Datastore
    metaDs: Datastore
    reservations: Reservations
    collateralPerByte: UInt256
  let
    repoTmp = TempLevelDb.new()
    metaTmp = TempLevelDb.new()

  setup:
    randomize(1.int64) # create reproducible results
    repoDs = repoTmp.newDb()
    metaDs = metaTmp.newDb()
    repo = RepoStore.new(repoDs, metaDs)
    reservations = Reservations.new(repo)
    collateralPerByte = uint8.example.u256

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  proc createAvailability(enabled = true, until = 0.SecondsSince1970): Availability =
    let example = Availability.example(collateralPerByte)
    let totalSize = rand(100000 .. 200000).uint64
    let totalCollateral = totalSize.u256 * collateralPerByte
    let availability = waitFor reservations.createAvailability(
      totalSize, example.duration, example.minPricePerBytePerSecond, totalCollateral,
      enabled, until,
    )
    return availability.get

  proc createReservation(availability: Availability): Reservation =
    let size = rand(1 ..< availability.freeSize.int)
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let reservation = waitFor reservations.createReservation(
      availability.id, size.uint64, RequestId.example, uint64.example, 1.u256,
      validUntil,
    )
    return reservation.get

  test "availability can be serialised and deserialised":
    let availability = Availability.example
    let serialised = %availability
    check Availability.fromJson(serialised).get == availability

  test "has no availability initially":
    check (await reservations.all(Availability)).get.len == 0

  test "generates unique ids for storage availability":
    let availability1 = Availability.init(
      1.uint64, 2.uint64, 3.uint64, 4.u256, 5.u256, true, 0.SecondsSince1970
    )
    let availability2 = Availability.init(
      1.uint64, 2.uint64, 3.uint64, 4.u256, 5.u256, true, 0.SecondsSince1970
    )
    check availability1.id != availability2.id

  test "can reserve available storage":
    let availability = createAvailability()
    check availability.id != AvailabilityId.default

  test "creating availability reserves bytes in repo":
    let orig = repo.available.uint
    let availability = createAvailability()
    check repo.available.uint == orig - availability.freeSize

  test "can get all availabilities":
    let availability1 = createAvailability()
    let availability2 = createAvailability()
    let availabilities = !(await reservations.all(Availability))
    check:
      # perform unordered checks
      availabilities.len == 2
      availabilities.contains(availability1)
      availabilities.contains(availability2)

  test "reserved availability exists":
    let availability = createAvailability()

    let exists = await reservations.exists(availability.key.get)

    check exists

  test "reservation can be created":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    check reservation.id != ReservationId.default

  test "can get all reservations":
    let availability1 = createAvailability()
    let availability2 = createAvailability()
    let reservation1 = createReservation(availability1)
    let reservation2 = createReservation(availability2)
    let availabilities = !(await reservations.all(Availability))
    let reservations = !(await reservations.all(Reservation))
    check:
      # perform unordered checks
      availabilities.len == 2
      reservations.len == 2
      reservations.contains(reservation1)
      reservations.contains(reservation2)

  test "can get reservations of specific availability":
    let availability1 = createAvailability()
    let availability2 = createAvailability()
    let reservation1 = createReservation(availability1)
    let reservation2 = createReservation(availability2)
    let reservations = !(await reservations.all(Reservation, availability1.id))

    check:
      # perform unordered checks
      reservations.len == 1
      reservations.contains(reservation1)
      not reservations.contains(reservation2)

  test "cannot create reservation with non-existant availability":
    let availability = Availability.example
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let created = await reservations.createReservation(
      availability.id, uint64.example, RequestId.example, uint64.example, 1.u256,
      validUntil,
    )
    check created.isErr
    check created.error of NotExistsError

  test "cannot create reservation larger than availability size":
    let availability = createAvailability()
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let created = await reservations.createReservation(
      availability.id,
      availability.totalSize + 1,
      RequestId.example,
      uint64.example,
      UInt256.example,
      validUntil,
    )
    check created.isErr
    check created.error of BytesOutOfBoundsError

  test "cannot create reservation larger than availability size - concurrency test":
    proc concurrencyTest(): Future[void] {.async.} =
      let availability = createAvailability()
      let validUntil = getTime().toUnix() + 30.SecondsSince1970
      let one = reservations.createReservation(
        availability.id,
        availability.totalSize - 1,
        RequestId.example,
        uint64.example,
        UInt256.example,
        validUntil,
      )

      let two = reservations.createReservation(
        availability.id, availability.totalSize, RequestId.example, uint64.example,
        UInt256.example, validUntil,
      )

      let oneResult = await one
      let twoResult = await two

      check oneResult.isErr or twoResult.isErr

      if oneResult.isErr:
        check oneResult.error of BytesOutOfBoundsError
      if twoResult.isErr:
        check twoResult.error of BytesOutOfBoundsError

    var futures: seq[Future[void]]
    for _ in 1 .. CONCURRENCY_TESTS_COUNT:
      futures.add(concurrencyTest())

    await allFuturesThrowing(futures)

  test "creating reservation reduces availability size":
    let availability = createAvailability()
    let orig = availability.freeSize
    let reservation = createReservation(availability)
    let key = availability.id.key.get
    let updated = (await reservations.get(key, Availability)).get
    check updated.freeSize == orig - reservation.size

  test "can check if reservation exists":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    let key = reservation.key.get
    check await reservations.exists(key)

  test "non-existant availability does not exist":
    let key = AvailabilityId.example.key.get
    check not (await reservations.exists(key))

  test "non-existant reservation does not exist":
    let key = key(ReservationId.example, AvailabilityId.example).get
    check not (await reservations.exists(key))

  test "can check if availability exists":
    let availability = createAvailability()
    let key = availability.key.get
    check await reservations.exists(key)

  test "can delete reservation":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    check isOk (
      await reservations.deleteReservation(reservation.id, reservation.availabilityId)
    )
    let key = reservation.key.get
    check not (await reservations.exists(key))

  test "deleting reservation returns bytes back to availability":
    let availability = createAvailability()
    let orig = availability.freeSize
    let reservation = createReservation(availability)
    discard
      await reservations.deleteReservation(reservation.id, reservation.availabilityId)
    let key = availability.key.get
    let updated = !(await reservations.get(key, Availability))
    check updated.freeSize == orig

  test "calling returnBytesToAvailability returns bytes back to availability":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    let orig = availability.freeSize - reservation.size
    let origQuota = repo.quotaReservedBytes
    let returnedBytes = reservation.size + 200.uint64

    check isOk await reservations.returnBytesToAvailability(
      reservation.availabilityId, reservation.id, returnedBytes
    )

    let key = availability.key.get
    let updated = !(await reservations.get(key, Availability))

    check updated.freeSize > orig
    check (updated.freeSize - orig) == 200.uint64
    check (repo.quotaReservedBytes - origQuota) == 200.NBytes

  test "update releases quota when lowering size":
    let
      availability = createAvailability()
      origQuota = repo.quotaReservedBytes
    availability.totalSize = availability.totalSize - 100

    check isOk await reservations.update(availability)
    check (origQuota - repo.quotaReservedBytes) == 100.NBytes

  test "update reserves quota when growing size":
    let
      availability = createAvailability()
      origQuota = repo.quotaReservedBytes
    availability.totalSize = availability.totalSize + 100

    check isOk await reservations.update(availability)
    check (repo.quotaReservedBytes - origQuota) == 100.NBytes

  test "create availability set enabled to true by default":
    let availability = createAvailability()
    check availability.enabled == true

  test "create availability set until to 0 by default":
    let availability = createAvailability()
    check availability.until == 0.SecondsSince1970

  test "create availability whith correct values":
    var until = getTime().toUnix()

    let availability = createAvailability(enabled = false, until = until)
    check availability.enabled == false
    check availability.until == until

  test "create an availability fails when trying set until with a negative value":
    let totalSize = rand(100000 .. 200000).uint64
    let example = Availability.example(collateralPerByte)
    let totalCollateral = totalSize.u256 * collateralPerByte

    let result = await reservations.createAvailability(
      totalSize,
      example.duration,
      example.minPricePerBytePerSecond,
      totalCollateral,
      enabled = true,
      until = -1.SecondsSince1970,
    )

    check result.isErr
    check result.error of UntilOutOfBoundsError

  test "update an availability fails when trying set until with a negative value":
    let until = getTime().toUnix()
    let availability = createAvailability(until = until)

    availability.until = -1

    let result = await reservations.update(availability)
    check result.isErr
    check result.error of UntilOutOfBoundsError

  test "reservation can be partially released":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    check isOk await reservations.release(reservation.id, reservation.availabilityId, 1)
    let key = reservation.key.get
    let updated = !(await reservations.get(key, Reservation))
    check updated.size == reservation.size - 1

  test "cannot release more bytes than size of reservation":
    let availability = createAvailability()
    let reservation = createReservation(availability)
    let updated = await reservations.release(
      reservation.id, reservation.availabilityId, reservation.size + 1
    )
    check updated.isErr
    check updated.error of BytesOutOfBoundsError

  test "cannot release bytes from non-existant reservation":
    let availability = createAvailability()
    discard createReservation(availability)
    let updated = await reservations.release(ReservationId.example, availability.id, 1)
    check updated.isErr
    check updated.error of NotExistsError

  test "OnAvailabilitySaved called when availability is created":
    var added: Availability
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      added = a

    let availability = createAvailability()

    check added == availability

  test "OnAvailabilitySaved called when availability size is increased":
    var availability = createAvailability()
    var added: Availability
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      added = a
    availability.freeSize += 1
    discard await reservations.update(availability)

    check added == availability

  test "OnAvailabilitySaved is not called when availability size is decreased":
    var availability = createAvailability()
    var called = false
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      called = true
    availability.freeSize -= 1.uint64
    discard await reservations.update(availability)

    check not called

  test "OnAvailabilitySaved is not called when availability is disabled":
    var availability = createAvailability(enabled = false)
    var called = false
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      called = true
    availability.freeSize -= 1
    discard await reservations.update(availability)

    check not called

  test "OnAvailabilitySaved called when availability duration is increased":
    var availability = createAvailability()
    var added: Availability
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      added = a
    availability.duration += 1
    discard await reservations.update(availability)

    check added == availability

  test "OnAvailabilitySaved is not called when availability duration is decreased":
    var availability = createAvailability()
    var called = false
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      called = true
    availability.duration -= 1
    discard await reservations.update(availability)

    check not called

  test "OnAvailabilitySaved called when availability minPricePerBytePerSecond is increased":
    var availability = createAvailability()
    var added: Availability
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      added = a
    availability.minPricePerBytePerSecond += 1.u256
    discard await reservations.update(availability)

    check added == availability

  test "OnAvailabilitySaved is not called when availability minPricePerBytePerSecond is decreased":
    var availability = createAvailability()
    var called = false
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      called = true
    availability.minPricePerBytePerSecond -= 1.u256
    discard await reservations.update(availability)

    check not called

  test "OnAvailabilitySaved called when availability totalRemainingCollateral is increased":
    var availability = createAvailability()
    var added: Availability
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      added = a
    availability.totalRemainingCollateral =
      availability.totalRemainingCollateral + 1.u256
    discard await reservations.update(availability)

    check added == availability

  test "OnAvailabilitySaved is not called when availability totalRemainingCollateral is decreased":
    var availability = createAvailability()
    var called = false
    reservations.OnAvailabilitySaved = proc(a: Availability) {.async: (raises: []).} =
      called = true
    availability.totalRemainingCollateral =
      availability.totalRemainingCollateral - 1.u256
    discard await reservations.update(availability)

    check not called

  test "availabilities can be found":
    let availability = createAvailability()
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize, availability.duration,
      availability.minPricePerBytePerSecond, collateralPerByte, validUntil,
    )

    check found.isSome
    check found.get == availability

  test "does not find an availability when is it disabled":
    let availability = createAvailability(enabled = false)
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize, availability.duration,
      availability.minPricePerBytePerSecond, collateralPerByte, validUntil,
    )

    check found.isNone

  test "finds an availability when the until date is after the duration":
    let example = Availability.example(collateralPerByte)
    let until = getTime().toUnix() + example.duration.SecondsSince1970
    let availability = createAvailability(until = until)
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize, availability.duration,
      availability.minPricePerBytePerSecond, collateralPerByte, validUntil,
    )

    check found.isSome
    check found.get == availability

  test "does not find an availability when the until date is before the duration":
    let example = Availability.example(collateralPerByte)
    let until = getTime().toUnix() + 1.SecondsSince1970
    let availability = createAvailability(until = until)
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize, availability.duration,
      availability.minPricePerBytePerSecond, collateralPerByte, validUntil,
    )

    check found.isNone

  test "non-matching availabilities are not found":
    let availability = createAvailability()
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize + 1,
      availability.duration,
      availability.minPricePerBytePerSecond,
      collateralPerByte,
      validUntil,
    )

    check found.isNone

  test "non-existent availability cannot be found":
    let availability = Availability.example
    let validUntil = getTime().toUnix() + 30.SecondsSince1970
    let found = await reservations.findAvailability(
      availability.freeSize, availability.duration,
      availability.minPricePerBytePerSecond, collateralPerByte, validUntil,
    )

    check found.isNone

  test "non-existent availability cannot be retrieved":
    let key = AvailabilityId.example.key.get
    let got = await reservations.get(key, Availability)
    check got.error of NotExistsError

  test "can get available bytes in repo":
    check reservations.available == DefaultQuotaBytes.uint

  test "reports quota available to be reserved":
    check reservations.hasAvailable(DefaultQuotaBytes.uint - 1)

  test "reports quota not available to be reserved":
    check not reservations.hasAvailable(DefaultQuotaBytes.uint64 + 1)

  test "fails to create availability with size that is larger than available quota":
    let created = await reservations.createAvailability(
      DefaultQuotaBytes.uint64 + 1,
      uint64.example,
      UInt256.example,
      UInt256.example,
      enabled = true,
      until = 0.SecondsSince1970,
    )
    check created.isErr
    check created.error of ReserveFailedError
    check created.error.parent of QuotaNotEnoughError
