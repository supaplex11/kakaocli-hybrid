# Notification receiver MVP — bounded implementation results

## Delivered

`receive --source notif --once|--follow --json --account NAME [--notification-db PATH] [--inbox PATH] [--replay-existing] [--retention-seconds SECONDS]` provides notification-only, durable at-least-once NDJSON output.

- P0 database-access resolver implementation is complete: bounded/cooperative resolution, explicit protected access configuration, read-only SQLCipher validation, required schema and account binding, payload-free diagnostics, and no auth-cache import/login. `auth`, `chats`, `messages`, `search`, `query`, `schema`, `sync`, and `harvest` now share the access options/resolver; existing read command implementations **were modified**. Legacy UI/send operations remain separate and are not invoked by receive.
- Pure binary/XML plist parsing; strict canonical positive signed-64-bit IDs preserved as JSON strings; CFAbsoluteTime/Date handling and nullable previews.
- Notification SQLite source opens READONLY; schema probing, Kakao bundle filtering, ordered bounded snapshots (10,000 rows, 32 MiB total, 1 MiB/payload, two-second query deadline). Malformed-payload diagnostics contain no content.
- Account-namespaced identities, transactional snapshot/checkpoint ingest, persistent deduplication and revisions, initial baseline or opt-in replay. Multiple retained records of an identity collapse to the latest record in the snapshot.
- Private durable SQLite inbox, expiring tokenized leases, bounded retry backoff and dead-letter quarantine; successful bounded nonblocking stdout write precedes acknowledgement. Recovery drains independently of missing/locked source health. One invocation/iteration attempts at most 100 eligible deliveries across both drains.
- Graceful SIGINT/SIGTERM wake idle waits and interrupt backpressured writes; active claims are released without consuming retry budget. Abrupt crashes still recover through lease expiry (default 30 seconds).
- Configurable terminal-payload retention, account-isolated pruning, schema-v1-to-v2 migration and retained dedup fingerprints. No attachment reads, outbound sends or login.

## Privacy retention policy

- `--retention-seconds` defaults to **604800 seconds (seven days)** after successful stdout acknowledgement or transition to dead-letter. This conservative window allows short-term diagnosis of delivery failures without indefinite terminal-payload accumulation. Both terminal states use the same window; `0` requests immediate pruning. Values must be finite and nonnegative.
- Maintenance runs at the start and end of each receive iteration for **only the selected account**, including when source acquisition fails. Expiry is inclusive (`terminal_at <= now - retention`). Retention is invocation-configured, not persisted; use the same option for workers sharing an account. No background cleanup occurs while receive is stopped; long poll intervals delay cleanup until the next iteration.
- Only `delivered` and `dead_letter` delivery rows are deleted. Pending, delayed-retry, actively leased and expired-but-unacknowledged deliveries never expire through retention. Dead-letter payloads cannot be recovered after pruning; no redrive command exists.
- Schema v2 records terminal transition timestamps. Schema v1 is validated and migrated transactionally. Legacy terminal rows with unknown completion times begin a full retention window at their account's first maintenance run rather than using a guessed lease timestamp. Zero retention explicitly removes those terminal rows immediately.
- Compact SHA-256 event identities and latest observation fingerprints, revision/baseline flags, and account/source checkpoints remain indefinitely. They prevent retained source records (including `--replay-existing` and source-path replacement) from flooding the outbox after payload pruning. A changed observation can still emit the next revision. This metadata grows with unique identities; hashes are not encryption or guaranteed anonymization and can permit guessing/linkability.
- Pruning is **logical deletion, not physical secure erasure**. SQLite freelist pages/journals/WAL, filesystem snapshots/backups and SSD storage may retain bytes; database file size need not shrink. No VACUUM, secure-delete guarantee, source-store deletion, or backup deletion is performed. Plaintext pending payloads, compact metadata and downstream stdout copies remain outside this terminal-payload policy. Protect the disk/backups separately. Never delete the dedup store merely to reclaim space unless intentional fresh replay is acceptable.

## Semantics and residual limits

- `--account` is operator-assigned and required; change it on account switch. No automatic identity/account-switch detection.
- Baseline is per account/source path. Replay affects only first initialization and does not resurrect previously baselined/delivered/pruned observations. A separate inbox creates an intentional fresh replay.
- A crash after output but before acknowledgement can duplicate an event. Consumers deduplicate `(event_id, revision)`. Output failure or interrupted writes can leave a partial NDJSON record. Stdout success is not downstream consumer acknowledgement. Sink failure exits nonzero; restart resumes retries. `--once` does not wait for future retries.
- Notification visibility is incomplete: muted/focused chats, disabled notifications, hidden previews, purged records and history are not recovered. Notification title is **not** a verified room name; attachment paths are metadata, not original media; sender, message timestamp and self-message status remain unknown. Source errors do not advance initialization checkpoints.
- Inbox is plaintext, protected by owned 0700 parent and 0600 regular files, with symlink ancestors/files and hardlinked inbox files rejected. Same-user processes are not excluded. Source schema depends on macOS version.
- DB resolver deadlines are cooperative, not hard preemption of kernel I/O or one native KDF. Wrong keys and corruption cannot always be distinguished. SQLCipher/macOS 14 deployment compatibility is not verified against the installed macOS-26-built dylib (linker warning).
- DB enrichment, hybrid reconciliation, webhook delivery, independent specification/quality review, real-user-data and Full Disk Access integration tests remain outside this completed notification MVP. The broader hybrid plan is not claimed complete. Root `AGENTS.md` was protected and was not changed.

## Verification

Only generated fixtures were used; no real Notification Center/Kakao/auth-cache data was read, and no login, send, install, production cleanup or push was performed.

- `swift build` — passed.
- `swift test` — **30 XCTest tests and 4 Swift Testing tests passed**, no failures. Includes 13 database-resolver, 4 parser, 1 notification-reader and 12 receive-store XCTest tests; plus 4 key-derivation tests.
- `python3 Tests/receive_cli_smoke.py .build/out/Products/Debug/kakaocli` — passed: baseline/replay/string IDs, dedup/follow, unchanged source bytes, broken-pipe retry, missing/locked-source recovery, 100-event bound, idle/active SIGINT/SIGTERM unwind, retention default/zero/invalid values and replay after prune; mixed valid/malformed native-Date snapshot ingestion, persisted delivery/dedup and subsequent valid ingestion while malformed records remain.
- Timestamp regression reproduced before the fix: native binary-plist NaN/±infinity failed JSONEncoder fingerprint encoding, and the mixed-snapshot CLI exited with a source-health error. All Date/numeric/string timestamp inputs now share finite/range validation (`abs(seconds) < 100_000_000_000`); invalid values become unknown without dropping observations. Binary-plist regression cases cover NaN, ±infinity, both exact range boundaries and finite values beyond them. Full build/test/smoke passed after the fix; the existing SQLCipher deployment-target linker warning remains.
- New synthetic-clock store tests cover exact retention boundary, delivered/dead-letter deletion, active and expired lease survival, pending survival, account isolation, reopen/source replacement replay, revision continuity, legacy migration grace period, zero retention and invalid clocks/options.

OpenKakao MIT provenance is recorded in `THIRD_PARTY_NOTICES.md`, pinned to `336cc9147303ed6e9b1a7c2cb39545327bffd5af`, with reference and local adaptation file names. The original upstream MIT license remains intact.
