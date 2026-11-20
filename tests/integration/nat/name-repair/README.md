# NAT name-repair scenario

## Scenario

Three nodes are each behind their own NAT, so all are Kad clients. The bootstrap
is the only DHT server. A publishes a name, then stops. B resolves the name and
keeps a local copy. The bootstrap restarts and loses the name record. When B
resolves again, it puts the name record back on the bootstrap, and C, which
never resolved the name before, gets the CID.

## Topology

```
node A ── lan1 ── router1 (NAT) ──┐
node B ── lan2 ── router2 (NAT) ──┼── wan ── bootstrap (relay + autonat, DHT server)
node C ── lan3 ── router3 (NAT) ──┘
```

- **bootstrap**: public node on the wan (`--nat=extip`), autonat + relay server.
  Its key and IP stay the same across a restart. Its name records don't.
- **router1 / router2 / router3**: `lan -> wan` masquerade, no inbound forward.
- **node A** (`publisher`): behind router1, publishes the name.
- **node B** (`resolver`): behind router2, resolves the name before and after
  the restart.
- **node C** (`late-resolver`): behind router3, resolves the name only after
  the restart.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/name-repair/testnamerepair.nim
```

Rootless, but needs the host netfilter modules. If a router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

1. A, B and C are NotReachable and in client mode.
2. A publishes a name: 200. A stops.
3. B resolves the name to A's CID.
4. The bootstrap restarts. It resolves the name through its own API: 404. Its
   table has no peers.
5. B resolves the name again. C then resolves the name to A's CID.

Per-run container logs are written before teardown to
`tests/integration/logs/<timestamp>__NAT_name_repair/<test>/<service>.log`.
