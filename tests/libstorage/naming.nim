import std/json
import std/monotimes
import std/os
import std/strutils

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/node_factory
import ../../library/storage_api/naming_api

from ../../storage/storage import StorageServer, close

# libstorageNimMain is emitted once, by download.nim.

asyncchecksuite "Libstorage - names":
  const cid = "zDzSvJTf8JYwvysKPmG7BtzpbiAHfuwFMRphxm4hdvnMJ4XPJjKX"

  var
    dataDir: string
    node: StorageServer

  setup:
    dataDir = getTempDir() / "libstorage-naming" / $getMonoTime()
    createDir(dataDir)

    let conf = %*{"data-dir": dataDir / "repo", "nat": "extip:127.0.0.1"}

    node = (await createStorage($conf)).tryGet()

  teardown:
    await node.close()

    removeDir(dataDir)

  test "publish refuses a cid that is not a CID":
    let res = await storage_name_publish(node, "catalog", "not-a-cid", 1)

    check res.isErr

    if res.isErr:
      check "invalid CID" in res.error

  test "unpublish refuses an empty label":
    let res = await storage_name_unpublish(node, "")

    check res.isErr

    if res.isErr:
      check "Label is shorter" in res.error

  test "resolve refuses a name that is not a CID":
    let res = await storage_name_resolve(node, "not-a-cid")

    check res.isErr

    if res.isErr:
      check "invalid name" in res.error

  test "resolve refuses a CID that is not a name":
    let res = await storage_name_resolve(node, cid)

    check res.isErr

    if res.isErr:
      check "not a CIDv1 of a name" in res.error

  test "refresh refuses a name that is not a CID":
    let res = await storage_name_refresh(node, "not-a-cid")

    check res.isErr

    if res.isErr:
      check "invalid name" in res.error

  test "resolve_key refuses a peer ID that is not valid":
    let res = await storage_name_resolve_key(node, "not-a-peer-id", "catalog")

    check res.isErr

    if res.isErr:
      check "invalid peer ID" in res.error

  test "resolve_key refuses a peer ID that doesn't hold its public key":
    # The hash of an RSA key.
    const peerId = "QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N"

    let res = await storage_name_resolve_key(node, peerId, "catalog")

    check res.isErr

    if res.isErr:
      check "no public key" in res.error
