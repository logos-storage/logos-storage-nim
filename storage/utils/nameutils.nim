## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/strutils

import pkg/libp2p
import pkg/questionable/results
import pkg/stew/base64

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

proc parseNameRecord*(name: Name, record: string): Result[seq[byte], ref CatchableError] =
  ## The bytes of a signed name record of the name, in base64url. The DHT checks
  ## the other rules, such as the expiration, when the node advertises it.
  var bytes: seq[byte]

  try:
    bytes = Base64Url.decode(record.strip())
  except Base64Error:
    return failure("The name record is not base64url")

  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  if signed.name() != name:
    return failure("The name record is not for this name key")

  ok(bytes)
