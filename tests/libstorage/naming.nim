import std/json
import std/monotimes
import std/os
import std/strutils
import std/times

import pkg/chronos
import pkg/libp2p/[cid, crypto/crypto, multihash]
import pkg/results
import pkg/stew/base64

import ../asynctest
import ../checktest
import ../storage/examples
import ../../library/node_factory
import ../../library/storage_api/naming_api
import ../../storage/naming/record
import ../../storage/naming/dht

from ../../storage/storage import StorageServer, close
from ../../storage/storagetypes import ManifestCodec

# libstorageNimMain is emitted once, by download.nim.

proc datasetCid(): string =
  $Cid
    .init(
      CIDv1,
      ManifestCodec,
      MultiHash.digest("sha2-256", "dataset".toOpenArrayByte(0, 6)).get(),
    )
    .get()

asyncchecksuite "Libstorage - names":
  var
    dataDir: string
    node: StorageServer

  setup:
    dataDir = getTempDir() / "libstorage-naming" / $getMonoTime()
    createDir(dataDir)

    let conf = %*{"data-dir": dataDir / "repo", "nat": "extip:127.0.0.1"}

    node = (await createStorage($conf)).tryGet()

  teardown:
    if not node.isNil:
      await node.close()

      node = nil

    removeDir(dataDir)

  test "publish refuses a cid that is not a CID":
    let res = await storage_name_publish(node, "catalog", "not-a-cid", 1)

    check res.isErr

    if res.isErr:
      check "invalid CID" in res.error

  test "stop publishing refuses an empty label":
    let res = await storage_name_stop_publishing(node, "")

    check res.isErr

    if res.isErr:
      check "Label is shorter" in res.error

  test "resolve refuses a name that is not a CID":
    let res = await storage_name_resolve(node, "not-a-cid")

    check res.isErr

    if res.isErr:
      check "invalid name" in res.error

  test "refresh refuses a name that is not a CID":
    let res = await storage_name_refresh(node, "not-a-cid", "record")

    check res.isErr

    if res.isErr:
      check "invalid name" in res.error

  test "refresh refuses a name record that is not base64url":
    let res = await storage_name_refresh(node, datasetCid(), "not base64url!")

    check res.isErr

    if res.isErr:
      check "Failed to refresh the name: " in res.error
      check "not base64url" in res.error

  test "refresh refuses a name record that is not valid":
    let
      privateKey = PrivateKey.example
      catalogName = name(privateKey.getPublicKey().get(), "catalog").get()
      catalogKey = $Cid.init(nameKey(catalogName)).get()
      # The label of this name record doesn't match the name key.
      nameRecord = NameRecord(
        version: NameRecordVersion,
        label: "release",
        cid: Cid.init(datasetCid()).get(),
        seqnum: 1,
        expiration: getTime().toUnix() + 3600,
      )
      signed = SignedNameRecord.init(privateKey, nameRecord).get()
      record = Base64Url.encode(signed.encode())

    let res = await storage_name_refresh(node, catalogKey, record)

    check res.isErr

    if res.isErr:
      check "Failed to refresh the name: " in res.error

  test "is_key answers true for a name key from a publish":
    let nameKey =
      (await storage_name_publish(node, "catalog", datasetCid(), 1)).tryGet()

    let res = await storage_name_is_key(node, nameKey)

    check res == Result[string, string].ok("true")

  test "is_key answers false for a dataset CID":
    let res = await storage_name_is_key(node, datasetCid())

    check res == Result[string, string].ok("false")

  test "is_key answers false for a string that is not a CID":
    let res = await storage_name_is_key(node, "not-a-cid")

    check res == Result[string, string].ok("false")

  test "resolve_key refuses a peer ID that is not valid":
    let res = await storage_name_resolve_key(node, "not-a-peer-id", "catalog")

    check res.isErr

    if res.isErr:
      check "invalid peer ID" in res.error
