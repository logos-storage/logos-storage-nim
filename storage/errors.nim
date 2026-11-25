## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options
import std/sugar
import std/sequtils

import pkg/results
import pkg/chronos
import pkg/questionable/results

export results

type
  StorageError* = object of CatchableError # base Storage error
  StorageResult*[T] = Result[T, ref StorageError]

  WantBlocksErrorKind* = enum
    RequestTooShort
    RequestTooLarge
    RequestTruncated
    InvalidCid
    InvalidCodec
    MetadataTooShort
    MetadataTruncated
    ResponseTooLarge
    MetadataTooLarge
    DataSizeMismatch
    ProofTooShort
    ProofTruncated
    ProofCreationFailed
    ProofPathTooLarge
    ProofDecodeFailed
    MissingProof
    TooManyBlocks
    NoConnection
    ConnectionClosed
    RequestFailed

  WantBlocksError* = object of StorageError
    kind*: WantBlocksErrorKind

  WantBlocksResult*[T] = Result[T, ref WantBlocksError]

  FinishedFailed*[T] = tuple[success: seq[Future[T]], failure: seq[Future[T]]]

  FinishedFutures*[T] =
    tuple[completed: seq[Future[T]], failed: seq[Future[T]], cancelled: seq[Future[T]]]

proc wantBlocksError*(kind: WantBlocksErrorKind, msg: string): ref WantBlocksError =
  (ref WantBlocksError)(kind: kind, msg: msg)

template mapFailure*[T, V, E](
    exp: Result[T, V], exc: typedesc[E]
): Result[T, ref CatchableError] =
  ## Convert `Result[T, E]` to `Result[E, ref CatchableError]`
  ##

  exp.mapErr(
    proc(e: V): ref CatchableError =
      (ref exc)(msg: $e)
  )

template mapFailure*[T, V](exp: Result[T, V]): Result[T, ref CatchableError] =
  mapFailure(exp, StorageError)

# TODO: using a template here, causes bad codegen
func toFailure*[T](exp: Option[T]): Result[T, ref CatchableError] {.inline.} =
  if exp.isSome:
    success exp.get
  else:
    T.failure("Option is None")

proc allFinishedFailed*[T](
    futs: auto
): Future[FinishedFailed[T]] {.async: (raises: [CancelledError]).} =
  ## Check if all futures have finished or failed
  ##
  ## TODO: wip, not sure if we want this - at the minimum,
  ## we should probably avoid the async transform

  var res: FinishedFailed[T] = (@[], @[])
  await allFutures(futs)
  for f in futs:
    if f.completed:
      res.success.add f
    else:
      res.failure.add f

  return res

proc allFinishedValues*[T](
    futs: auto
): Future[?!seq[T]] {.async: (raises: [CancelledError]).} =
  ## If all futures have finished, return corresponding values,
  ## otherwise return failure
  ##

  # wait for all futures to be either completed, failed or canceled
  await allFutures(futs)

  let numOfFailed = futs.countIt(it.failed)

  if numOfFailed > 0:
    return failure "Some futures failed (" & $numOfFailed & "))"

  # here, we know there are no failed futures in "futs"
  # and we are only interested in those that completed successfully
  let values = collect:
    for b in futs:
      if b.finished:
        b.value
  return success values

proc allDone*[T](
    futs: auto
): Future[FinishedFutures[T]] {.async: (raises: [CancelledError]).} =
  ## Returns a future which will complete only when all futures in ``futs``
  ## will be completed, failed or cancelled.
  ##
  ## Returned FinishedFutures will hold all the Future[T] objects passed to
  ## ``allDone``, grouped by their end state, with the order preserved.
  ##
  ## If the argument is empty, the returned future COMPLETES immediately.
  ##
  ## On cancel all the awaited futures ``futs`` WILL NOT BE cancelled.
  ##
  ## This is different from nim-chronos' ``allFinished``, in that the completed
  ## futures are grouped by their end state.
  await allFutures(futs)
  var res: FinishedFutures[T] = (@[], @[], @[])

  for f in futs:
    if f.completed:
      when T is Result:
        # count successfully completed Future containing Results with errors as
        # failed
        if f.value.isErr:
          res.failed.add f
          continue
      res.completed.add f
    elif f.cancelled:
      res.cancelled.add f
    else:
      res.failed.add f

  return res
