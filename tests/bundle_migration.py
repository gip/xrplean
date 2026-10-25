"""Version-2 bundle migration preserves IDs, foreign keys, anchors and blocked attempts."""
import json
from pathlib import Path
import sqlite3
import tempfile

from acquisition import Node, STATE_ROOT
from integration import backend, cli, request


def main():
    with tempfile.TemporaryDirectory(prefix='xl-bundle-migration-') as directory:
        data = Path(directory) / 'data'
        data.mkdir()
        with sqlite3.connect(data / 'xl.sqlite3') as db:
            db.executescript('''
                CREATE TABLE ledgers(id INTEGER PRIMARY KEY,network INTEGER NOT NULL,idx INTEGER NOT NULL,
                  hash TEXT NOT NULL,parent_hash TEXT NOT NULL,state_root TEXT NOT NULL,header_json TEXT,
                  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,UNIQUE(network,hash));
                CREATE TABLE exports(id INTEGER PRIMARY KEY,ledger_id INTEGER NOT NULL REFERENCES ledgers(id),
                  digest TEXT NOT NULL,payload TEXT NOT NULL,received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,UNIQUE(ledger_id,digest));
                CREATE TABLE trust_anchors(id INTEGER PRIMARY KEY,ledger_id INTEGER NOT NULL UNIQUE REFERENCES ledgers(id),
                  reason TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE states(ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id),sources_json TEXT NOT NULL,
                  origin TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE state_downloads(ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id),path TEXT NOT NULL UNIQUE,
                  status TEXT NOT NULL,updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE peer_downloads(ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id),path TEXT NOT NULL UNIQUE,
                  status TEXT NOT NULL,updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE jobs(id INTEGER PRIMARY KEY,network INTEGER NOT NULL,first_idx INTEGER NOT NULL,last_idx INTEGER NOT NULL,
                  checks_json TEXT NOT NULL,status TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE job_items(job_id INTEGER NOT NULL REFERENCES jobs(id),idx INTEGER NOT NULL,export_id INTEGER REFERENCES exports(id),
                  status TEXT NOT NULL DEFAULT 'pending',error TEXT NOT NULL DEFAULT '',PRIMARY KEY(job_id,idx));
                CREATE TABLE verifications(id INTEGER PRIMARY KEY,job_id INTEGER NOT NULL REFERENCES jobs(id),export_id INTEGER NOT NULL REFERENCES exports(id),
                  kind TEXT NOT NULL,status TEXT NOT NULL,anchor_id INTEGER REFERENCES trust_anchors(id),
                  parent_verification_id INTEGER REFERENCES verifications(id),report_json TEXT NOT NULL,artifacts_json TEXT NOT NULL,
                  attempt_dir TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
                PRAGMA user_version=2;
            ''')
            db.execute('INSERT INTO ledgers(id,network,idx,hash,parent_hash,state_root) VALUES(11,0,200,?,?,?)',
                       (Node.hash200, '00'*32, STATE_ROOT))
            db.execute("INSERT INTO exports(id,ledger_id,digest,payload) VALUES(61,11,'legacy-blocked-fixture','{}')")
            db.execute("INSERT INTO trust_anchors(id,ledger_id,reason) VALUES(41,11,'explicit legacy anchor')")
            db.execute("INSERT INTO states(ledger_id,sources_json,origin) VALUES(11,'[]','imported_witnesses')")
            db.execute("INSERT INTO jobs(id,network,first_idx,last_idx,checks_json,status,error) VALUES(51,0,201,201,'[\"merkle\"]','blocked','legacy blocked fixture')")
            db.execute("INSERT INTO job_items(job_id,idx,export_id,status) VALUES(51,201,61,'blocked')")
            db.execute("INSERT INTO verifications(id,job_id,export_id,kind,status,anchor_id,report_json,artifacts_json) VALUES(71,51,61,'merkle','blocked',41,'{}','[]')")
        with backend(data) as (url, _):
            job = request(url, '/jobs/51')
            assert job['status'] == 'blocked' and job['verifications'][0]['verification_id'] == '71'
            assert cli(url, 'ledgers')[0]['trust'] == 'operator_trusted'
            assert cli(url, 'state', 'info')['ledger_count'] == 0  # witness import is not a full base
            cli(url, 'trust', 200, Node.hash200, '--bundle', 'other')
            assert 'conflicts by case' in cli(url, 'trust', 200, Node.hash200, '--bundle', 'Other', success=False)
            assert cli(url, 'exports', '--bundle', 'other')[0]['merkle'] == 'not_checked'
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('PRAGMA user_version').fetchone()[0] == 4
                assert not db.execute('PRAGMA foreign_key_check').fetchall()
                assert db.execute('SELECT id,bundle,ledger_id FROM trust_anchors ORDER BY id').fetchall() == [(41, 'default', 11), (42, 'other', 11)]
                assert db.execute('SELECT anchor_id FROM verifications WHERE id=71').fetchone()[0] == 41
                assert db.execute('SELECT bundle FROM jobs WHERE id=51').fetchone()[0] == 'default'
        with backend(data) as (url, _):
            assert cli(url, 'job', 51)['status'] == 'blocked'
            assert cli(url, 'ledgers', '--bundle', 'other')[0]['trust'] == 'operator_trusted'
            assert cli(url, 'jobs', '--bundle', 'other') == []
        print('PASS v2-to-v4 migration, preserved IDs/foreign keys/anchors/blocked attempts, witness ineligibility, bundle scope, case collision, restart')


if __name__ == '__main__':
    main()
