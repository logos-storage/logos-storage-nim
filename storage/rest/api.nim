## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/sequtils
import std/mimetypes
import std/os
import std/strutils
import std/uri

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/presto except toJson
import pkg/metrics except toJson
import pkg/stew/base10
import pkg/confutils

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/protocols/connectivity/autonatv2/service
import pkg/libp2p/services/autorelayservice
import pkg/codexdht/discv5/spr

import ../logutils
import ../node
import ../discovery
import ../blocktype
import ../storagetypes
import ../conf
import ../manifest
import ../streams/asyncstreamwrapper
import ../stores
import ../stores/repostore
import ../blockexchange
import ../units
import ../utils/options
import ../nat

import ./coders
import ./json

logScope:
  topics = "storage restapi"

declareCounter(storage_api_uploads, "storage API uploads")
declareCounter(storage_api_downloads, "storage API downloads")

proc validate(pattern: string, value: string): int {.gcsafe, raises: [Defect].} =
  0

proc formatManifest(cid: Cid, manifest: Manifest): RestContent =
  return RestContent.init(cid, manifest)

proc formatManifestBlocks(node: StorageNodeRef): Future[JsonNode] {.async.} =
  var content: seq[RestContent]

  proc addManifest(cid: Cid, manifest: Manifest) =
    content.add(formatManifest(cid, manifest))

  await node.iterateManifests(addManifest)

  return %RestContentList.init(content)

proc isPending(resp: HttpResponseRef): bool =
  ## Checks that an HttpResponseRef object is still pending; i.e.,
  ## that no body has yet been sent. This helps us guard against calling
  ## sendBody(resp: HttpResponseRef, ...) twice, which is illegal.
  return resp.getResponseState() == HttpResponseState.Empty

proc retrieveCid(
    node: StorageNodeRef, cid: Cid, local: bool = true, resp: HttpResponseRef
): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
  ## Download a file from the node in a streaming
  ## manner
  ##

  var lpStream: LPStream

  var bytes = 0
  try:
    without stream =? (await node.retrieve(cid, local)), error:
      if error of BlockNotFoundError:
        resp.status = Http404
        await resp.sendBody(
          "The requested CID could not be retrieved (" & error.msg & ")."
        )
        return
      else:
        resp.status = Http500
        await resp.sendBody(error.msg)
        return

    lpStream = stream

    # It is ok to fetch again the manifest because it will hit the cache
    without manifest =? (await node.fetchManifest(cid)), err:
      error "Failed to fetch manifest", err = err.msg
      resp.status = Http404
      await resp.sendBody(err.msg)
      return

    if manifest.mimetype.isSome:
      resp.setHeader("Content-Type", manifest.mimetype.get())
    else:
      resp.addHeader("Content-Type", "application/octet-stream")

    if manifest.filename.isSome:
      resp.setHeader(
        "Content-Disposition",
        "attachment; filename=\"" & manifest.filename.get() & "\"",
      )
    else:
      resp.setHeader("Content-Disposition", "attachment")

    # For erasure-coded datasets, we need to return the _original_ length; i.e.,
    # the length of the non-erasure-coded dataset, as that's what we will be
    # returning to the client.
    resp.setHeader("Content-Length", $(manifest.datasetSize.int))

    await resp.prepare(HttpResponseStreamType.Plain)

    while not stream.atEof:
      var
        buff = newSeqUninit[byte](manifest.blockSize.int)
        len = await stream.readOnce(addr buff[0], buff.len)

      buff.setLen(len)
      if buff.len <= 0:
        break

      bytes += buff.len

      await resp.send(addr buff[0], buff.len)
    await resp.finish()
    storage_api_downloads.inc()
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Error streaming blocks", exc = exc.msg
    resp.status = Http500
    if resp.isPending():
      await resp.sendBody(exc.msg)
  finally:
    info "Sent bytes", cid = cid, bytes
    if not lpStream.isNil:
      await lpStream.close()

proc buildCorsHeaders(
    httpMethod: string, allowedOrigin: Option[string]
): seq[(string, string)] =
  var headers: seq[(string, string)] = newSeq[(string, string)]()

  if corsOrigin =? allowedOrigin:
    headers.add(("Access-Control-Allow-Origin", corsOrigin))
    headers.add(("Access-Control-Allow-Methods", httpMethod & ", OPTIONS"))
    headers.add(("Access-Control-Max-Age", "86400"))

  return headers

