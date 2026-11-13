# autonat-relay-discovery

The bootstrap is a plain public node. AutoNAT and relay run on two other public
nodes that nobody knows about, so they can only be found through service
discovery.

- autonat_server: `--autonat-server`
- relay_server: `--relay-server`
- node: behind NAT, must find both to become `NotReachable` with a circuit address
- client: public without extip, must find the AutoNAT server to become `Reachable`

```
node ── lan ── router ── wan ─┬─ bootstrap
                              ├─ autonat_server
                              ├─ relay_server
                              └─ client
```

Node API on `127.0.0.1:18095`, client on `127.0.0.1:18096`.

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/autonat-relay-discovery/testautonatrelaydiscovery.nim
```

The node's circuit addresses all go through relay_server (71.71.71.12). The
client downloads the node's file through it.
