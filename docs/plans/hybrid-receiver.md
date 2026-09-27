# KakaoCLI Hybrid Receiver Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Preserve kakaocli's local history/search while adding notification receive, durable delivery and evidence-based DB enrichment, without Kakao server authentication or autonomous sends.

**Architecture:** Swift adapters read KakaoTalk SQLCipher and Notification Center independently. A durable SQLite event store merges observations by account namespace + chat ID + log ID; sinks consume versioned events. DB is the richer evidence source; notification-only operation remains available when DB access breaks.

**Tech Stack:** Swift 6, Foundation PropertyListSerialization, existing CSQLCipher, XCTest, NDJSON; optional explicitly enabled webhook delivery.

## Scope and status

This commit is design only; no new command below exists yet. Preserve upstream commands and behavior until tested migration. Base: silver-flight-group/kakaocli commit 8b6ffcfdaebc592a735dc1a8bd5e50037e626406. Reference: JungHoonGhae/openkakao-cli notification parser and receive_inbox implementation, MIT. Pin reference commit before porting.

Verified previously on an authorized local machine: explicit cached user ID permits DB decryption and explicit DB/key permits messages reads; automatic ID detection fails. Notification replay emitted an existing message. Continuous new-arrival, restart recovery and hybrid operation are NOT yet verified. Do not publish production messages, credentials, paths to personal DBs or identifying fixtures.

## Corrections to preliminary concept

- kakaocli already has DB polling and webhook output. Notification reception is complementary, not the only real-time route.
- Notification polling is not instant; latency depends on polling and OS delivery. Muted/focused rooms may produce no notification. DB coverage depends on the official app actually synchronizing messages locally.
- Notification title may be a sender name rather than room name. Store notification_title with provenance; NEVER overwrite canonical chat names from title alone. Notification attachment may be an avatar/preview, not the original message media.
- History means locally retained history, not every server message.
- Existing DatabaseWatcher advances in-memory max log ID before callback delivery and lacks durable acknowledgement. Hybrid must persist before advancing checkpoints and must reconcile delayed/lower-ID arrivals.

## Proposed CLI (not implemented)

Keep `messages`, `search`, `chats`, and legacy `sync` compatible. Introduce `receive --source db|notif|hybrid --once|--follow --json [--replay-existing]`.

`receive` is durable by default. First run establishes a baseline unless replay is requested. Restart resumes pending deliveries. `--once` performs one bounded ingest/reconcile/drain pass. `doctor --json` reports per-source readiness without network/login/UI mutations. No arbitrary hook execution in MVP. Webhook delivery is phase 2 and explicit opt-in.

## Data contract

Use JSON strings for 64-bit chat/log IDs (avoid JavaScript precision loss), account namespace and schema_version=1. Event envelope: event_id, revision, event_type(message.observed/message.updated/message.deleted), chat_id, log_id, sources, observed_at, message_at, text, sender_id, is_from_me (nullable), notification_title, verified_chat_name, completeness, field_provenance.

Stable message key = account_namespace/chat_id/log_id. Sources add observations rather than duplicate message events. Late DB enrichment emits a new revision with the same event_id; downstream idempotency key = event_id + revision. Never coerce unknown sender/self direction to a known value. Distinguish notification time from message time. Raw observations are locally retained only under explicit retention policy; redact logs by default.

## Storage and failure model

Owned database under application support, directory 0700, files 0600; exclude from Git. Tables: observations, messages, checkpoints, deliveries, leases, schema_migrations. In one transaction ingest observations, upsert canonical message/revision, enqueue delivery and persist checkpoint. Per-sink delivery state: pending -> leased -> delivered or retry -> dead_letter. Lease expiry supports process crashes; bounded exponential backoff; configurable retention. Re-delivery after remote success but before local acknowledgement is possible: at-least-once, never exactly-once.

Stdout cannot acknowledge downstream processing: mark emitted only after successful write/flush and document crash duplication. Webhook acknowledgement requires validated success response. Separate source readiness from sink health; corrupt/locked DB must not advance cursor. Do not delete unacknowledged records during retention pruning.

