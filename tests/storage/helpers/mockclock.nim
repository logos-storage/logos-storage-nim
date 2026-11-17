import std/times
import pkg/chronos
import storage/clock

export clock

type
  MockClock* = ref object of Clock
    time: SecondsSince1970
    waiting: seq[Waiting]

  Waiting = ref object
    until: SecondsSince1970
    future: Future[void]

func new*(_: type MockClock, time: SecondsSince1970 = getTime().toUnix): MockClock =
  ## Create a mock clock instance
  MockClock(time: time)

proc set*(clock: MockClock, time: SecondsSince1970) =
  clock.time = time
  var index = 0
  while index < clock.waiting.len:
    if clock.waiting[index].until <= clock.time:
      clock.waiting[index].future.complete()
      clock.waiting.del(index)
    else:
      inc index

proc advance*(clock: MockClock, seconds: int64) =
  clock.set(clock.time + seconds)

method now*(clock: MockClock): SecondsSince1970 {.raises: [].} =
  clock.time

method waitUntil*(
    clock: MockClock, time: SecondsSince1970
) {.async: (raises: [CancelledError]).} =
  try:
    if time > clock.now():
      let waiting = Waiting(until: time, future: newFuture[void]())
      clock.waiting.add(waiting)

      try:
        await waiting.future
      except CancelledError as e:
        # A cancelled wait is no longer waiting
        let index = clock.waiting.find(waiting)

        if index >= 0:
          clock.waiting.del(index)

        raise e
  except CancelledError as e:
    raise e
  except Exception as e:
    discard

proc isWaiting*(clock: MockClock): bool =
  clock.waiting.len > 0
