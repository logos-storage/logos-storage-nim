# DHT provider lookups through MixTransport

With `--mix-enabled=true`, a client asks a proxy from its configured
`--dht-mix-proxy` records or its discovered proxy services to find providers. The proxy is the final Mix hop and
terminates a reliable MixTransport stream. The proxy runs the direct DHT lookup
on behalf of the client and returns provider peer records on that same stream.
MixTransport segments the response across Mix packets and supplies reply SURBs.
There is no separate connection from a Mix exit to the proxy and no destination-read
callback for the DHT proxy protocol.

Storage shares its MixTransport service between provider downloads and proxy
lookups. The client opens a lookup stream on first use of a proxy and reuses it
for subsequent lookups to that peer. A request ID lets the proxy return the
providers for a later lookup while an earlier DHT search is still running.
Requests on the same stream are linkable at the proxy.

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

The codec remains `/storage/dht-proxy/2.0.0`. The multiplexed schema adds a
required field to requests and replies. Upgrade both endpoints together,
including clients that learn their proxies through service discovery.

## Wire format

Each direction carries length-prefixed protobuf messages. The unsigned varint
prefix gives the message length in bytes. Writers finish each message before
starting the next. A reply can span several Mix packets.

| Field | Request | Response |
| --- | --- | --- |
| 1 | Required query type (`FindProviders = 0`) | Required status |
| 2 | Required binary CID | Repeated encoded provider peer records |
| 3 | Required unsigned 64-bit request ID | Required request ID echoed from the request |

IDs increase from 1 on each client stream. Two calls for the same CID have
distinct IDs. The client dispatches each complete reply by ID. An idle stream
can be closed and reopened on the next lookup. Losing a stream fails the calls
still waiting on it.

## Limits and failures

Requests are limited to 4 KiB and responses to 256 KiB, excluding the length
prefix. The proxy returns the longest prefix of whole provider records that
fits with the status and request ID. It returns `ErrResponseTooLarge` if the
first record exceeds the budget and `NotFound` if the search found no providers.

A client needs a usable local Mix address and a started transport. Discovery
tries eligible proxies in random order within the lookup deadline. A successful
`NotFound` completes the lookup with an empty result. If every attempt fails,
the client returns an error.

The proxy limits concurrent lookups across clients to 100 by default
(`--dht-proxy-max-inflight` in Storage). A valid request over lookup capacity
receives `ErrTooBusy` with its request ID. An idle stream takes no lookup slot.

The client accepts up to 32 callers per stream. Four can await replies at once.
Additional callers wait for a slot within their lookup deadline. The 90-second lookup
deadline includes dialing, waiting to write and waiting for a reply. Cancelling
a caller after the complete request has been sent detaches that caller. A
partial write closes the stream because later messages need an intact length
prefix and body.

Each proxy accepts up to 128 open streams and up to four concurrent lookups per
stream. A new stream has five seconds to send its first byte. A worker retains
its slot through the reply write. An incomplete request
has five seconds to arrive after its first byte. The idle timeout is 90 seconds
after outstanding work finishes. The proxy closes a stream on a zero, repeated,
decreasing or unreadable ID. A malformed request with a recoverable ID receives
a correlated decode error.
