import std/times
import pkg/chronos
import ./clock

type SystemClock* = ref object of Clock

method now*(clock: SystemClock): SecondsSince1970 {.raises: [].} =
  let now = times.now().utc
  now.toTime().toUnix()

method waitUntil*(
    clock: SystemClock, time: SecondsSince1970
) {.async: (raises: [CancelledError]).} =
  let remaining = time - clock.now()

  if remaining > 0:
    await sleepAsync(chronos.seconds(remaining))
