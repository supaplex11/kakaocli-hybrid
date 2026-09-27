# Third-party notices

The upstream kakaocli MIT license remains in LICENSE.

## OpenKakao

Selected notification parsing and durable-receive behavior is adapted from
[OpenKakao](https://github.com/JungHoonGhae/openkakao-cli), pinned reference commit
`336cc9147303ed6e9b1a7c2cb39545327bffd5af` (MIT).

Reference files at that commit:
- `src/commands/notif_watch.rs` — notification database/plist observation behavior.
- `src/receive_inbox.rs` — durable inbox, deduplication and delivery lifecycle behavior
  (not `src/commands/receive_inbox.rs`).

Local Swift adaptations and supporting integration:
- `Sources/KakaoCore/Receive/NotificationParser.swift`
- `Sources/KakaoCore/Receive/NotificationReader.swift`
- `Sources/KakaoCore/Receive/ReceiveEvent.swift`
- `Sources/KakaoCore/Receive/ReceiveSQLite.swift`
- `Sources/KakaoCore/Receive/ReceiveStore.swift`
- `Sources/KakaoCore/Receive/ReceiveStdout.swift`
- `Sources/KakaoCore/Receive/ReceiveStop.swift`
- `Sources/KakaoCLI/Commands/ReceiveCommand.swift`

These are Swift adaptations, not a byte-for-byte Rust port. Local changes include
strict identifier validation, account-namespaced identities, revisioned snapshot
reconciliation, bounded read-only snapshots, private store checks, tokenized stdout
leases, graceful shutdown, and configurable terminal-payload retention with durable
fingerprints. The upstream notice and MIT terms below remain applicable.

MIT License

Copyright (c) 2026 Lucas (JungHoonGhae)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
