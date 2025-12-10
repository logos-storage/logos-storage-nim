import std/random
import std/sequtils
import std/times
import std/typetraits

import pkg/codex/contracts/requests
import pkg/codex/rng
import pkg/codex/contracts/proofs
import pkg/codex/sales/slotqueue
import pkg/codex/stores
import pkg/codex/units

import pkg/chronos
import pkg/stew/byteutils
import pkg/stint

import ./codex/helpers/randomchunker

export randomchunker
export units

proc exampleString*(length: int): string =
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(length) # Create a new empty string with a given length
  for i in 0 ..< length:
    result[i] = chars[rand(chars.len - 1)]
      # Generate a random index and set the string's character

proc example*[T: SomeInteger](_: type T): T =
  rand(T)

proc example*[T, N](_: type array[N, T]): array[N, T] =
  for item in result.mitems:
    item = T.example

proc example*[T](_: type seq[T]): seq[T] =
  let length = uint8.example.int
  newSeqWith(length, T.example)

proc example*(_: type UInt256): UInt256 =
  UInt256.fromBytesBE(array[32, byte].example)

proc example*[T: distinct](_: type T): T =
  type baseType = T.distinctBase
  T(baseType.example)

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    ask: StorageAsk(
      slots: 4,
      slotSize: (1 * 1024 * 1024 * 1024).uint64, # 1 Gigabyte
      duration: (10 * 60 * 60).uint64, # 10 hours
      collateralPerByte: 1.u256,
      proofProbability: 4.u256, # require a proof roughly once every 4 periods
      pricePerBytePerSecond: 1.u256,
      maxSlotLoss: 2, # 2 slots can be freed without data considered to be lost
    ),
    content: StorageContent(
      cid: Cid.init("zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob").tryGet,
      merkleRoot: array[32, byte].example,
    ),
    expiry: (60 * 60).uint64, # 1 hour ,
    nonce: Nonce.example,
  )

proc example*(_: type Slot): Slot =
  let request = StorageRequest.example
  let slotIndex = rand(request.ask.slots.int).uint64
  Slot(request: request, slotIndex: slotIndex)

proc example*(_: type SlotQueueItem): SlotQueueItem =
  let request = StorageRequest.example
  let slot = Slot.example
  SlotQueueItem.init(
    request, slot.slotIndex.uint16, collateral = request.ask.collateralPerSlot
  )

proc example(_: type G1Point): G1Point =
  G1Point(x: UInt256.example, y: UInt256.example)

proc example(_: type G2Point): G2Point =
  G2Point(
    x: Fp2Element(real: UInt256.example, imag: UInt256.example),
    y: Fp2Element(real: UInt256.example, imag: UInt256.example),
  )

proc example*(_: type Groth16Proof): Groth16Proof =
  Groth16Proof(a: G1Point.example, b: G2Point.example, c: G1Point.example)

proc example*(_: type RandomChunker, blocks: int): Future[seq[byte]] {.async.} =
  let rng = Rng.instance()
  let chunker = RandomChunker.new(
    rng, size = DefaultBlockSize * blocks.NBytes, chunkSize = DefaultBlockSize
  )
  var data: seq[byte]
  while (let moar = await chunker.getBytes(); moar != []):
    data.add moar
  return data

proc example*(_: type RandomChunker): Future[string] {.async.} =
  await RandomChunker.example(3)
