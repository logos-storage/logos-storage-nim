import std/json
import std/times
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/questionable/results
import pkg/stew/byteutils
import ../twonodes

twonodessuite "Names":
  const
    AllowedOrigin = "http://localhost:3000"
    # A space, a slash, an ampersand and a non-ASCII character: the client
    # percent-encodes them.
    SpecialLabel = "my catalog/é&v=1"

  let namesConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withExtIp(1)
      .withAutonatServer(0)
      .withApiCorsOrigin(0, AllowedOrigin)
      .withApiCorsOrigin(1, "null").some
  )

  let wildcardConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withExtIp(1)
      .withAutonatServer(0)
      .withApiCorsOrigin(0, "*").some
  )

  let noSchemeConfig = NodeConfigs(
    clients: StorageConfigs
      .init(nodes = 2)
      .withExtIp(1)
      .withAutonatServer(0)
      .withApiCorsOrigin(0, "localhost:3000").some
  )

  proc unpublishedNameKey(): string =
    let hash = MultiHash.digest("sha2-256", "never published".toBytes).get
    $Cid.init(CIDv1, multiCodec("storage-name"), hash).get

  proc peerIdOf(
      client: StorageClient
  ): Future[string] {.async: (raises: [CatchableError]).} =
    let info = (await client.info()).get
    info["id"].getStr()

  test "a name published on one node resolves on another node", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let published = await client1.publishNameRaw(@{"label": "catalog", "cid": $cid})

    check published.status == 200

    let nameKey = await published.body
    let resolved = await client2.resolveNameRaw(nameKey)

    check resolved.status == 200

    check (await resolved.body) == $cid

  test "a name resolves on another node by the peer ID and a percent-encoded label",
    namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let published = await client1.publishNameRaw(@{"label": SpecialLabel, "cid": $cid})

    check published.status == 200

    let peerId = await client1.peerIdOf()
    let resolved = await client2.resolveNameByKeyRaw(peerId, SpecialLabel)

    check resolved.status == 200

    check (await resolved.body) == $cid

  test "publish takes the current time when seqnum is missing", namesConfig:
    let
      cid = (await client1.upload("catalog contents")).get
      currentTime = getTime().toUnix()

    let first = await client1.publishNameRaw(@{"label": "catalog", "cid": $cid})

    check first.status == 200

    # Publish with the current time minus 60 seconds to ensure that the
    # previous call used the current time by default.
    let older = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid, "seqnum": $(currentTime - 60)}
    )

    check older.status == 400

    # Publish with the current time plus 60 seconds to ensure that the
    # previous call didn't use a seqnum from the future.
    let newer = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid, "seqnum": $(currentTime + 60)}
    )

    check newer.status == 200

  test "publish takes the current time when seqnum is 0", namesConfig:
    let
      cid = (await client1.upload("catalog contents")).get
      currentTime = getTime().toUnix()

    let first =
      await client1.publishNameRaw(@{"label": "catalog", "cid": $cid, "seqnum": "0"})

    check first.status == 200

    # Publish with the current time minus 60 seconds to ensure that the
    # previous call used the current time, not 0.
    let older = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid, "seqnum": $(currentTime - 60)}
    )

    check older.status == 400

  test "publish passes a non-zero seqnum to the publisher", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let first =
      await client1.publishNameRaw(@{"label": "catalog", "cid": $cid, "seqnum": "10"})

    check first.status == 200

    let lower =
      await client1.publishNameRaw(@{"label": "catalog", "cid": $cid, "seqnum": "9"})

    check lower.status == 400

  test "publish refuses a seqnum that is not a uint64", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let notANumber =
      await client1.publishNameRaw(@{"label": "catalog", "cid": $cid, "seqnum": "abc"})
    let negative =
      await client1.publishNameRaw(@{"label": "catalog", "cid": $cid, "seqnum": "-1"})

    check notANumber.status == 400
    check negative.status == 400

  test "publish refuses a request without a label", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(@{"cid": $cid})

    check response.status == 400

  test "publish refuses a cid that is not a CID", namesConfig:
    let response =
      await client1.publishNameRaw(@{"label": "catalog", "cid": "not-a-cid"})

    check response.status == 400

  test "publish accepts the Origin of --api-cors-origin", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid}, headers = @[("Origin", AllowedOrigin)]
    )

    check response.status == 200

  test "publish refuses another Origin", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid},
      headers = @[("Origin", "http://other.example")],
    )

    check response.status == 403

  test "publish refuses the Origin null, even when --api-cors-origin is null",
    namesConfig:
    let cid = (await client2.upload("catalog contents")).get

    let response = await client2.publishNameRaw(
      @{"label": "catalog", "cid": $cid}, headers = @[("Origin", "null")]
    )

    check response.status == 403

  test "publish accepts an http Origin when --api-cors-origin doesn't have a scheme",
    noSchemeConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid},
      headers = @[("Origin", "http://localhost:3000")],
    )

    check response.status == 200

  test "publish refuses another Origin when --api-cors-origin doesn't have a scheme",
    noSchemeConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid}, headers = @[("Origin", "http://evil.example")]
    )

    check response.status == 403

  test "publish accepts any Origin when --api-cors-origin is *", wildcardConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid},
      headers = @[("Origin", "http://other.example")],
    )

    check response.status == 200

  test "publish refuses the Origin null when --api-cors-origin is *", wildcardConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid}, headers = @[("Origin", "null")]
    )

    check response.status == 403

  test "publish refuses a request with two Origin headers", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    # Both are the allowed origin: only the second header can make it fail.
    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid},
      headers = @[("Origin", AllowedOrigin), ("Origin", AllowedOrigin)],
    )

    check response.status == 403

  test "publish refuses any Origin when --api-cors-origin is not set", twoNodesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let response = await client1.publishNameRaw(
      @{"label": "catalog", "cid": $cid}, headers = @[("Origin", AllowedOrigin)]
    )

    check response.status == 403

  test "stop publishing deletes the name record of a label", namesConfig:
    let
      cid = (await client1.upload("catalog contents")).get
      otherCid = (await client1.upload("other catalog contents")).get

    let published = await client1.publishNameRaw(
      @{"label": SpecialLabel, "cid": $cid, "seqnum": "10"}
    )

    check published.status == 200

    let stopped = await client1.stopPublishingNameRaw(@{"label": SpecialLabel})

    check stopped.status == 204

    # If the name record were still stored, the same seqnum with another CID
    # would be refused.
    let republished = await client1.publishNameRaw(
      @{"label": SpecialLabel, "cid": $otherCid, "seqnum": "10"}
    )

    check republished.status == 200

  test "stop publishing refuses a request without a label", namesConfig:
    let response = await client1.stopPublishingNameRaw(@[])

    check response.status == 400

  test "resolve returns 404 when the DHT doesn't have a name record for the name key",
    namesConfig:
    let response = await client2.resolveNameRaw(unpublishedNameKey())

    check response.status == 404

  test "resolve refuses a name key that is not a CID", namesConfig:
    let response = await client1.resolveNameRaw("not-a-cid")

    check response.status == 400

  test "any node can refresh a name published by another node", namesConfig:
    let cid = (await client1.upload("catalog contents")).get

    let published = await client1.publishNameRaw(@{"label": "catalog", "cid": $cid})

    check published.status == 200

    let nameKey = await published.body
    let refreshed = await client2.refreshNameRaw(nameKey)

    check refreshed.status == 204

  test "refresh returns 404 when the DHT doesn't have a name record for the name key",
    namesConfig:
    let response = await client2.refreshNameRaw(unpublishedNameKey())

    check response.status == 404

  test "refresh refuses another Origin", namesConfig:
    let response = await client2.refreshNameRaw(
      unpublishedNameKey(), headers = @[("Origin", "http://other.example")]
    )

    check response.status == 403

  test "refresh refuses a name key that is not a CID", namesConfig:
    let response = await client1.refreshNameRaw("not-a-cid")

    check response.status == 400

  test "resolve by peer ID returns 404 when the DHT doesn't have a name record for the label",
    namesConfig:
    let peerId = await client1.peerIdOf()
    let response = await client2.resolveNameByKeyRaw(peerId, "never-published")

    check response.status == 404

  test "resolve by peer ID refuses a peer ID that is not valid", namesConfig:
    let response = await client1.resolveNameByKeyRaw("not-a-peer-id", "catalog")

    check response.status == 400
