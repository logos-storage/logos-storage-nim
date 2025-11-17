import pkg/questionable
import pkg/questionable/results

import ../statemachine
import ../salesagent
import ../../logutils
import ../../utils/exceptions

logScope:
  topics = "marketplace sales errored"

type SaleErrored* = ref object of SaleState
  error*: ref CatchableError
  reprocessSlot*: bool

method `$`*(state: SaleErrored): string =
  "SaleErrored"

method run*(
    state: SaleErrored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context

  error "Sale error",
    error = state.error.msgDetail,
    requestId = data.requestId,
    slotIndex = data.slotIndex

  try:
    if onClear =? context.onClear and request =? data.request:
      onClear(request, data.slotIndex)

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = state.reprocessSlot)
  except CancelledError as e:
    trace "SaleErrored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleErrored.run", error = e.msgDetail
