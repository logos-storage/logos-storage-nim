import std/strutils
import std/sequtils

from pkg/libp2p import Cid, `$`, init
import pkg/questionable/results
import pkg/chronos/apps/http/[httpserver, shttpserver, httpclient, httptable]
import pkg/storage/logutils
import pkg/storage/rest/json
import pkg/storage/errors

export httptable, httpclient

type StorageClient* = ref object
  baseurl: string
  session: HttpSessionRef

type HasBlockResponse = object
  has: bool

proc new*(_: type StorageClient, baseurl: string): StorageClient =
  StorageClient(session: HttpSessionRef.new(), baseurl: baseurl)

proc close*(self: StorageClient): Future[void] {.async: (raises: []).} =
  await self.session.closeWait()

proc request(
    self: StorageClient,
    httpMethod: httputils.HttpMethod,
    url: string,
    body: openArray[char] = [],
    headers: openArray[HttpHeaderTuple] = [],
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  HttpClientRequestRef
    .new(
      self.session,
      url,
      httpMethod,
      version = HttpVersion11,
      flags = {},
      maxResponseHeadersSize = HttpMaxHeadersSize,
      headers = headers,
      body = body.toOpenArrayByte(0, len(body) - 1),
    ).get
    .send()

proc post*(
    self: StorageClient,
    url: string,
    body: string = "",
    headers: seq[HttpHeaderTuple] = @[],
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodPost, url, headers = headers, body = body)

proc get(
    self: StorageClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodGet, url, headers = headers)

proc delete(
    self: StorageClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodDelete, url, headers = headers)

proc body*(
    response: HttpClientResponseRef
): Future[string] {.async: (raises: [CancelledError, HttpError]).} =
  return bytesToString (await response.getBodyBytes())

proc getContent(
    client: StorageClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(url, headers)
  return await response.body

proc info*(
    client: StorageClient
): Future[?!JsonNode] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(client.baseurl & "/debug/info")
  return JsonNode.parse(await response.body)

proc setLogLevel*(
    client: StorageClient, level: string
): Future[void] {.async: (raises: [CancelledError, HttpError]).} =
  let
    url = client.baseurl & "/debug/chronicles/loglevel?level=" & level
    headers = @[("Content-Type", "text/plain")]
    response = await client.post(url, headers = headers, body = "")
  assert response.status == 200

proc uploadRaw*(
    client: StorageClient,
    contents: string,
    headers: seq[HttpHeaderTuple] = @[],
    advertise = true,
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.post(
    client.baseurl & "/data?advertise=" & $advertise, body = contents, headers = headers
  )

proc upload*(
    client: StorageClient, contents: string, advertise = true
): Future[?!Cid] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.uploadRaw(contents, advertise = advertise)
  assert response.status == 200
  Cid.init(await response.body).mapFailure

proc upload*(
    client: StorageClient, bytes: seq[byte]
): Future[?!Cid] {.async: (raw: true).} =
  return client.upload(string.fromBytes(bytes))

proc getAdvertise*(
    client: StorageClient, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(client.baseurl & "/data/" & $cid & "/advertise")

  if response.status != 200:
    return failure($response.status)

  let jsonData = JsonNode.parse(await response.body)
  if jsonData.isErr:
    return failure(jsonData.error)

  let advertiseNode = jsonData.get.getOrDefault("advertise")
  if advertiseNode.isNil:
    return failure("missing advertise in response")

  success advertiseNode.getBool()

proc setAdvertise*(
    client: StorageClient, cid: Cid, advertise: bool
): Future[?!void] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.post(
    client.baseurl & "/data/" & $cid & "/advertise?advertise=" & $advertise
  )

  if response.status != 200:
    return failure($response.status)

  success()

proc downloadRaw*(
    client: StorageClient, cid: string, local = false
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return
    client.get(client.baseurl & "/data/" & cid & (if local: "" else: "/network/stream"))

proc downloadBytes*(
    client: StorageClient, cid: Cid, local = false
): Future[?!seq[byte]] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.downloadRaw($cid, local = local)

  if response.status != 200:
    return failure($response.status)

  success await response.getBodyBytes()

proc download*(
    client: StorageClient, cid: Cid, local = false
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  without response =? await client.downloadBytes(cid, local = local), err:
    return failure(err)
  return success bytesToString(response)

proc downloadNoStream*(
    client: StorageClient, cid: Cid
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.post(client.baseurl & "/data/" & $cid & "/network")

  if response.status != 200:
    return failure($response.status)

  success await response.body

proc downloadManifestOnly*(
    client: StorageClient, cid: Cid
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response =
    await client.get(client.baseurl & "/data/" & $cid & "/network/manifest")

  if response.status != 200:
    return failure($response.status)

  success await response.body

proc startDownload*(
    client: StorageClient, cid: Cid
): Future[?!uint64] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.post(client.baseurl & "/data/" & $cid & "/network")

  if response.status != 200:
    return failure($response.status)

  without jsonData =? JsonNode.parse(await response.body), err:
    return failure(err)
  let idNode = jsonData.getOrDefault("downloadId")
  if idNode.isNil:
    return failure("missing downloadId in response")
  success idNode.getInt().uint64

proc getDownloadProgress*(
    client: StorageClient, cid: Cid, downloadId: uint64
): Future[?!JsonNode] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/data/" & $cid & "/network/progress/" & $downloadId
  let response = await client.get(url)

  if response.status != 200:
    return failure($response.status)

  return JsonNode.parse(await response.body)

proc deleteRaw*(
    client: StorageClient, cid: string
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.delete(client.baseurl & "/data/" & cid)

proc delete*(
    client: StorageClient, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.deleteRaw($cid)

  if response.status != 204:
    return failure($response.status)

  success()

proc listRaw*(
    client: StorageClient
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.get(client.baseurl & "/data")

proc list*(
    client: StorageClient
): Future[?!RestContentList] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.listRaw()

  if response.status != 200:
    return failure($response.status)

  RestContentList.fromJson(await response.body)

proc hasBlock*(
    client: StorageClient, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/data/" & $cid & "/exists"
  let body = await client.getContent(url)
  let response = HasBlockResponse.fromJson(body)
  if response.isErr:
    return failure "Failed to parse has block response"
  return response.get.has.success

proc hasBlockRaw*(
    client: StorageClient, cid: string
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  let url = client.baseurl & "/data/" & cid & "/exists"
  return client.get(url)
