#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv[1])
live = sys.argv[2:] == ['--live']
self_test = sys.argv[2:] == ['--self-test']
if sys.argv[2:] not in ([], ['--live'], ['--self-test']):
    raise SystemExit('FAIL: supported arguments: --live or --self-test')
sys.path.insert(0, str(root/'scripts/lib'))
import dependency_lock
from dependency_lock import fingerprint, load_lock
from normalize_link_evidence import assert_adr_closure

def fail(message):
    raise ValueError(message)

def sha(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        fail('missing or invalid SHA-256')

def evidence(value):
    if not isinstance(value, dict) or set(value) != {'path', 'sha256'}:
        fail('evidence requires relative path and SHA-256')
    path = value['path']
    if (not isinstance(path, str) or not path.startswith('Build/') or
            any(part in ('', '.', '..') for part in path.split('/'))):
        fail('unsafe evidence-relative path')
    sha(value['sha256'])
    if live:
        target = root/path
        if target.is_symlink() or not target.is_file() or not target.resolve().is_relative_to(root):
            fail('missing or unsafe evidence: '+path)
        if hashlib.sha256(target.read_bytes()).hexdigest() != value['sha256']:
            fail('evidence hash differs: '+path)

def nonempty(value, label):
    if not value:
        fail('missing '+label)

def validate():
    lock = load_lock(root/'config/dependencies.lock')
    report = root/'docs/reports/2026-09-23-gate-6-reproducible-dependencies.md'
    if report.is_symlink() or not report.is_file():
        fail('Gate 6 report does not exist')
    text = report.read_text()
    if re.search(r'/Users/|/private/|/opt/homebrew/|/usr/local/Cellar/|/Applications/', text):
        fail('report contains absolute host/worktree/library paths')
    match = re.search(r'```json\n(.*?)\n```', text, re.S)
    if not match:
        fail('report requires normalized JSON acceptance record')
    data = json.loads(match.group(1))
    if data['schema_version'] != 1 or data['status'] != 'accepted':
        fail('Gate 6 report is not accepted')
    if data['lock_sha256'] != fingerprint(lock):
        fail('report lock fingerprint differs')
    if (len(data['dependencies']) != len(lock.dependencies) or
            {row['name'] for row in data['dependencies']} != {r.name for r in lock.dependencies}):
        fail('report must name all eight locked dependencies')
    records = {row['name']: row for row in data['dependencies']}
    for record in lock.dependencies:
        row = records[record.name]
        if (row['version'], row['role'], row['source_url'], row['source_kind'], row['source_identity'],
                row['source_tree_sha256'], row['license_spdx'], row['license_paths'], row['patches']) != (
                record.version, record.role, record.source.url, record.source.kind,
                record.source.commit or record.source.archive_sha256,
                record.source.tree_manifest_sha256, record.license_spdx, list(record.license_paths),
                [{'path': p.path, 'sha256': p.sha256} for p in record.patches]):
            fail(record.name+': report identity/license/patch differs')
        sha(row['prefix_manifest_sha256'])
        evidence(row['prefix_evidence'])
        if set(row['archives']) != set(record.expected_archives):
            fail(record.name+': expected archive inventory differs')
        for digest in row['archives'].values():
            sha(digest)
        if set(row['licenses']) != set(record.license_paths):
            fail(record.name+': notice inventory differs')
        for digest in row['licenses'].values():
            sha(digest)
        nonempty(row['upstream_checks'], record.name+' upstream checks/omissions')
        nonempty(row['installed_checks'], record.name+' installed-consumer checks')
        for check in row['upstream_checks']+row['installed_checks']:
            if check['result'] not in ('PASS', 'OMITTED'):
                fail(record.name+': unresolved library check')
            nonempty(check['description'], 'check description')
            evidence(check['evidence'])
        if not any(c['result'] == 'PASS' for c in row['installed_checks']):
            fail(record.name+': compensating installed check absent')
        if live:
            measured = json.loads((root/row['prefix_evidence']['path']).read_text())
            if measured['manifest_sha256'] != row['prefix_manifest_sha256']:
                fail(record.name+': measured prefix differs from report')
            if {a['path']: a['sha256'] for a in measured['archives']} != row['archives']:
                fail(record.name+': measured archives differ from report')
            for relative, digest in row['licenses'].items():
                if hashlib.sha256((root/'Build/prefix'/record.name/relative).read_bytes()).hexdigest() != digest:
                    fail(record.name+': license hash differs')
    nonempty(data['openssl_lts_exception'], 'OpenSSL LTS exception')
    if '3.5' not in data['openssl_lts_exception'] or '3.6' not in data['openssl_lts_exception']:
        fail('OpenSSL LTS exception must distinguish locked LTS from discovery')
    for field in ('host', 'tools', 'effective_closure', 'system_inputs', 'omissions',
                  'retry_history', 'known_limitations'):
        nonempty(data[field], field)
    if set(data['host']) != {'architecture', 'deployment_target', 'os_version', 'sdk_version'}:
        fail('host record is incomplete')
    if data['host']['architecture'] != 'arm64' or data['host']['deployment_target'] != '14.0':
        fail('report platform differs')
    for name in ('cmake', 'ninja', 'pkg-config', 'make', 'perl', 'python3', 'clang', 'clang++', 'ar', 'ranlib'):
        nonempty(data['tools'].get(name), 'host/tool version '+name)
    sha(data['core']['archive_sha256'])
    evidence(data['core']['evidence'])
    if data['consumer']['runtime_line'] != 'AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352':
        fail('consumer runtime identity differs')
    sha(data['consumer']['executable_sha256'])
    evidence(data['consumer']['evidence'])
    if data['system_inputs'] != ['explicit SDK Iconv', 'implicit libc++', 'implicit libSystem', 'Apple frameworks: none']:
        fail('Apple system boundary differs')
    rows = [tuple(row) for row in data['effective_closure']]
    if not rows or rows[-1][0] != 'apple-sdk':
        fail('SDK closure input missing')
    assert_adr_closure(rows, (root/'docs/decisions/0001-aggregate-static-distribution.md').read_text(), rows[-1][1])
    for name in ('snappy', 'leveldb'):
        if name not in str(data['omissions']).lower() or 'GoogleTest' not in str(data['omissions']):
            fail('disabled GoogleTest suites/compensating checks missing')
    acceptance = data['acceptance']
    if set(acceptance) != {str(i) for i in range(1, 13)}:
        fail('all twelve acceptance criteria are required')
    for row in acceptance.values():
        if row['result'] != 'PASS':
            fail('unresolved acceptance criterion')
        nonempty(row['evidence'], 'acceptance evidence')
        for item in row['evidence']:
            evidence(item)
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', 'Source', 'Dependencies', 'Build', 'Dist'])
    if tracked:
        fail('generated inputs/outputs are tracked')
    if os.path.lexists(root/'Dist') or (root/'Build/lib/libairdcpp.a').exists():
        fail('Dist or aggregate archive exists')
    if live:
        core_archive = root/'Build/airdcpp-core/reproducible-release/upstream/libairdcpp.a'
        executable = root/'Build/airdcpp-core/reproducible-link-interface/full/airdcpp-smoke'
        for path, expected in ((core_archive, data['core']['archive_sha256']),
                               (executable, data['consumer']['executable_sha256'])):
            if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                fail('report artifact hash differs')
        consumer = root/'Build/airdcpp-core/reproducible-link-interface'
        measured = [tuple(line.split('\t')[1:]) for line in (consumer/'link-interface.tsv').read_text().splitlines()]
        if measured != rows:
            fail('report measured closure differs')
        tracked_report = subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch', '--',
                                        str(report.relative_to(root))], capture_output=True)
        if tracked_report.returncode:
            fail('accepted report is not tracked')