## Architecture/file map

- Modify Sources/KakaoCore/Database/DeviceInfo.swift: bounded lookup; validated configured user ID.
- Add Sources/KakaoCore/Database/DatabaseAccessResolver.swift: shared read-only credential resolution and account validation.
- Modify Sources/KakaoCLI/Commands/SyncCommand.swift and read commands to share resolver only after regression tests.
- Add Sources/KakaoCore/Receive/ReceiveEvent.swift, NotificationParser.swift, NotificationReader.swift, DatabaseSource.swift, ReceiveStore.swift, HybridReceiver.swift, DeliveryWorker.swift.
- Add Sources/KakaoCLI/Commands/ReceiveCommand.swift and DoctorCommand.swift; register in Sources/KakaoCLI/KakaoCLI.swift.
- Existing Sources/KakaoCore/Sync/DatabaseWatcher.swift and WebhookPublisher.swift remain legacy until explicit migration.
- Add Tests/KakaoCoreTests/Receive*Tests.swift plus synthetic Fixtures/Notifications and synthetic SQLite fixtures.

## Sequenced implementation tasks

For EACH task: write the failing XCTest, run `swift test --filter <Suite>`, implement the smallest change, rerun that suite then `swift test`, and commit only named files. Test names below are proposed, not existing tests or claimed results.

### P0.1 Baseline and privacy boundary

Files: README.md, AGENTS.md, .gitignore, THIRD_PARTY_NOTICES.md, docs/architecture/hybrid.md.
Run `swift build` and `swift test` before changes; record actual failures. Replace inherited agent examples that solicit plaintext passwords or auto-send with human-approved flows. Ignore .env, credentials, runtime DB/WAL/SHM, logs, exports. CI fixtures must be synthetic. Keep upstream MIT and include OpenKakao attribution for ports. Commit: `docs: establish hybrid receiver boundaries`.

### P0.2 Bounded access resolution

Files: DatabaseAccessResolver.swift, DeviceInfo.swift; Tests/KakaoCoreTests/DatabaseAccessResolverTests.swift.
Tests: configured valid ID succeeds; wrong account fails closed; missing ID returns within deadline; unreadable DB and bad key classify separately; output never contains keys. Prefer Keychain references or protected configuration over command-line secret values; do not import a user's legacy auth cache automatically. Existing explicit --db/--key remains compatible but deprecated for secret exposure. No brute-force without bounded deadline. Commit: `fix: bound and validate database access resolution`.

### P1.1 Event types and stable identity

Files: ReceiveEvent.swift; ReceiveEventTests.swift.
Tests: IDs beyond 2^53 round-trip as strings; null sender/direction survives; two accounts cannot collide; same message from two sources shares identity. Provide fixture ID strings `9007199254740993` and `9007199254740995`. Commit: `feat: define versioned receive event contract`.

### P1.2 Pure notification parser

Files: NotificationParser.swift; ReceiveNotificationParserTests.swift.
Port behavior from OpenKakao notif_watch.rs using PropertyListSerialization. Parse req.iden as decimal room_log pair, req.titl/body/atta and CFAbsoluteTime date. Test malformed plist/identifier, integer/real/date timestamp, hidden preview, missing attachment, duplicate notifications. Titles stay unverified and attachment paths are metadata only. Commit: `feat: parse notification observations`.

### P1.3 Read-only notification source

Files: NotificationReader.swift; ReceiveNotificationReaderTests.swift.
Discover supported Notification Center DB paths and schema at runtime; filter Kakao bundle only; parameterized SQL; read-only open; bounded busy timeout. Tests: FDA denied -> actionable error; missing DB; incompatible schema; ordering; retained replay vs baseline; no write to source DB. No privileges escalation. Commit: `feat: read retained Kakao notifications`.

### P1.4 Durable store ingestion

Files: ReceiveStore.swift; ReceiveStoreTests.swift.
Tests: duplicate source observation yields one pending event; crash/rollback leaves cursor unchanged; migration failure keeps old DB intact; account separation; reopen retains pending events. Atomic insert/checkpoint transaction. Synthetic fixture only. Commit: `feat: persist receive observations atomically`.

