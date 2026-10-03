#!/bin/sh
set -eu
case "${1:-}" in
  --self-test) [ "$#" -eq 1 ] || exit 64 ;;
  '')
    if [ "${AIRDCCORE_RUN_DEPENDENCY_TESTS:-0}" != 1 ]; then
      printf 'SKIP: set AIRDCCORE_RUN_DEPENDENCY_TESTS=1 for live dependency builds\n'
      exit 0
    fi ;;
  *) printf 'FAIL: supported argument: --self-test\n' >&2; exit 64 ;;
esac
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
[ -x /usr/bin/sandbox-exec ] || { printf 'FAIL: network sandbox is unavailable\n' >&2; exit 1; }
# Confinement covers this Python process and every acquisition validator, adapter,
# compiler, upstream test and installed consumer it starts. Local OpenSSL TLS
# self-tests are allowed; remote sockets are refused by the kernel.
exec /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))' \
  python3 - "$ROOT" "$@" <<'PY'
from dataclasses import asdict
import errno
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv[1])
self_test = sys.argv[2:] == ['--self-test']
sys.path.insert(0, str(root/'scripts/lib'))
from dependency_acquire import acquire_all
from dependency_build import (_accepted_evidence_matches, _canonical_json, _input_document,
                              _pinned_tools, adapter_path, resolve_tool_inventory)
from dependency_lock import fingerprint, load_lock, topological_records
from dependency_prefix import tree_digest, validate_prefix
from normalize_link_evidence import assert_adr_closure

def fail(message):
    raise ValueError(message)

def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        fail('unsafe evidence file: '+str(path))
    return path.read_bytes()

def digest(path):
    return hashlib.sha256(regular(path)).hexdigest()

def network_probe():
    # TEST-NET-3 is a literal address: no DNS or external service is needed.
    # A timeout/refused route is insufficient; only kernel EPERM/EACCES proves
    # this process cannot open an outbound connection.
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        with socket.create_connection(listener.getsockname(), timeout=3) as client:
            with listener.accept()[0] as accepted:
                client.sendall(b'gate6')
                if accepted.recv(5) != b'gate6':
                    fail('localhost network probe failed')
    probe = 'import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(("203.0.113.1", 9)))'
    result = subprocess.run([sys.executable, '-c', probe], text=True, capture_output=True, check=True)
    if result.stdout.strip() not in (str(errno.EPERM), str(errno.EACCES)):
        fail('outbound network sandbox probe was not denied by policy')
    return {'profile': '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))',
            'outbound': 'PASS: child socket denied by policy', 'localhost': 'PASS: loopback socket permitted'}

def boundaries(project):
    tracked = subprocess.check_output(['git', '-C', str(project), 'ls-files', 'Source', 'Dependencies', 'Build', 'Dist'])
    if tracked:
        fail('generated inputs/outputs are tracked')
    if os.path.lexists(project/'Dist') or os.path.lexists(project/'Build/lib/libairdcpp.a'):
        fail('Dist or aggregate archive exists')

def snapshot(paths):
    entries = []
    def visit(path):
        info = path.lstat()
        identity = (info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode))
        if stat.S_ISLNK(info.st_mode):
            entries.append((str(path), identity, 'link', os.readlink(path)))
        elif stat.S_ISDIR(info.st_mode):
            entries.append((str(path), identity, 'directory'))
            for child in sorted(path.iterdir()):
                visit(child)
        elif stat.S_ISREG(info.st_mode):
            entries.append((str(path), identity, 'file', info.st_mtime_ns, info.st_size, digest(path)))
        else:
            fail('unsupported snapshot entry')
    for path in paths:
        visit(path)
    return entries

def unchanged(before, paths, label):
    if snapshot(paths) != before:
        fail(label+' changed during no-op build')

def command(*argv):
    # Inherit stdout/stderr: a growing log inside this project would violate
    # the Core/consumer outside-output snapshots. Operators log outside it.
    subprocess.run([str(a) for a in argv], check=True)
    boundaries(root)

def write(name, value):
    target = root/'Build/gate6'/name
    if target.is_symlink():
        fail('symlinked gate evidence')
    target.write_bytes(_canonical_json(value))

def prefix_reports(lock, tools):
    reports = {}
    for record in topological_records(lock):
        prefix = root/'Build/prefix'/record.name
        component = root/'Build/dependencies'/record.name
        evidence = component/'evidence'
        report = validate_prefix(record, prefix, dict(project=root, source=root/'Dependencies'/record.name,
            build=component, home=component/'home'), tools=_pinned_tools(tools.apple, tools.identities, 'apple'))
        inputs = _input_document(lock, record, adapter_path(root, record),
                                 {n: reports[n] for n in record.dependencies}, tools)
        if regular(evidence/'input-fingerprint.txt').decode() != hashlib.sha256(_canonical_json(inputs)).hexdigest()+'\n':
            fail(record.name+': input fingerprint differs')
        if not _accepted_evidence_matches(record, prefix, evidence, report):
            fail(record.name+': accepted evidence differs')
        reports[record.name] = report
    return reports

