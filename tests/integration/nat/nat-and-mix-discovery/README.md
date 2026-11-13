# nat-and-mix-discovery

Seeder and leecher are behind NAT and run with `--mix-enabled` only. No
`--mix-pool-json`, no `--dht-mix-proxy`. They have to find everything through
service discovery.

Public nodes, one service each:

- bootstrap: `--autonat-server`
- relay_server: `--relay-server`
- mix_relay_1..4: `--mix-enabled`
- dht_proxy: `--dht-proxy-server`

```
seeder  ── seeder_lan  ── seeder_router  ──┐         bootstrap
                                           │         relay_server
                                           ├── wan ─ mix_relay_1..4
                                           │         dht_proxy
leecher ── leecher_lan ── leecher_router ──┘
```

Seeder API on `127.0.0.1:18093`, leecher on `127.0.0.1:18094`.

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/nat-and-mix-discovery/testnatandmixdiscovery.nim
```

The leecher downloads the seeder's file over Mix.
