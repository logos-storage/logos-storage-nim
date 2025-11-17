import pkg/chronos
import pkg/questionable
import pkg/ethers/erc20
import ./contracts/requests
import ./contracts/proofs
import ./clock
import ./errors
import ./periods

export chronos
export questionable
export requests
export proofs
export SecondsSince1970
export periods

type
  Market* = ref object of RootObj
  MarketError* = object of CodexError
  SlotStateMismatchError* = object of MarketError
  SlotReservationNotAllowedError* = object of MarketError
  ProofInvalidError* = object of MarketError
  Subscription* = ref object of RootObj
  OnRequest* =
    proc(id: RequestId, ask: StorageAsk, expiry: uint64) {.gcsafe, raises: [].}
  OnFulfillment* = proc(requestId: RequestId) {.gcsafe, raises: [].}
  OnSlotFilled* = proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSlotFreed* = proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSlotReservationsFull* =
    proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnRequestCancelled* = proc(requestId: RequestId) {.gcsafe, raises: [].}
  OnRequestFailed* = proc(requestId: RequestId) {.gcsafe, raises: [].}
  OnProofSubmitted* = proc(id: SlotId) {.gcsafe, raises: [].}
  ProofChallenge* = array[32, byte]

  # Marketplace events -- located here due to the Market abstraction
  MarketplaceEvent* = Event
  StorageRequested* = object of MarketplaceEvent
    requestId*: RequestId
    ask*: StorageAsk
    expiry*: uint64

  SlotFilled* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  SlotFreed* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  SlotReservationsFull* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  RequestFulfilled* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId

  RequestCancelled* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId

  RequestFailed* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId

  ProofSubmitted* = object of MarketplaceEvent
    id*: SlotId

method loadConfig*(
    market: Market
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method getZkeyHash*(
    market: Market
): Future[?string] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method getSigner*(
    market: Market
): Future[Address] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method periodicity*(
    market: Market
): Future[Periodicity] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method proofTimeout*(
    market: Market
): Future[uint64] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method repairRewardPercentage*(
    market: Market
): Future[uint8] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method requestDurationLimit*(market: Market): Future[uint64] {.base, async.} =
  raiseAssert("not implemented")

method proofDowntime*(
    market: Market
): Future[uint8] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method getPointer*(market: Market, slotId: SlotId): Future[uint8] {.base, async.} =
  raiseAssert("not implemented")

proc inDowntime*(market: Market, slotId: SlotId): Future[bool] {.async.} =
  let downtime = await market.proofDowntime
  let pntr = await market.getPointer(slotId)
  return pntr < downtime

method requestStorage*(
    market: Market, request: StorageRequest
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method myRequests*(market: Market): Future[seq[RequestId]] {.base, async.} =
  raiseAssert("not implemented")

method mySlots*(market: Market): Future[seq[SlotId]] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(
    market: Market, id: RequestId
): Future[?StorageRequest] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method requestState*(
    market: Market, requestId: RequestId
): Future[?RequestState] {.base, async.} =
  raiseAssert("not implemented")

method slotState*(
    market: Market, slotId: SlotId
): Future[SlotState] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method getRequestEnd*(
    market: Market, id: RequestId
): Future[SecondsSince1970] {.base, async.} =
  raiseAssert("not implemented")

method requestExpiresAt*(
    market: Market, id: RequestId
): Future[SecondsSince1970] {.base, async.} =
  raiseAssert("not implemented")

method getHost*(
    market: Market, requestId: RequestId, slotIndex: uint64
): Future[?Address] {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method currentCollateral*(
    market: Market, slotId: SlotId
): Future[UInt256] {.base, async: (raises: [MarketError, CancelledError]).} =
  raiseAssert("not implemented")

method getActiveSlot*(market: Market, slotId: SlotId): Future[?Slot] {.base, async.} =
  raiseAssert("not implemented")

method fillSlot*(
    market: Market,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    collateral: UInt256,
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method freeSlot*(
    market: Market, slotId: SlotId
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method withdrawFunds*(
    market: Market, requestId: RequestId
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method subscribeRequests*(
    market: Market, callback: OnRequest
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(market: Market, id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(market: Market, id: SlotId): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method getChallenge*(
    market: Market, id: SlotId
): Future[ProofChallenge] {.base, async.} =
  raiseAssert("not implemented")

method submitProof*(
    market: Market, id: SlotId, proof: Groth16Proof
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method markProofAsMissing*(
    market: Market, id: SlotId, period: Period
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method canMarkProofAsMissing*(
    market: Market, id: SlotId, period: Period
): Future[bool] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method reserveSlot*(
    market: Market, requestId: RequestId, slotIndex: uint64
) {.base, async: (raises: [CancelledError, MarketError]).} =
  raiseAssert("not implemented")

method canReserveSlot*(
    market: Market, requestId: RequestId, slotIndex: uint64
): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(
    market: Market, callback: OnFulfillment
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(
    market: Market, requestId: RequestId, callback: OnFulfillment
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(
    market: Market, callback: OnSlotFilled
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(
    market: Market, requestId: RequestId, slotIndex: uint64, callback: OnSlotFilled
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFreed*(
    market: Market, callback: OnSlotFreed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotReservationsFull*(
    market: Market, callback: OnSlotReservationsFull
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestCancelled*(
    market: Market, callback: OnRequestCancelled
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestCancelled*(
    market: Market, requestId: RequestId, callback: OnRequestCancelled
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(
    market: Market, callback: OnRequestFailed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(
    market: Market, requestId: RequestId, callback: OnRequestFailed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeProofSubmission*(
    market: Market, callback: OnProofSubmitted
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async.} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    market: Market, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.base, async.} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    market: Market, blocksAgo: int
): Future[seq[SlotFilled]] {.base, async.} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    market: Market, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.base, async.} =
  raiseAssert("not implemented")

method queryPastStorageRequestedEvents*(
    market: Market, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.base, async.} =
  raiseAssert("not implemented")

method queryPastStorageRequestedEvents*(
    market: Market, blocksAgo: int
): Future[seq[StorageRequested]] {.base, async.} =
  raiseAssert("not implemented")

method slotCollateral*(
    market: Market, requestId: RequestId, slotIndex: uint64
): Future[?!UInt256] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method slotCollateral*(
    market: Market, collateralPerSlot: UInt256, slotState: SlotState
): ?!UInt256 {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")