def main():
    confinement = network_probe()
    boundaries(root)
    lock = load_lock(root/'config/dependencies.lock')
    # This is validation, never acquisition: accepted sources and verified
    # offline caches must already exist, and the complete tree is unchanged.
    source_paths = [root/'Dependencies']
    source_before = snapshot(source_paths)
    acquire_all(root, lock, True)
    unchanged(source_before, source_paths, 'accepted sources/cache')
    command(root/'scripts/build', '--build-dependencies')
    tools = resolve_tool_inventory()
    reports = prefix_reports(lock, tools)
    prefixes = {name: report.manifest_sha256 for name, report in reports.items()}
    paths = [root/'Build/prefix', root/'Build/dependencies']
    before = snapshot(paths)
    command(root/'scripts/build', '--build-dependencies')
    unchanged(before, paths, 'prefixes/component evidence')
    repeated = prefix_reports(lock, tools)
    if {name: report.manifest_sha256 for name, report in repeated.items()} != prefixes:
        fail('second dependency build changed prefix fingerprints')
    # Do not write any Gate 6 evidence while these scoped child modes run.
    command(root/'scripts/build', '--build-reproducible-core')
    command(root/'scripts/build', '--link-reproducible-consumer')
    prefix_reports(lock, tools)
    unchanged(source_before, source_paths, 'accepted sources/cache')
    consumer = root/'Build/airdcpp-core/reproducible-link-interface'
    rows = []
    for index, line in enumerate(regular(consumer/'link-interface.tsv').decode().splitlines(), 1):
        ordinal, kind, value = line.split('\t')
        if ordinal != str(index):
            fail('invalid ordered link-interface evidence')
        rows.append((kind, value))
    sdk = Path(tools.sdkroot).resolve(strict=True)
    iconv = (sdk/'usr/lib/libiconv.tbd').resolve(strict=True).relative_to(sdk).as_posix()
    assert_adr_closure(rows, regular(root/'docs/decisions/0001-aggregate-static-distribution.md').decode(), iconv)
    for filename, expected in (
        ('adr-comparison.txt', 'PASS: physical closure and Apple system boundary match ADR 0001\n'),
        ('path-leak-scan.txt', 'PASS: no prohibited consumer paths\n'),
        ('run/exit-code.txt', '0\n'),
        ('run/stdout.txt', 'AirDC++ Core 55d51ceb817ec006d4ec844d9e3788e1b0ccc352\n')):
        if regular(consumer/filename).decode() != expected:
            fail('consumer verification differs: '+filename)
    if digest(consumer/'full/airdcpp-smoke')+'\n' != regular(consumer/'consumer-sha256.txt').decode():
        fail('consumer executable hash differs')
    if regular(consumer/'scope-before.sha256') != regular(consumer/'scope-after.sha256'):
        fail('consumer outside-output scope changed')
    core = root/'Build/airdcpp-core/reproducible-release'
    if regular(core/'scope-before.sha256') != regular(core/'scope-after.sha256'):
        fail('Core outside-output scope changed')
    gate = root/'Build/gate6'
    if gate.is_symlink() or (gate.exists() and not gate.is_dir()):
        fail('unsafe Gate 6 evidence directory')
    gate.mkdir(exist_ok=True)
    write('network-confinement.json', confinement)
    write('build-validation.json', dict(lock_sha256=fingerprint(lock), prefix_manifests=prefixes,
        dependency_rerun='PASS: prefixes and component evidence unchanged',
        sources='PASS: accepted sources/cache unchanged',
        core_scope='PASS', consumer_scope='PASS', closure='PASS: ADR 0001',
        generated_git_boundary='PASS', distribution='PASS: Dist and aggregate absent'))
    command('/bin/sh', root/'tests/gate6_contract_test.sh', '--live')
    print('PASS: Gate 6 sandboxed dependency build, unchanged rerun, Core, consumer, closure, and report')

class OfflineContracts(unittest.TestCase):
    def test_descendant_outbound_denied_and_localhost_allowed(self):
        self.assertEqual(network_probe()['outbound'], 'PASS: child socket denied by policy')

    def test_noop_guard_rejects_prefix_content_or_mtime_drift(self):
        with tempfile.TemporaryDirectory(prefix='gate6-noop-', dir='/private/tmp') as name:
            directory = Path(name)
            path = directory/'prefix.a'
            path.write_text('accepted')
            before = snapshot([directory])
            unchanged(before, [directory], 'fixture')
            path.write_text('changed')
            with self.assertRaisesRegex(ValueError, 'changed during no-op'):
                unchanged(before, [directory], 'fixture')

    def test_distribution_and_index_boundaries_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='gate6-boundary-', dir='/private/tmp') as name:
            project = Path(name)
            subprocess.run(['git', 'init', '-q', name], check=True)
            boundaries(project)
            (project/'Dist').symlink_to('missing')
            with self.assertRaisesRegex(ValueError, 'Dist or aggregate'):
                boundaries(project)
            (project/'Dist').unlink()
            (project/'Dependencies').mkdir()
            (project/'Dependencies/tracked').write_text('wrong')
            subprocess.run(['git', '-C', name, 'add', 'Dependencies/tracked'], check=True)
            with self.assertRaisesRegex(ValueError, 'are tracked'):
                boundaries(project)

if self_test:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OfflineContracts)
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
try:
    main()
except (ValueError, OSError, subprocess.CalledProcessError) as error:
    raise SystemExit('FAIL: '+str(error))
PY
