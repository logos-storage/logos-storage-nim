# NAT nat-and-mix scenario

## Scenario

Two nodes are each behind their **own** NAT, and both route their DHT provider
queries through a pool of public Mix proxies. Both nodes are `NotReachable` and
take a relay reservation, so the leecher must find the seeder's provider record
over Mix and then download from it through the relay.

This is the common deployment shape: private endpoints, public Mix relays.

## Topology

```
seeder  ── seeder_lan  ── seeder_router (NAT)  ──┐
                                                 │        mix_proxy_1 (bootstrap)
                                                 ├── wan ─ mix_proxy_2
                                                 │        mix_proxy_3
leecher ── leecher_lan ── leecher_router (NAT) ──┘        mix_proxy_4
```

- **mix_proxy_1..4** — public nodes on the wan, started with `--nat=extip`,
  autonat + relay servers, `--mix-enabled` and `--dht-proxy-server`. `mix_proxy_1` is the primary
  bootstrap node; the other three bootstrap off it.
- **seeder_router / leecher_router** — `lan -> wan` masquerade, *no* inbound
  forward, so each node can dial out but nothing can dial back in.
- **seeder** — on `seeder_lan`, `nat=auto`. AutoNAT finds it unreachable, so it
  takes a relay reservation and announces its circuit address. Uploads the file.
  REST API on `127.0.0.1:18090`.
- **leecher** — on `leecher_lan`, same NATed setup. Downloads the file.
  REST API on `127.0.0.1:18091`.

Both nodes get all four proxies as `--dht-mix-proxy` entries plus a
`--mix-pool-json` pool built from the proxies' `/debug/info`.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/nat-and-mix/testnatandmix.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if a router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

Both nodes report `NotReachable` and announce a `p2p-circuit` address, and both
report `privateQueries == true`, meaning their DHT lookups go through Mix. The
seeder uploads a file, and the leecher fetches the same content back after
resolving the provider record over Mix.

Per-run container logs (routers, mix proxies, seeder, leecher) are written before
teardown to
`tests/integration/logs/<timestamp>__Mix_queries_with_NATted_endpoints/<test>/<service>.log`.
