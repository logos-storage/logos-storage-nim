import pkg/chronos
import pkg/datastore
import pkg/questionable/results

export datastore

type FailingDatastore* = ref object of Datastore
  ## Calls the real datastore, except for the operations set to fail
  datastore: Datastore
  failGet*: bool
  failPut*: bool
  failDelete*: bool
  failQuery*: bool
  failSecondNext*: bool ## The query gives its first item, then an error

proc new*(T: type FailingDatastore, datastore: Datastore): T =
  FailingDatastore(datastore: datastore)

method get*(
    self: FailingDatastore, key: Key
): Future[?!seq[byte]] {.async: (raises: [CancelledError]).} =
  if self.failGet:
    return failure("get fails")

  return await self.datastore.get(key)

method put*(
    self: FailingDatastore, key: Key, data: seq[byte]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if self.failPut:
    return failure("put fails")

  return await self.datastore.put(key, data)

method delete*(
    self: FailingDatastore, key: Key
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if self.failDelete:
    return failure("delete fails")

  return await self.datastore.delete(key)

method query*(
    self: FailingDatastore, query: Query
): Future[?!QueryIter] {.async: (raises: [CancelledError]).} =
  if self.failQuery:
    return failure("query fails")

  let iter = (await self.datastore.query(query)).valueOr:
    return failure(error)

  if not self.failSecondNext:
    return success(iter)

  let failingIter = QueryIter(dispose: iter.dispose)
  var calls = 0

  proc next(): Future[?!QueryResponse] {.async: (raises: [CancelledError]).} =
    calls.inc

    if calls > 1:
      return failure("next fails")

    return await iter.next()

  failingIter.next = next

  return success(failingIter)
