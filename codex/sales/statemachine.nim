import pkg/questionable
import ../errors
import ../utils/asyncstatemachine
import ../market
import ../clock
import ../contracts/requests

export market
export clock
export asyncstatemachine

type
  SaleState* = ref object of State
  SaleError* = object of CodexError

method onCancelled*(
    state: SaleState, request: StorageRequest
): ?State {.base, raises: [].} =
  discard

method onFailed*(
    state: SaleState, request: StorageRequest
): ?State {.base, raises: [].} =
  discard

method onSlotFilled*(
    state: SaleState, requestId: RequestId, slotIndex: uint64
): ?State {.base, raises: [].} =
  discard

proc cancelledEvent*(request: StorageRequest): Event =
  return proc(state: State): ?State =
    SaleState(state).onCancelled(request)

proc failedEvent*(request: StorageRequest): Event =
  return proc(state: State): ?State =
    SaleState(state).onFailed(request)

proc slotFilledEvent*(requestId: RequestId, slotIndex: uint64): Event =
  return proc(state: State): ?State =
    SaleState(state).onSlotFilled(requestId, slotIndex)