### P1.5 Delivery and lease recovery

Files: DeliveryWorker.swift; ReceiveDeliveryTests.swift.
Inject clock and sink; no real sleeps in tests. Tests: lease expires after crash; concurrent workers claim once; failed sink retries; success+crash allows duplicate same revision; exhausted retries quarantined; pending events survive cleanup; broken stdout pipe does not acknowledge. Commit: `feat: add recoverable receive delivery`.

### P1.6 Notification-only CLI MVP

Files: ReceiveCommand.swift, KakaoCLI.swift; ReceiveCommandTests.swift.
Wire `receive --source notif --once --json --replay-existing`; follow mode with SIGINT/SIGTERM cleanup; diagnostics stderr only. Test parser/help, unsupported flags, bounded once, baseline/replay, restart pending delivery. Do not install launchd yet. Acceptance: synthetic replay produces expected message identity; authorized real retained notification works without printing private text to shared logs. Commit: `feat: expose notification receive CLI`.

### P2.1 Durable DB source

Files: DatabaseSource.swift, DatabaseReader.swift; ReceiveDatabaseSourceTests.swift.
Retain primary cursor plus bounded overlap scan and dedup; add explicit reconciliation for late older history. Document overlap limits instead of promising universal capture. Test out-of-order inserts, same timestamp, restart, locked DB, deleted/hidden system events and own messages. Persist before checkpoint. Commit: `feat: add durable database receive source`.

### P2.2 Hybrid reconciliation

Files: HybridReceiver.swift; ReceiveHybridTests.swift.
Tests: notification-first/DB-first both produce one observed identity; delayed DB enrichment yields one updated revision; matching text alone never joins rooms; differing fields preserve provenance; unavailable source reports degraded readiness; notification title never changes verified name. Add bounded enrichment retries and DB reconciliation. Commit: `feat: reconcile database and notification observations`.

### P2.3 Optional webhook sink

Files: ReceiveWebhookSink.swift; ReceiveWebhookTests.swift.
Explicit destination opt-in, HTTPS by default; localhost HTTP separately allowed. Reject redirects to unapproved destinations. Timeout, bounded responses and retry policy; configurable headers resolved from secret refs; optional timestamped HMAC. No implicit forwarding to Hermes/n8n. Tests use local mock server only and prove idempotency key/retry behavior. Commit: `feat: add opt-in acknowledged webhook delivery`.

### P3 Operations and deployment

Files: DoctorCommand.swift, docs/operations.md, examples/launchd/*, .github/workflows/swift.yml.
Test schema/permission diagnostics, redaction, retention and account switch. Document no automatic source-app launch/login, stale local data, permissions for actual binary/process, signed binary upgrades, rollback and uninstall. launchd installation remains user-approved; do not start on CI. macOS CI: brew install sqlcipher; swift build; swift test. Linux unsupported. Safe-send is explicitly a separate future project, not included.

## Release gates

1. Existing build/tests pass or inherited failures documented and resolved before release.
2. Synthetic parser/store/merge/crash tests all pass.
3. Read-only manual smoke against authorized data: DB read, retained notification replay, independent source outage.
4. New incoming message and restart recovery explicitly exercised before claiming live monitoring validated; absence of a volunteer message is a blocker for this gate, not fabricated evidence.
5. No source DB writes, sends, login requests, real personal fixtures or secrets in Git.
6. CLI examples and tests agree; version distinguish fork from upstream; rollback binary retained.

## Non-goals

No LOCO implementation, no server-login retries, no guaranteed full server history, no paywall bypass, no unattended send, no AX safety-limit removal, no automatic room rename from notification title, no UI dashboard or large workflow engine.

## Recommended handoff

Build only P0 + P1 first. Review real replay and crash recovery before adding DB hybrid logic. Existing installed CLIs remain unchanged throughout prototype work. All upstream sync occurs via separate reviewed branches; never force-push upstream-derived history.
