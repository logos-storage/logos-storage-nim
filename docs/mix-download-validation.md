# Mix Transport integration: validation and open questions

Updated: 2026-09-16. This is a live status note, separate from the implementation walkthrough.

## Recorded verification

2026-09-16: retained the tree-only lookup diagnostic in the download-manager suite and strengthened the bound-reader regression to select the opposite download explicitly. Neither test assumes table iteration follows insertion order. The unbound test demonstrates cancellation coupling; the bound test demonstrates isolation. All 60 download-manager tests passed.

2026-09-16: retaining download-ID-bound streaming readers passed all 59 download-manager tests, including two new Direct/Direct cancellation-isolation tests and the existing Direct/Mix handle-isolation test. Reader binding is an accepted shared correctness change relative to master's tree-only lookup. No production code changed in this increment. Concurrent storage behavior was inspected in source, not fault-injection tested; no benchmark equivalence is claimed.

2026-09-16: restoring master-style Direct address forwarding passed 12 network tests, three Direct/Mix integration tests, and Storage's compile-only check. The integration provider list places a valid Mix advertisement before its ordinary endpoint. The unused Direct filtering helper and both empty-list rejections were removed; Mix validation is unchanged. This does not validate mapper ordering or final advertisement preservation; those remain separate follow-ups. Benchmarks and the full suite were not run.

2026-09-16: removing explicit Direct provider registration passed 12 network tests and three Direct/Mix download-selection integration tests. The two new network tests use real Switch connections to verify a single registration notification and preservation of relay exclusion. Direct address filtering and Mix session registration were not changed. The full suite and benchmarks were not run.

2026-09-16: the independent presence-query policies passed 131 engine tests and three Direct/Mix download-selection integration tests. Six focused tests cover full swarms, swarm bans, successful admission, and existing incomplete/complete peers. Storage's compile-only check also passed. Both transports default to master's query-after-failed-admission behavior; `QueryAdmittedPeers` is an explicit opt-in. These results do not establish benchmark equivalence or validate every remaining Direct-path difference.

2026-09-16: the injected presence-peer selection policies passed 125 engine tests (including six focused policy tests) and three download-selection tests with real Mix traffic. The focused tests compare the default initial selection and random-number consumption with master's shuffle-and-truncate procedure. Both transports default to that policy; provider priority and provider-only eligibility are explicit constructor opt-ins. Default construction installs no provider-tracking callback. These checks do not establish benchmark equivalence or resolve the remaining Direct-path differences, including swarm-admission gating.

2026-09-15: the independent Direct/Mix protocol-instance refactoring passed 9 network tests, 117 engine tests, 7 discovery tests, and 3 download-selection tests with real Mix traffic (136 tests total). Storage's compile-only check passed. The new network test confirms that the mounted dispatcher closes an incoming Mix stream when Mix is disabled without creating a Direct peer. The full Storage suite was not run.

The shared `BlockExcNetworks` holder now replaces recursive `mixNetwork` ownership. Mix is created with its service during enabled startup; one mounted dispatcher preserves the shared incoming quota. The same engine callback configuration is used for both protocol instances. This increment does not change the wire protocol or the legacy DHT-over-Mix path.

2026-09-15: replacing `useMixSessionEvents` with the protocol instance's `DownloadTransport` field passed all eight network tests and all three download-selection tests, including real Mix traffic. No full-suite or Storage compile-only rerun was performed for this refactoring.

These are results recorded during the integration work, not a claim that every check has been rerun against today's branch.

- The original download-selection increment passed 57 download-manager tests and 117 BlockExchange engine tests. Those covered transport-specific background reuse and a streaming read attached to its own download ID, as well as existing engine behavior.
- After Storage adopted MixTransport recipient-side dialing at commit `edd2423`, eight network tests and three download-selection tests passed. Storage's compile-only check also passed.
- The download-selection test uses five real Mix nodes and an in-memory provider-discovery stub. It fetches manifests over both transports, transfers blocks over each, checks stream types, and rejects a direct-only provider record for a Mix request.
- The same integration test checks recipient-originated presence delivery, sending-stream reuse, and replacement after stream closure while retaining the session.
- The preceding MixTransport increment passed 85 transport tests, including seven focused opening-history tests for both session roles.

Diagnostic logging for the download-selection test can be enabled with `MIX_DOWNLOAD_TEST_LOGS=1`. The recorded Storage integration runs did not exercise live DHT discovery or HTTP endpoints.

## Verification still needed

- Actual HTTP requests to the REST endpoints: query parsing, error responses, and delivering the downloaded bytes to the HTTP caller.
- Real provider-record propagation and discovery, including usable Mix advertisements.
- Sustained concurrent downloads and delayed/lost traffic through the extended BlockExchange harness.
- A successful legacy DHT-over-Mix lookup while a MixTransport transfer is active.

A colleague is extending the harness for BlockExchange. Confirm whether the harness drives REST or calls the underlying APIs directly; those test different boundaries.

## Legacy DHT-over-Mix crash report

The user reports that some DHT-over-Mix tests segfault, but the failing tests and environment are not yet identified. Master has also received DHT changes. No cause is established.

Collect the exact revision, failing test, Nim version, build/run command, and backtrace or core dump. Compare master and the integration branch under the same conditions before attributing the failure to MixTransport.

Code inspection found separate codecs and credential ownership: MixTransport returns `Unhandled` for unknown reply identifiers so the embedded Mix connection path can process legacy replies. This observation is not runtime proof of coexistence.

## Open implementation questions

- Recipient peer removal currently clears the BlockExchange peer without resetting its underlying Mix session when the protocol instance has not retained that session object. Recipient dialing is available, but peer-drop/reset policy remains separate work.
- A full Direct swarm can still need better replacement of low-value candidates with newly discovered providers.
- AutoNAT address-mapper ordering and stale or unreachable advertisements remain independent concerns.
- Previously observed high-concurrency harness stalls need investigation; transport selection alone does not explain or resolve them.

## CacheStore duplicate-insert accounting — follow-up

While reviewing simultaneous Direct/Direct and Direct/Mix downloads on 2026-09-16, source inspection identified an existing accounting bug in `storage/stores/cachestore.nim`, in `putBlockSync`: replacing an existing CID still increments `currentSize` by the block size. With sufficient free capacity, inserting the same block twice retains one entry but counts its bytes twice. The capacity check also treats replacement as a new insertion, potentially evicting other entries unnecessarily. Sequential duplicate inserts are enough; concurrent scheduling is not required.

This code is unchanged from the reviewed master baseline. Normal node startup uses `RepoStore` for BlockExchange and Manifest storage, not `CacheStore`. CacheStore is used by tests, including the Direct/Mix integration fixture, and may be used by external consumers. This is not a normal-node RepoStore bug or a Mix integration blocker.

Follow-up: add a duplicate-insert size/eviction regression test and correct replacement accounting in a separate increment. No fix or dedicated reproduction test has been added yet. This issue is separate from shared-block cleanup after proof-storage failure.

## Document ownership

The Download Transport Selection walkthrough explains the current code and design decisions. Keep test outcomes, unverified hypotheses, and proposed follow-ups here. The integration plan records increment ordering and links to this note.
