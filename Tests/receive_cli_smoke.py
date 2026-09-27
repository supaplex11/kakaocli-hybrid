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
    # Durable retry drains before missing or locked source failures, with health on stderr.
    for unavailable in ('missing', 'locked'):
        with sqlite3.connect(base[-1]) as state:
            state.execute("UPDATE deliveries SET state='pending',available=0,token=NULL WHERE rowid=(SELECT min(rowid) FROM deliveries)")
        original_source = base[base.index('--notification-db') + 1]
        if unavailable == 'missing':
            base[base.index('--notification-db') + 1] = str(root / 'missing.sqlite')
        else:
            con.execute('BEGIN EXCLUSIVE')
        try:
            recovered = subprocess.run(base + ['--once'], capture_output=True, text=True, timeout=10)
            assert recovered.returncode == 1, recovered.stderr
            assert len(recovered.stdout.splitlines()) == 1
            assert 'Source health:' in recovered.stderr
        finally:
            base[base.index('--notification-db') + 1] = original_source
            if unavailable == 'locked':
                con.rollback()
        with sqlite3.connect(base[-1]) as state:
            assert state.execute("SELECT count(*) FROM deliveries WHERE state='pending'").fetchone()[0] == 0

    # A fixed invocation batch cannot drain an unbounded producer/backlog.
    for log in range(2000, 2105):
        insert(str(log))
    assert len(run()) == 100
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT count(*) FROM deliveries WHERE state='pending'").fetchone()[0] == 5
    assert len(run()) == 5

    # Both signals unwind idle waits and active backpressured writes, with no live lease.
    import signal
    import time
    for sig in (signal.SIGINT, signal.SIGTERM):
        for active in (False, True):
            with sqlite3.connect(base[-1]) as state:
                state.execute("UPDATE deliveries SET state='delivered',token=NULL")
                if active:
                    rowid, payload = state.execute("SELECT rowid,payload FROM deliveries LIMIT 1").fetchone()
                    obj = json.loads(payload)
                    obj['text'] = 'synthetic' * 100000
                    state.execute("UPDATE deliveries SET payload=?,state='pending',available=0 WHERE rowid=?", (json.dumps(obj), rowid))
            args = base + ['--follow', '--interval', '3600']
            if not active:
                args[args.index('--notification-db') + 1] = str(root / 'idle-missing.sqlite')
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert process.stdout is not None and process.stderr is not None
            try:
                deadline = time.monotonic() + 5
                if active:
                    while True:
                        with sqlite3.connect(base[-1]) as state:
                            leased = state.execute("SELECT count(*) FROM deliveries WHERE state='leased'").fetchone()[0]
                        if leased:
                            break
                        assert time.monotonic() < deadline
                        time.sleep(0.01)
                else:
                    assert select.select([process.stderr], [], [], 5)[0], 'idle receiver not ready'
                    assert b'Source health:' in process.stderr.readline()
                    assert process.poll() is None
                start = time.monotonic()
                process.send_signal(sig)
                assert process.wait(timeout=3) == 0
                assert time.monotonic() - start < 3
                with sqlite3.connect(base[-1]) as state:
                    assert state.execute("SELECT count(*) FROM deliveries WHERE state='leased'").fetchone()[0] == 0
                    if active:
                        assert state.execute("SELECT count(*) FROM deliveries WHERE state='pending'").fetchone()[0] == 1
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
                process.stderr.close()
    # Retention option: real CLI pruning, no payload resurrection from retained source.
    base[-1] = str(root / 'retention/inbox.sqlite')
    assert len(run(['--replay-existing', '--retention-seconds', '0'])) == 100
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT count(*) FROM deliveries WHERE state='delivered'").fetchone()[0] == 0
        assert state.execute("SELECT count(*) FROM deliveries WHERE state='pending'").fetchone()[0] > 0
    assert len(run(['--retention-seconds', '0'])) > 0
    assert run(['--replay-existing', '--retention-seconds', '0']) == []
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT count(*) FROM deliveries").fetchone()[0] == 0
        assert state.execute("SELECT count(*) FROM observations").fetchone()[0] > 0
    insert('99999')
    assert len(run()) == 1  # default seven-day window retains a new acknowledgement
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT count(*) FROM deliveries").fetchone()[0] == 1
        state.execute("UPDATE deliveries SET terminal_at=0")  # synthetic clock ageing only
    assert run() == []
    with sqlite3.connect(base[-1]) as state:
        assert state.execute("SELECT count(*) FROM deliveries").fetchone()[0] == 0
    for invalid in ('-1', 'nan', 'inf'):
        rejected = subprocess.run(base + ['--once', '--retention-seconds', invalid], capture_output=True, text=True, timeout=10)
        assert rejected.returncode != 0 and '--retention-seconds' in rejected.stderr
    con.close()
print('PASS: baseline, replay, string IDs, dedup, follow, source unchanged, broken-pipe retry, missing/locked source recovery, 100-event bound, SIGINT/SIGTERM idle/active unwind, retention default/zero/validation/replay')