class ReportContracts(unittest.TestCase):
    def setUp(self):
        global root
        self.previous = root
        self.previous_lock_root = dependency_lock.ROOT
        self.temp = tempfile.TemporaryDirectory(prefix='gate6-report-', dir='/private/tmp')
        root = Path(self.temp.name)
        shutil.copytree(self.previous/'config', root/'config')
        adr = Path('docs/decisions/0001-aggregate-static-distribution.md')
        (root/adr).parent.mkdir(parents=True)
        shutil.copy2(self.previous/adr, root/adr)
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'add', 'config'], check=True)
        dependency_lock.ROOT = root
        lock = load_lock(root/'config/dependencies.lock')
        ref = {'path': 'Build/gate6/fixture.json', 'sha256': 'a'*64}
        check = {'result': 'PASS', 'description': 'fixture check', 'evidence': ref}
        from normalize_link_evidence import adr_expected_rows
        self.data = dict(schema_version=1, status='accepted', lock_sha256=fingerprint(lock),
            dependencies=[dict(name=r.name, version=r.version, role=r.role, source_url=r.source.url,
                source_kind=r.source.kind, source_identity=r.source.commit or r.source.archive_sha256,
                source_tree_sha256=r.source.tree_manifest_sha256, license_spdx=r.license_spdx,
                license_paths=list(r.license_paths), patches=[dict(path=p.path, sha256=p.sha256) for p in r.patches],
                prefix_manifest_sha256='a'*64, prefix_evidence=ref,
                archives={p:'a'*64 for p in r.expected_archives}, licenses={p:'a'*64 for p in r.license_paths},
                upstream_checks=[check], installed_checks=[check]) for r in lock.dependencies],
            openssl_lts_exception='3.5 LTS replaces 3.6 discovery',
            host=dict(architecture='arm64', deployment_target='14.0', os_version='fixture', sdk_version='fixture'),
            tools={n:'fixture' for n in ('cmake','ninja','pkg-config','make','perl','python3','clang','clang++','ar','ranlib')},
            core=dict(archive_sha256='a'*64, evidence=ref),
            consumer=dict(runtime_line='AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352', executable_sha256='a'*64, evidence=ref),
            effective_closure=adr_expected_rows((root/adr).read_text(), 'usr/lib/libiconv.tbd'),
            system_inputs=['explicit SDK Iconv','implicit libc++','implicit libSystem','Apple frameworks: none'],
            omissions=['snappy and leveldb GoogleTest disabled; installed checks compensate'],
            retry_history=['fixture: none'], known_limitations=['fixture: no publication'],
            acceptance={str(i):dict(result='PASS', evidence=[ref]) for i in range(1,13)})

    def tearDown(self):
        global root
        root = self.previous
        dependency_lock.ROOT = self.previous_lock_root
        self.temp.cleanup()

    def write_report(self):
        report = root/'docs/reports/2026-09-23-gate-6-reproducible-dependencies.md'
        report.parent.mkdir(exist_ok=True)
        report.write_text('# Fixture only\n\n```json\n'+json.dumps(self.data)+'\n```\n')

    def test_complete_normalized_report_is_accepted(self):
        self.write_report()
        validate()

    def test_omitted_acceptance_or_lock_drift_is_rejected(self):
        del self.data['acceptance']['12']
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'all twelve'):
            validate()
        self.data['acceptance']['12'] = dict(result='PASS', evidence=[{'path':'Build/fixture','sha256':'a'*64}])
        self.data['lock_sha256'] = 'b'*64
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'lock fingerprint differs'):
            validate()

    def test_new_closure_or_absolute_evidence_is_rejected(self):
        self.data['effective_closure'].insert(1, ['component:boost','lib/libboost_regex.a'])
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'differs from ADR'):
            validate()
        self.data['effective_closure'].pop(1)
        self.data['acceptance']['1']['evidence'] = [{'path':'/absolute/Build/fixture','sha256':'a'*64}]
        self.write_report()
        with self.assertRaisesRegex(ValueError, 'unsafe evidence'):
            validate()

if self_test:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReportContracts)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        raise SystemExit(1)
    subprocess.run(['/bin/sh', str(root/'tests/gate6_dependency_build_test.sh'), '--self-test'], check=True)
    raise SystemExit(0)
try:
    validate()
except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
    raise SystemExit('FAIL: '+str(error))
print('PASS: Gate 6 normalized report, locked identities, and generated-path boundaries')
PY
