## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p
import pkg/questionable/results

import ../naming/dht

proc nameKeyString*(name: Name): string =
  ## The name key of the name, as a CID string.
  let cid = Cid.init(nameKey(name)).expect("nameKey builds a valid CID")

  $cid

proc nameKeyString*(signed: SignedNameRecord): string =
  ## The name key of a name record that the publisher built.
  nameKeyString(signed.name())

proc parseName*(nameKey: string): Result[Name, ref CatchableError] =
  ## The name of a name key string, the reverse of `nameKeyString`.
  let cid = Cid.init(nameKey).valueOr:
    return failure("invalid name key: " & $error)

  let name = parseNameKey(cid.data.buffer).valueOr:
    return failure("invalid name key: " & error.msg)

  return ok(name)

proc parsePublicKey*(peerId: string): Result[PublicKey, ref CatchableError] =
  ## The public key of a peer ID string.
  let id = PeerId.init(peerId).valueOr:
    return failure("invalid peer ID: " & $error)

  var publicKey: PublicKey

  if not id.extractPublicKey(publicKey):
    return failure("the peer ID doesn't have a public key")

  return ok(publicKey)
