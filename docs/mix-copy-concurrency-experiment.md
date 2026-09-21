# Experiment: overlapping redundant reverse Data sends

Date: 2026-09-21. This is an experimental record, not a production design change.

## Question and controlled change

The recipient sends two copies of each reverse Data frame using two distinct
SURBs. Previously, the second send began only after the first send completed its
sampled sender delay and first-hop write. The experiment starts both sends, then
waits for both before returning to the chunk-writing loop.

Every packet still goes through the normal Mix send implementation, including its
full sampled sender delay. Relay delays are unchanged. Control-frame sends remain
sequential. The session reply-send lock still covers the complete redundancy
batch, so this experiment does not pipeline successive Data chunks within that
session. The default build retains sequential sending; the experimental build
uses `-d:mixExperimentConcurrentDataCopies`.

For two independent exponential sender delays with a 100 ms mean, the expected
sum is 200 ms and the expected maximum is 150 ms. Thus the delay-only prediction
is about 25% less time for sending the reverse response, not a twofold speedup.

## Setup and reproduction

Storage base revision: `7ae9722671f943323a96eef1b710a090864be809`.
MixTransport base revision: `edd24234a2bf067986d3cce8d634382b9317c492`, plus
the experimental change in `libp2p_mix_transport/transport.nim`, now committed as
`6dc5bd73c4b884e9b9f9c95b49f10c76607bde0c`. The committed files exactly match
the locally tested implementation and packaged tests.
The experiment branches in Storage and MixTransport are both named
`experiment/concurrent-surb-copies`. Storage must pin the committed MixTransport
revision in its submodule; matching branch names alone do not select a dependency.

### Selecting the recorded dependency

From Storage, fetch and select the exact experiment commit in a clean submodule:

```bash
git -C vendor/libp2p-mix-transport fetch origin experiment/concurrent-surb-copies
git -C vendor/libp2p-mix-transport switch --detach 6dc5bd73c4b884e9b9f9c95b49f10c76607bde0c
git add vendor/libp2p-mix-transport docs/mix-copy-concurrency-experiment.md
```

Once the Storage submodule pointer is committed, another checkout can reproduce the dependency with
`git submodule update --init --recursive`.

### Tests and builds

From the standalone MixTransport checkout, the focused tests are included in the
normal test entry point:

```bash
make test NIMFLAGS='-d:disableMarchNative'
make test NIMFLAGS='-d:disableMarchNative -d:mixExperimentConcurrentDataCopies'
```

Build both variants from the Storage repository:

```bash
make -j24 NIMFLAGS='-d:disableMarchNative --out:build/storage-sequential-copies'
make -j24 NIMFLAGS='-d:disableMarchNative -d:mixExperimentConcurrentDataCopies --out:build/storage-concurrent-copies'
```

The experiment uses the local harness's `experiments/mix-smoke.bash` convenience
helper. That helper must be present; it is not supplied by either of these two
repositories. The recorded runs used harness base commit `6642b56` plus the local
helper (SHA-256 `9a1d5e62bd43b45867b46228111c0d82e1eb687d0f78bd27384189dc00069c86`).
For reproduction on a fresh machine, preserve or commit that helper in the
harness repository as well. Build `mix_pool` with `make mix-tools NIMFLAGS='-d:disableMarchNative'` in
Storage if it is not already available.

From the local harness repository, run each variant separately:

```bash
STORAGE_BINARY="$PWD/../logos-storage-nim/build/storage-sequential-copies" \
  OUTPUTS="$PWD/outputs/copy-baseline" \
  timeout --signal=INT --kill-after=20s 180s bash experiments/mix-smoke.bash 1

STORAGE_BINARY="$PWD/../logos-storage-nim/build/storage-concurrent-copies" \
  OUTPUTS="$PWD/outputs/copy-concurrent" \
  timeout --signal=INT --kill-after=20s 180s bash experiments/mix-smoke.bash 1
```

