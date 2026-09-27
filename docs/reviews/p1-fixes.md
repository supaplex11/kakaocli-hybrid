# P1 notification receiver fixes

## Implemented

- Drain durable deliveries before notification-source discovery/open/snapshot. Missing or locked sources report a redacted `Source health:` diagnostic on stderr; `--once` exits 1 after recovery, while follow retries source health on later polls.
- Validate version-1 store column names, types, nullability and primary-key positions. Decode persisted revisions and payload identity with checked guards rather than force unwraps; reject malformed and overflow revisions with redacted errors.
- Bound each once invocation (and each follow iteration) to 100 claims total across pre/post-snapshot drains. Excess deliveries remain durable for the next invocation.
- Handle SIGINT/SIGTERM through Dispatch signal sources and a condition-protected stop flag. Wake long idle waits, stop further claims, cancel backpressured writes, release incomplete claims without consuming retry budget, and return normally. Successfully written complete records are acknowledged before unwind.
- Baseline suppresses only the initial observation: unchanged replay stays suppressed, but a genuine change to that identity emits revision 2 and clears baseline state.

## Verified locally, synthetic fixtures only

Commands: `swift build`; `swift test`; `python3 Tests/receive_cli_smoke.py .build/debug/kakaocli`; `git diff --check`.

- Build passed.
- XCTest: 26 tests, zero failures; Swift Testing: 4 tests passed.
- Added regression unit coverage for changed baselines after reopen, nonnumeric and overflow revisions, incompatible version-1 schema, and repeated shutdown release without retry exhaustion.
- Smoke passed: baseline/replay, large string IDs, restart dedup, follow, unchanged source bytes, broken-pipe retry, pending recovery with missing/exclusively locked sources, 105-event backlog split 100/5, and both SIGINT/SIGTERM during idle and active backpressured output. Signal cases assert normal exit within 3 seconds and no remaining leased deliveries.

## Limits / unchanged guarantees

- Fixed batch size is not an end-to-end wall-clock deadline. Source snapshot bounds and per-write timeout still apply.
- At-least-once stdout remains intentional: interruption may leave a partial line; crash after a complete write but before acknowledgement can duplicate a record. No downstream acknowledgement is claimed.
- Existing SQLCipher linker warning remains: installed dylib targets macOS 26 while package deployment target is macOS 14. Tests pass on this host; older macOS compatibility is not verified.
- No real notifications/chat data, auth, login, network send, installed binary changes, or push. IDs remain strings and notification titles remain unverified.
- Shared P0 DB/CLI/docs files and implementation-results.md were not edited or staged by this worker.
