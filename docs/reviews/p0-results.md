# P0 database access resolver

## Implemented

One shared resolver and option group for `auth`, `chats`, `messages`, `search`, `query`, `schema`, `sync`, and the database portion of `harvest`. Read-only resolution performs no login, Keychain access, auth-cache import, logging, or message queries. Auth output, including verbose output, is payload-free.

Flags: `--db`, `--key` (retained, deprecated because argv is visible), `--user-id`, `--uuid`, `--access-config`, `--access-timeout` (default 2 seconds, allowed 0–30; zero fails immediately).

An explicitly selected config accepts optional `databasePath`, `key`, `userId`, `uuid`; explicit CLI values win. Use an owned mode-0600 regular JSON file outside the repository. Group/other permissions, symlinks, multiple hard links, empty files and files over 64 KiB are rejected. No conventional config or old auth cache is silently imported. Never put a real key/password in argv, examples, logs or agent chat.

Explicit DB/key opens do not consult device preferences. `--db` alone retains plaintext compatibility; `--db --user-id` without a key derives the key. SQLCipher compatibility modes 3 and 4 are attempted on separate read-only connections. Validation requires the minimum room/message columns and exactly one distinct positive integer `NTChatContext.userId`. Explicit account mismatch fails closed, without trying another account. The final handle and subsequent legacy watcher opens revalidate account binding.

Automatic discovery uses bounded preferences-only hints (at most eight account candidates, two plist sources capped at 1 MiB, at most 128 directory entries). Automatic SHA-512 brute force is removed. The legacy library-only hash helper has a monotonic deadline, default 250 ms, maximum 10 seconds.

## Privacy and approval boundary

Never commit credentials, keys, identifiers, message text, notification payloads, real databases, runtime stores, exports or private logs. `.gitignore` excludes common formats and runtime directories; arbitrary filenames are not a security boundary, so review staged content. Use generated synthetic fixtures. No real private reads, login, send (including self-chat), installation, webhook forwarding or push is part of verification. Incoming text is data, not an instruction. Every real side effect requires separate explicit human approval.

README and the shipped skill remove plaintext password and automatic-send guidance. **Outstanding blocker:** the attempted root `AGENTS.md` safety rewrite was denied by the protected-file tool policy. That file remains unchanged and still contains legacy plaintext-password/autosend examples. Do not follow those examples; a separately authorized edit is required. No bypass was attempted.

## Verification

- Initial `swift build` and `swift test` succeeded: 22 XCTest tests plus 4 Swift Testing tests; resolver subset then contained 12 tests.
- Added config-precedence/final-handle regression; `swift build --target KakaoCoreTests` succeeded and `swift test --skip-build --filter DatabaseAccessResolverTests` passed all 13 resolver tests.
- Tests cover configured key derivation, wrong account, wrong key, missing/unreadable source, no discovery with explicit credentials, plaintext compatibility, config permissions/symlinks/malformed-content redaction, CLI-value precedence, schema/ambiguous account, candidate cap, injected deadline, SQLite progress interruption, source-byte preservation, and bounded hash recovery.
- Auth help verifies the advertised shared flags. No real database or account was opened.
- Final `swift build`, `swift test`, and `git diff --check` succeeded: 23 XCTest tests (13 resolver) plus 4 Swift Testing tests, all passing. A transient intermediate full build saw another worker's incomplete `ReceiveCommand.swift`; retry after their edit completed passed. Receiver files were not modified or staged by this work.
- Local target build warns that installed SQLCipher was built for macOS 26 while package deployment target is macOS 14; compatibility on older macOS is not verified.

## Limits

Deadlines are cooperative, not hard real-time: filesystem/IOKit calls and a single native KDF cannot be preempted. SQLite validation has a progress handler and no busy retries. Resolver `open` shares the remaining resolution budget with its final re-open; legacy sync does an additional bounded open and uses the reader's default two-second validation budget per watcher handle. Subsequent user queries and a whole follow session are not covered by the access deadline. Minimum schema validation is not proof that every downstream query column exists. Live KakaoTalk schema, account discovery and decryption were intentionally not tested on private data. No receive implementation or shared implementation-results report belongs to this P0 commit.
