# Notification receiver MVP — bounded implementation results

## Delivered

`receive --source notif --once|--follow --json --account NAME [--notification-db PATH] [--inbox PATH] [--replay-existing]` is an additive command. Existing command implementations are unchanged.

- Pure binary/XML plist parsing, strict canonical positive signed-64-bit identifier validation while preserving IDs as JSON strings, CFAbsoluteTime/Date handling, nullable preview fields.
- Notification SQLite source opens READONLY; schema probing, Kakao bundle filter, ordered bounded snapshots (10,000 rows, 32 MiB total, 1 MiB/payload, two-second query deadline). Malformed payload counts contain no content.
- Account-namespaced event identities; notification title is **not** a verified room name; attachment path is **not** original media. Sender, message timestamp, and self-message status remain unknown.
- Private durable SQLite inbox, transactional snapshot ingest and initialization checkpoint, persisted identity deduplication, revisions, first-run baseline or opt-in replay, tokenized expiring delivery leases, retry delay, dead-letter state after repeated failures. Multiple retained records for the same identity collapse to the latest snapshot record.
- Bounded nonblocking NDJSON stdout writes, acknowledgement only after successful write, broken-pipe failure retained for retry. No login, outbound sends, or attachment reads.

## Semantics and limits

- `--account` is required and explicitly operator-assigned; account identity is not inferred from notification data. Change namespace on account switch. No automatic account-switch detection.
- Baseline is per account/source path; first successful snapshot is suppressed unless replay is requested. Replay only affects first initialization; it does not resurrect previously baselined/delivered observations. Use a separate inbox for an intentional fresh replay.
- At-least-once output: a crash after write but before acknowledgement can duplicate an event. Consumers deduplicate `(event_id, revision)`. Partial stdout records can occur if output fails mid-write. stdout success is not downstream consumer acknowledgement.
- `--once` drains eligible deliveries, not future retries. Follow polls; SIGINT/SIGTERM terminate and unacknowledged leases become eligible after expiry (default 30 seconds). Sink failure exits nonzero; restart resumes retries. No dead-letter redrive command or retention/compaction policy yet.
- Notification-only visibility is incomplete: muted/focused chats, disabled notifications, hidden previews, purged records, and history are not recoverable here. Source-file inode replacement requires restart. Snapshot errors fail closed without changing the initialization checkpoint.
- Inbox data is plaintext, guarded by owned 0700 parent and 0600 regular files; symlink ancestors/files and hardlinked inbox files are rejected. This is not protection against another process running as the same user. The source schema is macOS-version dependent.

## Verification

All checks used generated fixtures, never real Notification Center/Kakao/auth-cache contents. `swift build`, `swift test`, and `python3 Tests/receive_cli_smoke.py .build/out/Products/Debug/kakaocli` pass. Tests cover parser variants, filtering/source bytes unchanged, baseline/replay, namespace separation, restart dedup, revisions, repeated source identities, rollback/migration refusal, concurrent store leases/stale acknowledgements, retries/dead-letter, private-store checks, stdout and broken-pipe recovery, and CLI follow.

The local SQLCipher library produces a linker warning: package deployment target macOS 14, installed dylib built for macOS 26. Compatibility on macOS 14 is not verified. No installed binary was replaced; no push.

## Remaining P0/P1 scope — NOT complete

The broader plan is **not** complete. P0 encrypted Kakao DB resolver work remains with the parent: safe credential/key resolution, explicit account/DB binding, schema compatibility and read-only DB-source validation. This receiver deliberately never invokes the legacy `resolveDatabasePath`/authentication discovery path. DB enrichment, hybrid reconciliation, complete-message provenance, and independent specification/quality reviews are pending. No real-user-data or Full Disk Access integration test was performed.

OpenKakao MIT attribution remains in `THIRD_PARTY_NOTICES.md`. Local references inspected: `src/commands/notif_watch.rs` and `src/receive_inbox.rs` (the supplied `src/commands/receive_inbox.rs` path does not exist). Existing interrupted parser/reader/event/SQLite helper and tests were preserved and completed rather than discarded.