proc setCorsHeaders(resp: HttpResponseRef, httpMethod: string, origin: string) =
  resp.setHeader("Access-Control-Allow-Origin", origin)
  resp.setHeader("Access-Control-Allow-Methods", httpMethod & ", OPTIONS")
  resp.setHeader("Access-Control-Max-Age", "86400")

proc getFilenameFromContentDisposition*(contentDisposition: string): ?string =
  # RFC 6266 / RFC 5987: filename* parameter takes precedence over filename
  let idxExt = contentDisposition.find("filename*=")
  if idxExt != -1:
    var val = contentDisposition[idxExt + "filename*=".len .. ^1].strip()
    if val.len > 0:
      let semiIdx = val.find(";")
      if semiIdx != -1:
        val = val[0 .. semiIdx - 1].strip()
      if val.startsWith("\"") and val.endsWith("\"") and val.len >= 2:
        val = val[1 .. ^2].strip()
      let quoteIdx = val.rfind("''")
      if quoteIdx != -1 and quoteIdx + 2 < val.len:
        val = val[quoteIdx + 2 .. ^1]
      try:
        val = decodeUrl(val)
      except CatchableError:
        discard
      val = val.strip(chars = {'"'})
      if val.len > 0:
        return val.some

  let idx = contentDisposition.find("filename=")
  if idx == -1:
    return string.none

  var val = contentDisposition[idx + "filename=".len .. ^1].strip()
  if val.len == 0:
    return string.none

  if val.startsWith("\""):
    let endQuote = val.find("\"", 1)
    if endQuote > 1:
      return val[1 .. endQuote - 1].some
    else:
      return string.none
  else:
    let semiIdx = val.find(";")
    if semiIdx != -1:
      val = val[0 .. semiIdx - 1].strip()
    val = val.strip(chars = {'"'})
    if val.len > 0:
      return val.some
    else:
      return string.none

