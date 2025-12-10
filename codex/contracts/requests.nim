import std/hashes
import std/sequtils
import std/typetraits
import pkg/contractabi
import pkg/nimcrypto/keccak
import pkg/ethers/contracts/fields
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/libp2p/[cid, multicodec]
import ../logutils
import ../utils/json
from ../errors import mapFailure

export contractabi

type
  StorageRequest* = object
    client* {.serialize.}: Address
    ask* {.serialize.}: StorageAsk
    content* {.serialize.}: StorageContent
    expiry* {.serialize.}: uint64
    nonce*: Nonce

  StorageAsk* = object
    proofProbability* {.serialize.}: UInt256
    pricePerBytePerSecond* {.serialize.}: UInt256
    collateralPerByte* {.serialize.}: UInt256
    slots* {.serialize.}: uint64
    slotSize* {.serialize.}: uint64
    duration* {.serialize.}: uint64
    maxSlotLoss* {.serialize.}: uint64

  StorageContent* = object
    cid* {.serialize.}: Cid
    merkleRoot*: array[32, byte]

  Slot* = object
    request* {.serialize.}: StorageRequest
    slotIndex* {.serialize.}: uint64

  SlotId* = distinct array[32, byte]
  RequestId* = distinct array[32, byte]
  Nonce* = distinct array[32, byte]
  RequestState* {.pure.} = enum
    New
    Started
    Cancelled
    Finished
    Failed

  SlotState* {.pure.} = enum
    Free
    Filled
    Finished
    Failed
    Paid
    Cancelled
    Repair

proc `==`*(x, y: Nonce): bool {.borrow.}
proc `==`*(x, y: RequestId): bool {.borrow.}
proc `==`*(x, y: SlotId): bool {.borrow.}
proc hash*(x: SlotId): Hash {.borrow.}
proc hash*(x: Nonce): Hash {.borrow.}
proc hash*(x: Address): Hash {.borrow.}

func toArray*(id: RequestId | SlotId | Nonce): array[32, byte] =
  array[32, byte](id)

proc `$`*(id: RequestId | SlotId | Nonce): string =
  id.toArray.toHex

proc fromHex*(T: type RequestId, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*(T: type SlotId, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*(T: type Nonce, hex: string): T =
  T array[32, byte].fromHex(hex)

proc fromHex*[T: distinct](_: type T, hex: string): T =
  type baseType = T.distinctBase
  T baseType.fromHex(hex)

proc toHex*[T: distinct](id: T): string =
  type baseType = T.distinctBase
  baseType(id).toHex

logutils.formatIt(LogFormat.textLines, Nonce):
  it.short0xHexLog
logutils.formatIt(LogFormat.textLines, RequestId):
  it.short0xHexLog
logutils.formatIt(LogFormat.textLines, SlotId):
  it.short0xHexLog
logutils.formatIt(LogFormat.json, Nonce):
  it.to0xHexLog
logutils.formatIt(LogFormat.json, RequestId):
  it.to0xHexLog
logutils.formatIt(LogFormat.json, SlotId):
  it.to0xHexLog

func fromTuple(_: type StorageRequest, tupl: tuple): StorageRequest =
  StorageRequest(
    client: tupl[0], ask: tupl[1], content: tupl[2], expiry: tupl[3], nonce: tupl[4]
  )

func fromTuple(_: type Slot, tupl: tuple): Slot =
  Slot(request: tupl[0], slotIndex: tupl[1])

func fromTuple(_: type StorageAsk, tupl: tuple): StorageAsk =
  StorageAsk(
    proofProbability: tupl[0],
    pricePerBytePerSecond: tupl[1],
    collateralPerByte: tupl[2],
    slots: tupl[3],
    slotSize: tupl[4],
    duration: tupl[5],
    maxSlotLoss: tupl[6],
  )

func fromTuple(_: type StorageContent, tupl: tuple): StorageContent =
  StorageContent(cid: tupl[0], merkleRoot: tupl[1])

func solidityType*(_: type Cid): string =
  solidityType(seq[byte])

func solidityType*(_: type StorageContent): string =
  solidityType(StorageContent.fieldTypes)

func solidityType*(_: type StorageAsk): string =
  solidityType(StorageAsk.fieldTypes)

func solidityType*(_: type StorageRequest): string =
  solidityType(StorageRequest.fieldTypes)

# Note: it seems to be ok to ignore the vbuffer offset for now
func encode*(encoder: var AbiEncoder, cid: Cid) =
  encoder.write(cid.data.buffer)

func encode*(encoder: var AbiEncoder, content: StorageContent) =
  encoder.write(content.fieldValues)

func encode*(encoder: var AbiEncoder, ask: StorageAsk) =
  encoder.write(ask.fieldValues)

func encode*(encoder: var AbiEncoder, id: RequestId | SlotId | Nonce) =
  encoder.write(id.toArray)

func encode*(encoder: var AbiEncoder, request: StorageRequest) =
  encoder.write(request.fieldValues)

func encode*(encoder: var AbiEncoder, slot: Slot) =
  encoder.write(slot.fieldValues)

func decode*(decoder: var AbiDecoder, T: type Cid): ?!T =
  let data = ?decoder.read(seq[byte])
  Cid.init(data).mapFailure

func decode*(decoder: var AbiDecoder, T: type StorageContent): ?!T =
  let tupl = ?decoder.read(StorageContent.fieldTypes)
  success StorageContent.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageAsk): ?!T =
  let tupl = ?decoder.read(StorageAsk.fieldTypes)
  success StorageAsk.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type StorageRequest): ?!T =
  let tupl = ?decoder.read(StorageRequest.fieldTypes)
  success StorageRequest.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type Slot): ?!T =
  let tupl = ?decoder.read(Slot.fieldTypes)
  success Slot.fromTuple(tupl)

func id*(request: StorageRequest): RequestId =
  let encoding = AbiEncoder.encode((request,))
  RequestId(keccak256.digest(encoding).data)

func slotId*(requestId: RequestId, slotIndex: uint64): SlotId =
  let encoding = AbiEncoder.encode((requestId, slotIndex))
  SlotId(keccak256.digest(encoding).data)

func slotId*(request: StorageRequest, slotIndex: uint64): SlotId =
  slotId(request.id, slotIndex)

func id*(slot: Slot): SlotId =
  slotId(slot.request, slot.slotIndex)

func pricePerSlotPerSecond*(ask: StorageAsk): UInt256 =
  ask.pricePerBytePerSecond * ask.slotSize.u256

func pricePerSlot*(ask: StorageAsk): UInt256 =
  ask.duration.u256 * ask.pricePerSlotPerSecond

func totalPrice*(ask: StorageAsk): UInt256 =
  ask.slots.u256 * ask.pricePerSlot

func totalPrice*(request: StorageRequest): UInt256 =
  request.ask.totalPrice

func collateralPerSlot*(ask: StorageAsk): UInt256 =
  ask.collateralPerByte * ask.slotSize.u256

func size*(ask: StorageAsk): uint64 =
  ask.slots * ask.slotSize
