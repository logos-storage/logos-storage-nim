## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import ../stores

type
  ErasureBackend* = ref object of RootObj
    blockSize*: int # block size in bytes
    buffers*: int # number of original pieces
    parity*: int # number of redundancy pieces

  EncoderBackend* = ref object of ErasureBackend
  DecoderBackend* = ref object of ErasureBackend

method release*(self: ErasureBackend) {.base, gcsafe.} =
  ## release the backend
  ##
  raiseAssert("not implemented!")

method encode*(
    self: EncoderBackend, data, parity: var openArray[seq[byte]]
): Result[void, cstring] {.base, gcsafe.} =
  ## encode buffers using a backend
  ##
  raiseAssert("not implemented!")

method decode*(
    self: DecoderBackend, data, parity, recovered: var openArray[seq[byte]]
): Result[void, cstring] {.base, gcsafe.} =
  ## decode buffers using a backend
  ##
  raiseAssert("not implemented!")
