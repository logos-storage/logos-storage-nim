# NAT name-download scenario

## Scenario

Three nodes are each behind their own NAT, so all are Kad clients. A publishes a
file under a name. B resolves the name and downloads the file. A publishes a
second file under the same name. B resolves the same name again and gets the
second file. D downloads the second file too. A stops. B still resolves the
name. B gets the second file from D into a fresh data dir.

## Topology

```
node A ── lan1 ── router1 (NAT) ──┐
node B ── lan2 ── router2 (NAT) ──┼── wan ── bootstrap (relay + autonat, DHT server)
node D ── lan3 ── router3 (NAT) ──┘
```

- **bootstrap**: public node on the wan (`--nat=extip`), autonat + relay server,
  the only DHT server.
- **router1 / router2 / router3**: `lan -> wan` masquerade, no inbound forward.
- **node A** (`publisher`): behind router1, `nat=auto`. It publishes the name.
- **node B** (`downloader`): behind router2, `nat=auto`. It resolves the name
  and downloads. Its data dir is a tmpfs, so a restart empties it.
- **node D** (`second-downloader`): behind router3, `nat=auto`. It downloads the
  second file and serves it to B once A has stopped.

AutoNAT finds A, B and D NotReachable. Each takes a relay reservation on the
bootstrap and announces its circuit address. A node without a circuit address
doesn't announce what it stores.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/name-download/testnamedownload.nim
```

Rootless, but needs the host netfilter modules. If a router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

1. A, B and D are NotReachable and in client mode. Each announces a circuit
   address.
2. A uploads file 1 and publishes it under the label `catalog`. The REST call
   returns the name key.
3. B resolves the name key to the CID of file 1, downloads it, and gets the same
   bytes.
4. A uploads file 2 and publishes it under `catalog` again. The name key doesn't
   change.
5. B resolves the same name key to the CID of file 2, downloads it, and gets the
   same bytes.
6. D resolves the name key and downloads file 2 completely.
7. A stops.
8. B resolves the name key again and still gets the CID of file 2. The name
   record lives 8 hours after A's last publish.
9. B restarts with a fresh data dir. It downloads file 2 again and gets the same
   bytes, served by D.

Per-run container logs are written before teardown to
`tests/integration/logs/<timestamp>__NAT_name_download/<test>/<service>.log`.
