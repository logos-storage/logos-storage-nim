## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import pkg/libp2p/crypto/crypto
import pkg/bearssl/rand

type
  RngSampleError = object of CatchableError
  Rng* = ref HmacDrbgContext

var rng {.threadvar.}: Rng

proc instance*(t: type Rng): Rng =
  if rng.isNil:
    rng = newRng()
  rng

# Random helpers: similar as in stdlib, but with HmacDrbgContext rng
# TODO: Move these somewhere else?
const randMax = 18_446_744_073_709_551_615'u64

proc rand*(rng: Rng, max: Natural): int =
  if max == 0:
    return 0

  while true:
    let x = rng[].generate(uint64)
    if x < randMax - (randMax mod (uint64(max) + 1'u64)): # against modulo bias
      return int(x mod (uint64(max) + 1'u64))

proc sample*[T](rng: Rng, a: openArray[T]): T =
  result = a[rng.rand(a.high)]

proc sample*[T](
    rng: Rng, sample, exclude: openArray[T]
): T {.raises: [Defect, RngSampleError].} =
  if sample == exclude:
    raise newException(RngSampleError, "Sample and exclude arrays are the same!")

  while true:
    result = rng.sample(sample)
    if exclude.find(result) != -1:
      continue

    break

proc sample*[T](
    rng: Rng, sample: openArray[T], limit: int
): seq[T] {.raises: [Defect, RngSampleError].} =
  if limit > sample.len:
    raise newException(RngSampleError, "Limit cannot be larger than sample!")

  for _ in 0 ..< min(sample.len, limit):
    result.add(rng.sample(sample, result))

proc shuffle*[T](rng: Rng, a: var openArray[T]) =
  for i in countdown(a.high, 1):
    let j = rng.rand(i)
    swap(a[i], a[j])
