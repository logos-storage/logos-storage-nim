# Mix Transport integration: validation and open questions

Updated: 2026-09-15. This is a live status note, separate from the implementation walkthrough.

## Recorded verification

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

## Document ownership

The Download Transport Selection walkthrough explains the current code and design decisions. Keep test outcomes, unverified hypotheses, and proposed follow-ups here. The integration plan records increment ordering and links to this note.
