import std/json
import std/monotimes
import std/os

import pkg/chronos
import pkg/results

import ../asynctest
import ../checktest
import ../../library/node_factory
import ../../library/storage_api/upload_api
import ../../library/storage_api/download_api

from ../../storage/storage import start, stop, close

{.emit: "void libstorageNimMain(void) {}".}

template withUploadedFile(body: untyped) =
  let dataDir = getTempDir() / "libstorage-download" / $getMonoTime()
  let input = dataDir / "hello.txt"
  let output {.inject.} = dataDir / "downloaded.txt"

  defer:
    removeDir(dataDir)

  createDir(dataDir)
  writeFile(input, "Hello World!")

  resetUploadSessions()
  resetDownloadSessions()

  let conf =
    %*{"data-dir": dataDir / "repo", "nat": "extip:127.0.0.1", "mix-enabled": true}
  let node {.inject.} = (await createStorage($conf)).tryGet()
  defer:
    await node.close()

  await node.start()
  defer:
    await node.stop()

  let sessionId = (await storage_upload_init(node, input, 0, true)).tryGet()
  let cid {.inject.} = (await storage_upload_file(node, sessionId)).tryGet()

  body

asyncchecksuite "Libstorage - download":
  test "streams a private local download session":
    # This test ensures that a private download works for
    # a local download.
    #
    # By declaring the download as local, we don't need Mix relays
    # or a second node.
    #
    # This covers a bug where the session created with storage_download_init
    # wasn't reused by storage_download_stream, so the download failed
    # with:
    # Download privacy setting does not match the existing session.
    withUploadedFile:
      discard (
        await storage_download_init(
          node, cid, 0, local = true, isPrivate = true, advertise = true
        )
      ).tryGet()

      discard (await storage_download_stream(node, cid, 0, output)).tryGet()

      check readFile(output) == "Hello World!"

  test "streams a download without a session":
    withUploadedFile:
      discard (await storage_download_stream(node, cid, 0, output)).tryGet()

      check readFile(output) == "Hello World!"
