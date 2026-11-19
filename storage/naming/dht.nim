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

import pkg/chronos
import pkg/libp2p
from pkg/libp2p/protocols/kademlia import Key

import ../discovery
import ./record
import ./validator

export record, validator

const NoNameRecordError = "No valid records found"

proc nameKey*(name: Name): Key =
  ## The name key of the protocol spec: the name CID, used as key in the DHT.
  let
    hash = MultiHash.init(NameHashCodec, name).expect(
        "A name is 32 bytes, the size of a SHA2-256 digest"
      )
    cid = Cid.init(CIDv1, multiCodec("storage-name"), hash).expect(
        "storage-name is a registered content id codec"
      )

  cid.data.buffer

proc resolve*(
    discovery: Discovery, name: Name
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Reads the name record of the name in the DHT and returns its CID. Returns no
  ## CID when the DHT has no name record for the name.
  ##
  ## The DHT validator has already checked the name record, so it is only
  ## decoded here: see [NameRecordValidator] and `getValue` in
  ## libp2p/protocols/kademlia/get.nim.
  let bytes = (await discovery.getValue(nameKey(name))).valueOr:
    if error.msg.endsWith(NoNameRecordError):
      return ok(Opt.none(Cid))

    return err(error)

  let signed = decodeNameRecord(bytes).valueOr:
    return err(error)

  ok(Opt.some(signed.data.cid))

proc resolve*(
    discovery: Discovery, publicKey: PublicKey, label: string
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Resolves the name of the public key and the label.
  let nameBytes = name(publicKey, label).valueOr:
    return err(error)

  await discovery.resolve(nameBytes)

proc refresh*(
    discovery: Discovery, name: Name
): Future[Result[void, ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Advertises the name record of the name in the DHT again, without changing
  ## it. It doesn't need the private key of the publisher.
  ##
  ## The DHT validator has already checked the name record, so an expired or
  ## invalid one is never advertised: see [NameRecordValidator] and `getValue` in
  ## libp2p/protocols/kademlia/get.nim.
  let key = nameKey(name)

  let bytes = (await discovery.getValue(key)).valueOr:
    return err(error)

  await discovery.putValue(key, bytes)
