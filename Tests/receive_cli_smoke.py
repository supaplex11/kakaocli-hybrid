"""Synthetic-only CLI integration: python3 Tests/receive_cli_smoke.py /path/to/kakaocli."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import sqlite3
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
scratch = Path.home() / '.hermes/cache/scratch'
scratch.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='receive-cli-', dir=scratch) as tmp:
    root = Path(tmp)
    source = root / 'source.sqlite'
    con = sqlite3.connect(source)
    con.executescript('CREATE TABLE app(app_id INTEGER, identifier TEXT); CREATE TABLE record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB); INSERT INTO app VALUES(1,"com.kakao.KakaoTalkMac");')
    def insert(log):
        blob = plistlib.dumps({'req': {'iden': f'9007199254740993_{log}', 'titl': 'unverified synthetic', 'body': 'synthetic only'}}, fmt=plistlib.FMT_BINARY)
        con.execute('INSERT INTO record(app_id,data) VALUES(1,?)', (blob,))
        con.commit()
    insert('9007199254740995')
    inbox = root / 'private/inbox.sqlite'
    base = [binary, 'receive', '--source', 'notif', '--json', '--account', 'fixture', '--notification-db', str(source), '--inbox', str(inbox)]
    def run(extra=()):
        p = subprocess.run(base + ['--once'] + list(extra), capture_output=True, text=True, timeout=10)
        assert p.returncode == 0, p.stderr
        return [json.loads(line) for line in p.stdout.splitlines()]
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    assert run() == []  # default initial baseline
    assert run(['--replay-existing']) == []  # baseline cannot be resurrected
    insert('9007199254740996')
    events = run()
    assert len(events) == 1 and events[0]['log_id'] == '9007199254740996'
    assert events[0]['chat_id'] == '9007199254740993'
    assert events[0]['verified_chat_name'] is None and events[0]['is_from_me'] is None
    assert run() == []  # new process dedup
    # First-init replay uses a distinct inbox, not an implicit reset.
    base[-1] = str(root / 'replay/inbox.sqlite')
    assert len(run(['--replay-existing'])) == 2
    assert run(['--replay-existing']) == []
    # Follow sees a newly committed source record, then restart deduplicates it.
    process = subprocess.Popen(base + ['--follow', '--interval', '0.1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert process.stdout is not None
    try:
        insert('9007199254740997')
        assert select.select([process.stdout], [], [], 5)[0], 'follow produced no event'
        event = json.loads(process.stdout.readline())
        assert event['log_id'] == '9007199254740997'
        # Wait for acknowledgement through the synthetic inbox, no blind timing race.
        import time
        deadline = time.monotonic() + 5
        while True:
            with sqlite3.connect(base[-1]) as state:
                delivered = state.execute("SELECT count(*) FROM deliveries WHERE state='delivered'").fetchone()[0]
            if delivered == 3:
                break
            assert time.monotonic() < deadline
            time.sleep(0.02)
    finally:
        process.terminate()
        process.wait(timeout=5)
    assert run() == []
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    assert run() == []
    assert before == hashlib.sha256(source.read_bytes()).hexdigest()
    # Closed output pipe must not acknowledge; retry survives process restart.
    insert('9007199254740998')
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    failed = subprocess.run(base + ['--once'], stdout=write_fd, stderr=subprocess.PIPE, timeout=10)
    os.close(write_fd)
    assert failed.returncode != 0
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT state FROM deliveries WHERE state='pending'").fetchone() == ('pending',)
        state.execute("UPDATE deliveries SET available=0 WHERE state='pending'")
    assert len(run()) == 1
    assert run() == []
    con.close()
print('PASS: baseline, replay, large string IDs, restart/dedup, follow, source unchanged, broken-pipe durable retry')
