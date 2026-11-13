# multi-service-discovery

Same as nat-and-mix-discovery, but every public node provides all services:
`--autonat-server --relay-server --mix-enabled --dht-proxy-server`. The
bootstrap is a plain public node.

All public nodes are in 7.7.7.0/24. Storage now sets `ipSimCoefficient = 0`, 
so a registrar doesn't delay an advertisement because it already holds one from
the same IP or subnet. Without it, a node's second and later services would
wait ~15 min before discovery finds them.

```
seeder  ── seeder_lan  ── seeder_router  ──┐
                                           ├── wan ─ bootstrap
                                           │         public_node_1..4
leecher ── leecher_lan ── leecher_router ──┘
```

Seeder API on `127.0.0.1:18097`, leecher on `127.0.0.1:18098`.

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/multi-service-discovery/testmultiservicediscovery.nim
```

The leecher downloads the seeder's file over Mix.
