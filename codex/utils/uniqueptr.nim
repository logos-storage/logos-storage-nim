import std/isolation
type UniquePtr*[T] = object
  ## A unique pointer to a seq[seq[T]] in shared memory
  ## Can only be moved, not copied
  data: ptr T

proc newUniquePtr*[T](data: sink Isolated[T]): UniquePtr[T] =
  ## Creates a new unique sequence in shared memory
  ## The memory is automatically freed when the object is destroyed
  result.data = cast[ptr T](allocShared0(sizeof(T)))

  result.data[] = extract(data)

template newUniquePtr*[T](data: T): UniquePtr[T] =
  newUniquePtr(isolate(data))

proc `=destroy`*[T](p: var UniquePtr[T]) =
  ## Destructor for UniquePtr
  if p.data != nil:
    deallocShared(p.data)
    p.data = nil

proc `=copy`*[T](
  dest: var UniquePtr[T], src: UniquePtr[T]
) {.error: "UniquePtr cannot be copied, only moved".}

proc `=sink`*[T](dest: var UniquePtr[T], src: UniquePtr[T]) =
  if dest.data != nil:
    `=destroy`(dest)
  dest.data = src.data
  # We need to nil out the source data to prevent double-free
  # This is handled by Nim's destructive move semantics

proc `[]`*[T](p: UniquePtr[T]): lent T =
  ## Access the data (read-only)
  if p.data == nil:
    raise newException(NilAccessDefect, "accessing nil UniquePtr")
  p.data[]

# proc `[]`*[T](p: var UniquePtr[T]): var T =
#   ## Access the data (mutable)
#   if p.data == nil:
#     raise newException(NilAccessDefect, "accessing nil UniquePtr")
#   p.data[]

proc isNil*[T](p: UniquePtr[T]): bool =
  ## Check if the UniquePtr is nil
  p.data == nil

proc extractValue*[T](p: var UniquePtr[T]): T =
  ## Extract the value from the UniquePtr and release the memory
  if p.data == nil:
    raise newException(NilAccessDefect, "extracting from nil UniquePtr")

  # Move the value out
  var isolated = isolate(p.data[])
  result = extract(isolated)

  # Free the shared memory
  deallocShared(p.data)
  p.data = nil