proc initDataApi(node: StorageNodeRef, repoStore: RepoStore, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin # prevents capture inside of api defintion

  router.api(MethodOptions, "/api/storage/v1/data") do(
    resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("POST", corsOrigin)
      resp.setHeader(
        "Access-Control-Allow-Headers", "content-type, content-disposition"
      )

    resp.status = Http204
    await resp.sendBody("")

  router.rawApi(MethodPost, "/api/storage/v1/data") do() -> RestApiResponse:
    ## Upload a file in a streaming manner
    ##
    ## Optional query parameter:
    ##   blockSize - size of blocks in bytes (default: 64KiB, min: 4KiB, max: 512KiB)
    ##

    trace "Handling file upload"

    # Parse blockSize query parameter
    var blockSize = DefaultBlockSize
    let blockSizeStr = request.query.getString("blockSize", "")
    if blockSizeStr != "":
      let parsedSize = Base10.decode(uint64, blockSizeStr)
      if parsedSize.isErr:
        return RestApiResponse.error(Http400, "Invalid blockSize parameter")
      let size = parsedSize.get()
      # Validate block size
      if size < MinBlockSize or size > MaxBlockSize or not isPowerOfTwo(size):
        return RestApiResponse.error(
          Http400,
          "blockSize must be a power of two between " & $MinBlockSize & " and " &
            $MaxBlockSize & " bytes",
        )
      blockSize = NBytes(size)

    var bodyReader = request.getBodyReader()
    if bodyReader.isErr():
      return RestApiResponse.error(Http500, msg = bodyReader.error())

    # Attempt to handle `Expect` header
    # some clients (curl), wait 1000ms
    # before giving up
    #
    await request.handleExpect()

    var mimetype = request.headers.getString(ContentTypeHeader).some

    if mimetype.get() != "":
      let mimetypeVal = mimetype.get()
      var m = newMimetypes()
      let extension = m.getExt(mimetypeVal, "")
      if extension == "":
        return RestApiResponse.error(
          Http422, "The MIME type '" & mimetypeVal & "' is not valid."
        )
    else:
      mimetype = string.none

    const ContentDispositionHeader = "Content-Disposition"
    let contentDisposition = request.headers.getString(ContentDispositionHeader)
    let filename = getFilenameFromContentDisposition(contentDisposition)

    if filename.isSome and not isValidFilename(filename.get()):
      return RestApiResponse.error(Http422, "The filename is not valid.")

    if filename.isSome and filename.get().len > MaxFilenameSize:
      return RestApiResponse.error(
        Http422, "Filename exceeds maximum size of " & $MaxFilenameSize & " bytes"
      )

    if mimetype.isSome and mimetype.get().len > MaxMimetypeSize:
      return RestApiResponse.error(
        Http422, "Mimetype exceeds maximum size of " & $MaxMimetypeSize & " bytes"
      )

    # Here we could check if the extension matches the filename if needed

    let reader = bodyReader.get()

    try:
      without cid =? (
        await node.store(
          AsyncStreamWrapper.new(reader = AsyncStreamReader(reader)),
          filename = filename,
          mimetype = mimetype,
          blockSize = blockSize,
        )
      ), error:
        error "Error uploading file", exc = error.msg
        return RestApiResponse.error(Http500, error.msg)

      storage_api_uploads.inc()
      trace "Uploaded file", cid, blockSize
      return RestApiResponse.response($cid)
    except CancelledError:
      trace "Upload cancelled error"
      return RestApiResponse.error(Http500)
    except AsyncStreamError:
      trace "Async stream error"
      return RestApiResponse.error(Http500)
    finally:
      await reader.closeWait()

  router.api(MethodGet, "/api/storage/v1/data") do() -> RestApiResponse:
    let json = await formatManifestBlocks(node)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodOptions, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET,DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodGet, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    ## Download a file from the local node in a streaming
    ## manner
    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    await node.retrieveCid(cid.get(), local = true, resp = resp)

  router.api(MethodDelete, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Deletes either a single block or an entire dataset
    ## from the local node. Does nothing and returns 204
    ## if the dataset is not locally available.
    ##
    var headers = buildCorsHeaders("DELETE", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if err =? (await node.delete(cid.get())).errorOption:
      return RestApiResponse.error(Http500, err.msg, headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodPost, "/api/storage/v1/data/{cid}/network") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network to the local node
    ## Returns the download ID for progress tracking and cancellation.
    ##

    var headers = buildCorsHeaders("POST", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    # Start fetching the dataset in the background
    let md = ManifestDescriptor(manifest: manifest, manifestCid: cid.get())
    without downloadId =?
      (await node.startBackgroundDownload(md, selectionPolicy = spRandomWindow)), err:
      return RestApiResponse.error(Http409, err.msg, headers = headers)

    var json = %formatManifest(cid.get(), manifest)
    json["downloadId"] = %downloadId
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodDelete, "/api/storage/v1/data/{cid}/network/{downloadId}") do(
    cid: Cid, downloadId: uint64, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Cancel a specific background download
    ##

    var headers = buildCorsHeaders("DELETE", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if downloadId.isErr:
      return RestApiResponse.error(Http400, "Invalid download ID", headers = headers)

    if not node.cancelBackgroundDownload(downloadId.get(), cid.get()):
      return RestApiResponse.error(
        Http404, "Background download not found", headers = headers
      )

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodGet, "/api/storage/v1/data/{cid}/network/progress/{downloadId}") do(
    cid: Cid, downloadId: uint64, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Get progress of a specific background download
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if downloadId.isErr:
      return RestApiResponse.error(Http400, "Invalid download ID", headers = headers)

    let progress = node.getDownloadProgress(downloadId.get(), cid.get())
    if progress.isSome:
      let
        p = progress.get()
        json = %*{
          "active": true,
          "received": p.blocksCompleted,
          "total": p.totalBlocks,
          "bytes": p.bytesTransferred,
        }
      return RestApiResponse.response($json, contentType = "application/json")
    else:
      let json = %*{"active": false}
      return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/data/{cid}/network/stream") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network in a streaming
    ## manner
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    resp.setHeader("Access-Control-Expose-Headers", "Content-Disposition")
    await node.retrieveCid(cid.get(), local = false, resp = resp)

  router.api(MethodGet, "/api/storage/v1/data/{cid}/network/manifest") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download only the manifest.
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    let json = %formatManifest(cid.get(), manifest)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/data/{cid}/exists") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Only test if the give CID is available in the local store
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    let cid = cid.get()
    let hasCid = await node.hasLocalBlock(cid)

    let json = %*{$cid: hasCid}
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/space") do() -> RestApiResponse:
    let json = %RestRepoStore(
      totalBlocks: repoStore.totalBlocks,
      quotaMaxBytes: repoStore.quotaMaxBytes,
      quotaUsedBytes: repoStore.quotaUsedBytes,
      quotaReservedBytes: repoStore.quotaReservedBytes,
    )
    return RestApiResponse.response($json, contentType = "application/json")

proc initNodeApi(node: StorageNodeRef, conf: StorageConf, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  ## various node management api's
  ##
  router.api(MethodGet, "/api/storage/v1/spr") do() -> RestApiResponse:
    ## Returns node SPR in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let spr = node.discovery.getSpr()

      if $preferredContentType().get() == "text/plain":
        return RestApiResponse.response(
          spr.toURI, contentType = "text/plain", headers = headers
        )
      else:
        return RestApiResponse.response(
          $ %*{"spr": spr.toURI}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/storage/v1/peerid") do() -> RestApiResponse:
    ## Returns node's peerId in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let id = $node.switch.peerInfo.peerId

      if $preferredContentType().get() == "text/plain":
        return
          RestApiResponse.response(id, contentType = "text/plain", headers = headers)
      else:
        return RestApiResponse.response(
          $ %*{"id": id}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/storage/v1/connect/{peerId}") do(
    peerId: PeerId, addrs: seq[MultiAddress]
  ) -> RestApiResponse:
    ## Connect to a peer
    ##
    ## If `addrs` param is supplied, it will be used to
    ## dial the peer, otherwise the `peerId` is used
    ## to invoke peer discovery, if it succeeds
    ## the returned addresses will be used to dial
    ##
    ## `addrs` the listening addresses of the peers to dial, which is
    ## /ip4/0.0.0.0/tcp/<port>, where port is specified with the
    ## `--listen-port` CLI flag.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if peerId.isErr:
      return RestApiResponse.error(Http400, $peerId.error(), headers = headers)

    let addresses =
      if addrs.isOk and addrs.get().len > 0:
        addrs.get()
      else:
        without peerRecord =? (await node.findPeer(peerId.get())):
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)
        peerRecord.addresses.mapIt(it.address)
    try:
      await node.connect(peerId.get(), addresses)
      return
        RestApiResponse.response("Successfully connected to peer", headers = headers)
    except DialFailedError:
      return RestApiResponse.error(Http400, "Unable to dial peer", headers = headers)
    except CatchableError:
      return
        RestApiResponse.error(Http500, "Unknown error dialling peer", headers = headers)

proc initDebugApi(
    node: StorageNodeRef,
    autonat: Option[AutonatV2Service],
    autoRelay: Option[AutoRelayService],
    natMapper: Option[NatPortMapper],
    router: var RestRouter,
) =
  let allowedOrigin = router.allowedOrigin

  router.api(MethodGet, "/api/storage/v1/debug/info") do() -> RestApiResponse:
    ## Print rudimentary node information
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      # return pretty json for human readability
      return RestApiResponse.response(
        DebugInfo.init(node, autonat, autoRelay, natMapper).toJson(pretty = true),
        contentType = "application/json",
        headers = headers,
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodPost, "/api/storage/v1/debug/chronicles/loglevel") do(
    level: Option[string]
  ) -> RestApiResponse:
    ## Set log level at run time
    ##
    ## e.g. `chronicles/loglevel?level=DEBUG`
    ##
    ## `level` - chronicles log level
    ##
    var headers = buildCorsHeaders("POST", allowedOrigin)

    try:
      without res =? level and level =? res:
        return RestApiResponse.error(Http400, "Missing log level", headers = headers)

      try:
        {.gcsafe.}:
          updateLogLevel(level)
      except CatchableError as exc:
        return RestApiResponse.error(Http500, exc.msg, headers = headers)

      return RestApiResponse.response("")
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  when storage_enable_api_debug_peers:
    router.api(MethodGet, "/api/storage/v1/debug/peer/{peerId}") do(
      peerId: PeerId
    ) -> RestApiResponse:
      var headers = buildCorsHeaders("GET", allowedOrigin)

      try:
        trace "debug/peer start"
        without peerRecord =? (await node.findPeer(peerId.get())):
          trace "debug/peer peer not found!"
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)

        let json = %RestPeerRecord.init(peerRecord)
        trace "debug/peer returning peer record"
        return RestApiResponse.response($json, headers = headers)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500, headers = headers)

proc initRestApi*(
    node: StorageNodeRef,
    conf: StorageConf,
    repoStore: RepoStore,
    autonat: Option[AutonatV2Service],
    autoRelay: Option[AutoRelayService],
    natMapper: Option[NatPortMapper],
    corsAllowedOrigin: ?string,
): RestRouter =
  var router = RestRouter.init(validate, corsAllowedOrigin)

  initDataApi(node, repoStore, router)
  initNodeApi(node, conf, router)
  initDebugApi(node, autonat, autoRelay, natMapper, router)

  return router