Each run uses fresh nodes and a fresh 1 MiB file: one seeder, one downloader, five
local Storage-backed Mix relays, default Mix delays, TRACE endpoint logging and
INFO relay logging. Runs alternate baseline/concurrent; there is no injected
network loss. These are comparable configurations, not identical random delay
samples or identical routes. The helper checks the downloaded bytes against the
original and records executable hashes in `run-info.txt`.

Results directory for this experiment:

```text
/home/mc2/code/logos-storage/logos-storage-local-harness/outputs/copy-concurrency-wgz5oN3H
```

Each `sequential-N` or `concurrent-N` subdirectory contains a smoke run with
`report.log`, `timings.csv`, `run-info.txt`, and per-node logs below `k-node-*`.
End-to-end time comes from `timings.csv`. Response-send time is the interval
between the seeder's `Sending WantBlocks response` and `WantBlocks response sent`
messages; it measures completion of the send operation, not final receipt.

## Results

All six runs completed successfully and passed byte-for-byte file verification.

| Pair | Sequential total | Concurrent total | Sequential response send | Concurrent response send |
| --- | ---: | ---: | ---: | ---: |
| 1 | 61.961 s | 47.902 s | 56.228 s | 42.138 s |
| 2 | 63.757 s | 49.233 s | 58.021 s | 43.931 s |
| 3 | 63.370 s | 49.187 s | 56.802 s | 42.326 s |
| Mean | 63.029 s | 48.774 s | 57.017 s | 42.798 s |

Mean end-to-end duration fell by 22.6%; effective file throughput increased from
16.25 to 20.99 KiB/s, approximately 29%. Mean response-send duration fell by 24.9%,
closely matching the delay-only prediction. The remainder of the end-to-end time
was approximately six seconds in both configurations.

During each response-send interval, the seeder logged exactly 275 unique Data
chunks and 550 outbound copies, two per chunk. The reduction therefore did not
come from reducing the response size or redundancy. These are transport
submission traces, not packet captures or proof that every redundant copy arrived.

This small comparison supports the hypothesis that sequential sender holds are
a substantial bottleneck in this workload. It does not establish a general
performance bound. Random routes and delay samples were not paired or seeded;
the experiment has only three runs per configuration.

### Confirmation after committing the experiment

Rebuilt both binaries from Storage `441ca680` and its clean MixTransport submodule
at `6dc5bd73c4b884e9b9f9c95b49f10c76607bde0c`, then repeated one fresh pair on
2026-09-21. Both downloads passed byte-for-byte verification:

| Variant | End-to-end time, 1 MiB |
| --- | ---: |
| Sequential copies | 62.292 s |
| Concurrent copies | 47.356 s |

This confirmation pair took approximately 24% less time with concurrent copies,
consistent with the original comparison. It is a smoke confirmation, not an
additional load or anonymity assessment. Logs and executable hashes are retained
under:

```text
/home/mc2/code/logos-storage/logos-storage-local-harness/outputs/copy-confirmation-0FI1datu
```

## Safety and interpretation

The focused MixTransport test `tests/test_surb_copy_sending.nim` confirms that both copies
start before either completes, the caller waits for completion, and cancellation
cancels and drains both owned sends. Both tests passed. The experiment retains
the existing rule that at least one successful copy makes a redundancy batch
successful. After packaging the experiment into the standalone MixTransport
branch, all 87 tests passed both with the default build and with
`-d:mixExperimentConcurrentDataCopies`. The focused completion test now also
checks that finishing only the first copy leaves the batch pending.

The two-send bound is per redundancy batch, not a global admission limit across
sessions. Mix's task tracking should not be mistaken for a bounded packet queue.
These one-downloader measurements cannot establish relay overload behaviour or
safe concurrency limits under load.

Preserving each packet's delay does not prove identical anonymity properties:
overlapping delays changes packet spacing. Any production adoption needs a
separate traffic-pattern and overload review. No packet-delay bypass or
fire-and-forget sending is proposed here.
