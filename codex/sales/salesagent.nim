import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import ../contracts/requests
import ../errors
import ../logutils
import ../utils/exceptions
import ./statemachine
import ./salescontext
import ./salesdata
import ./reservations
import ./slotqueue

export reservations

logScope:
  topics = "marketplace sales"

type
  SalesAgent* = ref object of Machine
    context*: SalesContext
    data*: SalesData
    subscribed: bool
    # Slot-level callbacks.
    onCleanUp*: OnCleanUp
    onFilled*: ?OnFilled

  OnCleanUp* = proc(reprocessSlot = false, returnedCollateral = UInt256.none) {.
    async: (raises: [])
  .}
  OnFilled* = proc(request: StorageRequest, slotIndex: uint64) {.gcsafe, raises: [].}

  SalesAgentError = object of CodexError
  AllSlotsFilledError* = object of SalesAgentError

func `==`*(a, b: SalesAgent): bool =
  a.data.requestId == b.data.requestId and a.data.slotIndex == b.data.slotIndex

proc newSalesAgent*(
    context: SalesContext,
    requestId: RequestId,
    slotIndex: uint64,
    request: ?StorageRequest,
    slotQueueItem = SlotQueueItem.none,
): SalesAgent =
  var agent = SalesAgent.new()
  agent.context = context
  agent.data = SalesData(
    requestId: requestId,
    slotIndex: slotIndex,
    request: request,
    slotQueueItem: slotQueueItem,
  )
  return agent

proc retrieveRequest*(agent: SalesAgent) {.async.} =
  let data = agent.data
  let market = agent.context.market
  if data.request.isNone:
    data.request = await market.getRequest(data.requestId)

proc retrieveRequestState*(agent: SalesAgent): Future[?RequestState] {.async.} =
  let data = agent.data
  let market = agent.context.market
  return await market.requestState(data.requestId)

func state*(agent: SalesAgent): ?string =
  proc description(state: State): string =
    $state

  agent.query(description)

proc subscribeCancellation(agent: SalesAgent) {.async.} =
  let data = agent.data
  let clock = agent.context.clock

  proc onCancelled() {.async: (raises: []).} =
    without request =? data.request:
      return

    try:
      let market = agent.context.market
      let expiry = await market.requestExpiresAt(data.requestId)

      while true:
        let deadline = max(clock.now, expiry) + 1
        trace "Waiting for request to be cancelled", now = clock.now, expiry = deadline
        await clock.waitUntil(deadline)

        without state =? await agent.retrieveRequestState():
          error "Unknown request", requestId = data.requestId
          return

        case state
        of New:
          discard
        of RequestState.Cancelled:
          agent.schedule(cancelledEvent(request))
          break
        of RequestState.Started, RequestState.Finished, RequestState.Failed:
          break

        debug "The request is not yet canceled, even though it should be. Waiting for some more time.",
          currentState = state, now = clock.now
    except CancelledError:
      trace "Waiting for expiry to lapse was cancelled", requestId = data.requestId
    except CatchableError as e:
      error "Error while waiting for expiry to lapse", error = e.msgDetail

  data.cancelled = onCancelled()

method onFulfilled*(
    agent: SalesAgent, requestId: RequestId
) {.base, gcsafe, raises: [].} =
  let cancelled = agent.data.cancelled
  if agent.data.requestId == requestId and not cancelled.isNil and not cancelled.finished:
    cancelled.cancelSoon()

method onFailed*(agent: SalesAgent, requestId: RequestId) {.base, gcsafe, raises: [].} =
  without request =? agent.data.request:
    return
  if agent.data.requestId == requestId:
    agent.schedule(failedEvent(request))

method onSlotFilled*(
    agent: SalesAgent, requestId: RequestId, slotIndex: uint64
) {.base, gcsafe, raises: [].} =
  if agent.data.requestId == requestId and agent.data.slotIndex == slotIndex:
    agent.schedule(slotFilledEvent(requestId, slotIndex))

proc subscribe*(agent: SalesAgent) {.async.} =
  if agent.subscribed:
    return

  await agent.subscribeCancellation()
  agent.subscribed = true

proc unsubscribe*(agent: SalesAgent) {.async: (raises: []).} =
  if not agent.subscribed:
    return

  let data = agent.data
  if not data.cancelled.isNil and not data.cancelled.finished:
    await data.cancelled.cancelAndWait()
    data.cancelled = nil

  agent.subscribed = false

proc stop*(agent: SalesAgent) {.async: (raises: []).} =
  await Machine(agent).stop()
  await agent.unsubscribe()
