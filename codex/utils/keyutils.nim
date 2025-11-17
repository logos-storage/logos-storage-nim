## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import pkg/questionable/results
import pkg/libp2p/crypto/crypto

import ./fileutils
import ../errors
import ../logutils
import ../rng

export crypto

type
  CodexKeyError = object of CodexError
  CodexKeyUnsafeError = object of CodexKeyError

proc setupKey*(path: string): ?!PrivateKey =
  if not path.fileAccessible({AccessFlags.Find}):
    info "Creating a private key and saving it"
    let
      res = ?PrivateKey.random(Rng.instance()[]).mapFailure(CodexKeyError)
      bytes = ?res.getBytes().mapFailure(CodexKeyError)

    ?path.secureWriteFile(bytes).mapFailure(CodexKeyError)
    return PrivateKey.init(bytes).mapFailure(CodexKeyError)

  info "Found a network private key"
  if not ?checkSecureFile(path).mapFailure(CodexKeyError):
    warn "The network private key file is not safe, aborting"
    return failure newException(
      CodexKeyUnsafeError, "The network private key file is not safe"
    )

  let kb = ?path.readAllBytes().mapFailure(CodexKeyError)
  return PrivateKey.init(kb).mapFailure(CodexKeyError)
