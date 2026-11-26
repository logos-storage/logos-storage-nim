import std/times
import pkg/storage/conf
from pkg/libp2p import Cid, `$`
import ../../asynctest
import ../../checktest
import ../../examples
import ../../storage/examples
import ../storageconfig
import ../storageclient
import ../multinodes

multinodesuite "Rest API validation":
  let config = NodeConfigs(clients: StorageConfigs.init(nodes = 1).some)
  var client: StorageClient

  setup:
    client = clients()[0].client

  test "should return 204 when attempting delete of non-existing dataset", config:
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get

    let responseBefore = await client.deleteRaw($Cid.example)
    check responseBefore.status == 204
    check (await responseBefore.body) == "" # No content

  test "upload fails if content disposition contains bad filename", config:
    let headers = @[("Content-Disposition", "attachment; filename=\"exam*ple.txt\"")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The filename is not valid."

  test "upload succeeds if content disposition has an empty filename", config:
    let headers = @[("Content-Disposition", "attachment; filename=\"")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 200

  test "upload fails if content type is invalid", config:
    let headers = @[("Content-Type", "hello/world")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The MIME type 'hello/world' is not valid."

  test "has block returns error 400 when the cid is invalid", config:
    let response = await client.hasBlockRaw("invalid-cid")

    check:
      response.status == 400
      (await response.body) == "Incorrect Cid"
