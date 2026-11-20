# NAT name-no-server scenario

## Scenario

Two nodes are each behind their own NAT, so both are Kad clients. The bootstrap
is the only DHT server. A publishes a name while the bootstrap is stopped:
publish succeeds, but no server holds the name record, so B can't resolve it.
Once A restarts, it publishes its name records again and B resolves the name.

## Topology

```
node A ── lan1 ── router1 (NAT) ──┐
                                  ├── wan ── bootstrap (relay + autonat, DHT server)
node B ── lan2 ── router2 (NAT) ──┘
```

- **bootstrap**: public node on the wan (`--nat=extip`), autonat + relay server.
  Its key and IP stay the same across a restart.
- **router1 / router2**: `lan -> wan` masquerade, no inbound forward.
- **node A** (`publisher`): behind router1, NotReachable, publishes the name.
- **node B** (`resolver`): behind router2, NotReachable, resolves the name.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/name-no-server/testnamenoserver.nim
```

Rootless, but needs the host netfilter modules. If a router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

1. A and B are NotReachable and in client mode.
2. With the bootstrap stopped, A publishes a name: 200.
3. B doesn't get a CID for the name (404 or 500).
4. The bootstrap starts again. A restarts. B resolves the name to A's CID.

Per-run container logs are written before teardown to
`tests/integration/logs/<timestamp>__NAT_name_with_no_server/<test>/<service>.log`.
