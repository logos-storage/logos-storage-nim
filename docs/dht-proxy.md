# DHT provider lookups through MixTransport

With `--mix-enabled=true`, a client asks a proxy from its configured
`--dht-mix-proxy` records or its discovered proxy services to find providers. The proxy is the final Mix hop and
terminates a reliable MixTransport stream. The proxy runs the direct DHT lookup
on behalf of the client and returns provider peer records on that same stream.
MixTransport segments the response across Mix packets and supplies reply SURBs.
There is no separate connection from a Mix exit to the proxy and no destination-read
callback for the DHT proxy protocol.

Storage shares its MixTransport service between provider downloads and proxy
lookups. Each lookup opens its own stream; closing that stream leaves the shared
session available to other operations. Server shutdown stops the shared service.

## Configuration and compatibility

Each configured proxy signed peer record must contain a `/mix-transport` address carrying
its Mix public information. The embedded peer identity must match the record's
peer ID. An ordinary TCP address alone is insufficient. The client obtains the
proxy's Mix public information from its advertised address. Discovered proxy
records are checked for the same address and matching identity. The proxy need not appear in the client's
relay pool, but both nodes still require usable Mix routing information.

Run an updated Storage node with `--dht-proxy-server`, or the updated `mix_relay_dht`
tool with its DHT proxy enabled. Both start MixTransport and mount the proxy
protocol. A dedicated Storage proxy advertises its Mix address and proxy service.
Adding `--mix-enabled` also enables Mix downloads and, on a public node, relay advertisement.
The tool's generated signed peer records include its Mix advertisement;
redistribute the updated record to clients. Relay-only mode does not serve lookups.

The stream protocol uses `/storage/dht-proxy/2.0.0`. Protobuf field numbers and
status values are unchanged. Version 1 proxies are incompatible with the new
transport topology and response limits. Clients do not retry the legacy protocol
or make a direct DHT query when a Mix lookup fails. Deploy updated proxies and
replace their configured records before switching clients.

## Limits and failures

A stream carries one length-prefixed `FindProviders(CID)` request and one
length-prefixed response. The client closes the stream after reading the reply.
On MixTransport streams, the proxy waits for that close so the client can consume buffered response data.
Requests are limited to 4 KiB and responses to 256 KiB,
independently of Mix packet size. The proxy returns the largest prefix of provider
records that fits the response limit. If even the first record cannot fit, the
proxy returns `ErrResponseTooLarge`. An empty result returns `NotFound`.

The client requires a usable local Mix address and a started transport. Missing
Mix information, unavailable proxies, unsupported codecs, and remote error
statuses fail the attempt. Discovery tries the remaining proxy candidates in
random order. A successful `NotFound` response completes the lookup with an empty
result. Exhausting the candidates returns an error without direct fallback.

Each proxy attempt has a 90-second deadline covering session establishment,
stream opening, and the request/response exchange. Timeout or cancellation cancels
the exchange and closes its stream. The proxy limits concurrent exchanges to
100 by default (`--dht-proxy-max-inflight` in Storage), reads the request within
five seconds, and bounds the full exchange to 90 seconds. Requests beyond capacity
receive `ErrTooBusy`. These limits bound application messages and work; MixTransport
also applies its own stream and session limits.
