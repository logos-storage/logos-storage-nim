import std/strutils

import pkg/unittest2
import pkg/libp2p
import pkg/questionable/results
import pkg/storage/naming/record
import pkg/storage/utils/nameutils

import ../examples

suite "Nameutils":
  let
    privateKey = PrivateKey.example
    publicKey = privateKey.getPublicKey().tryGet()
    catalogName = name(publicKey, "catalog").tryGet()

  test "nameKeyString of a signed name record is the name key string of its name":
    let record = NameRecord(
      version: NameRecordVersion,
      label: "catalog",
      cid: Cid.example,
      seqnum: 1'u64,
      expiration: 1794477600'i64,
    )
    let signed = record.sign(privateKey).tryGet()

    check nameKeyString(signed) == nameKeyString(catalogName)

  test "parseName gives back the name of a name key string":
    check parseName(nameKeyString(catalogName)).tryGet() == catalogName

  test "parseName refuses a string that is not a CID":
    check parseName("not-a-cid").isErr

  test "parseName refuses a CID that is not a name key":
    check parseName($Cid.example).isErr

  test "parsePublicKey gives the public key of a peer ID":
    let peerId = PeerId.init(publicKey).tryGet()

    check parsePublicKey($peerId).tryGet() == publicKey

  test "parsePublicKey refuses a string that is not a peer ID":
    let res = parsePublicKey("not-a-peer-id")

    check res.isErr

    if res.isErr:
      check "invalid peer ID" in res.error.msg

  test "parsePublicKey refuses a peer ID that doesn't hold its public key":
    # The hash of an RSA key.
    let res = parsePublicKey("QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N")

    check res.isErr

    if res.isErr:
      check "doesn't have a public key" in res.error.msg
