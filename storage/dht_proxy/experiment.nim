## Local experiment only. Runtime policy switches and trace events for the
## adaptive concurrency per Mix DHT proxy measurements. Defaults reproduce the
## limits on Storage #1587.
{.push raises: [].}

import std/random
import pkg/chronos

type
  ClientPolicy* = object
    window*: int ## fixed requests awaiting replies per stream; 0 = no fixed cap
    adaptive*: bool ## vary the window from proxy replies instead
    retryBusy*: bool ## requeue an ErrTooBusy lookup locally and retry
    followLimit*: bool ## take the window from the limit in proxy replies
    probe*: bool ## with followLimit, try sending a little above that limit
    initialWindow*: int
    decrease*: float ## window multiplier after a busy reply
    backoffBase*, backoffMax*: Duration

  ProxyPolicy* = object
    perStream*: int ## fixed workers per stream; 0 = no fixed cap
    softShare*: bool ## keep the last free slots for streams under an equal share
    headroom*: int ## slots kept for under-share streams
    replyBudget*: int ## bytes of finished replies a stream may hold; 0 = off
    maxUnwritten*: int ## finished replies a stream may hold when budgeted
    advertise*: bool ## state the stream's current limit in every reply

const
  StockClientPolicy* = ClientPolicy(window: 4)
  StockProxyPolicy* = ProxyPolicy(perStream: 4)

var
  clientPolicyValue {.threadvar.}: ClientPolicy
  proxyPolicyValue {.threadvar.}: ProxyPolicy
  configured {.threadvar.}: bool
  tracing {.threadvar.}: bool
  epoch {.threadvar.}: Moment
  jitterRng {.threadvar.}: Rand

proc configure*(client: ClientPolicy, proxy: ProxyPolicy, seed: int64) =
  clientPolicyValue = client
  proxyPolicyValue = proxy
  configured = true
  tracing = true
  epoch = Moment.now()
  jitterRng = initRand(seed)

proc clientPolicy*(): ClientPolicy =
  if configured: clientPolicyValue else: StockClientPolicy

proc proxyPolicy*(): ProxyPolicy =
  if configured: proxyPolicyValue else: StockProxyPolicy

proc backoff*(policy: ClientPolicy, attempt: int): Duration =
  ## Exponential backoff with jitter drawn from the upper half of the step.
  var step = policy.backoffBase
  for _ in 1 ..< attempt:
    if step >= policy.backoffMax:
      break
    step = step * 2
  step = min(step, policy.backoffMax)
  let micros = step.microseconds
  microseconds(micros div 2 + jitterRng.rand(micros div 2))

proc tail*(bytes: openArray[byte]): string =
  ## Last bytes of a CID in hex, to match proxy events with client lookups.
  const digits = "0123456789abcdef"
  for i in max(0, bytes.len - 6) ..< bytes.len:
    result.add(digits[int(bytes[i] shr 4)])
    result.add(digits[int(bytes[i] and 15)])

proc traceEnabled*(): bool =
  tracing

proc emit*(kind: string, fields: varargs[string, `$`]) =
  var line = "EV " & $(Moment.now() - epoch).microseconds & " " & kind
  for field in fields:
    line.add(' ')
    line.add(field)
  try:
    stdout.writeLine(line)
  except IOError:
    discard

template event*(kind: string, fields: varargs[untyped]) =
  if traceEnabled():
    emit(kind, fields)
