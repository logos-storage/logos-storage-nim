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
import pkg/questionable/results

import ../discovery
import ./dht
import ./record

export record

# The libp2p KadDHT gives no typed error for a name without name record. When
# no peer has a valid one, `getValue` fails with this text, see
# `bestValidRecord` in libp2p/protocols/kademlia/get.nim.
const NoNameRecordError = "No valid records found"

proc resolve*(
    discovery: Discovery, name: Name
): Future[Result[Opt[Cid], ref CatchableError]] {.async: (raises: [CancelledError]).} =
  ## Reads the name record of the name in the DHT and returns its CID. Returns no
  ## CID when the DHT has no name record for the name.
  ##
  ## The DHT validator has already checked the name record, so it is only
  ## decoded here: see [NameRecordValidator] and `bestValidRecord` in
  ## libp2p/protocols/kademlia/get.nim.
  let bytes = (await discovery.getValue(dhtKeyFromName(name))).valueOr:
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
