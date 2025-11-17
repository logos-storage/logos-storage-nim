import std/times
import ./clock

type SystemClock* = ref object of Clock

method now*(clock: SystemClock): SecondsSince1970 {.raises: [].} =
  let now = times.now().utc
  now.toTime().toUnix()
