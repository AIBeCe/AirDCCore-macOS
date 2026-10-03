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
from unittest.mock import patch

root = Path(sys.argv[1])
self_test = sys.argv[2:] == ['--self-test']
sys.path.insert(0, str(root/'scripts/lib'))
from dependency_acquire import acquire_all
import dependency_build
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

ATTESTED_FIELDS = ('input-fingerprint.txt', 'inputs.json', 'tool-inventory.json',
    'command.json', 'expanded-options.json', 'adapter.log', 'exit-status.txt',
    'prefix-report.json', 'install-manifest.jsonl', 'license-inventory.json')

def confinement_binding(lock, confinement):
    authority = [root/'scripts/build', root/'tests/gate6_dependency_build_test.sh',
                 root/'tests/gate6_contract_test.sh']
    # --build-dependencies dispatches directly to dependency_build.py before
    # scripts/build sources any Core/configure shell helper. Its transitive
    # local imports are these four modules; archive inspection is internal to
    # dependency_prefix.py. Bind all adapter .py helpers exactly as the normal
    # input fingerprint does, and the eight adapter paths selected by the lock.
    authority += [root/'scripts/lib'/name for name in (
        'dependency_build.py', 'dependency_acquire.py', 'dependency_lock.py', 'dependency_prefix.py')]
    authority += [adapter_path(root, record) for record in topological_records(lock)]
    authority += sorted((root/'scripts/lib/dependencies').glob('*.py'))
    components = {}
    for record in topological_records(lock):
        evidence = root/'Build/dependencies'/record.name/'evidence'
        components[record.name] = {field: digest(evidence/field) for field in ATTESTED_FIELDS}
        components[record.name]['prefix_manifest_sha256'] = tree_digest(root/'Build/prefix'/record.name)
    return dict(lock_sha256=fingerprint(lock), confinement=confinement,
        authority={p.relative_to(root).as_posix(): digest(p) for p in authority}, components=components)

def attestation_document(binding, executed, expected):
    if executed != expected:
        fail('confinement attestation requires all locked adapters to complete in order')
    return dict(schema_version=1, result='PASS', executed_adapters=expected, binding=binding)

def attestation_matches(path, binding, expected):
    try:
        return regular(path) == _canonical_json(attestation_document(binding, expected, expected))
    except FileNotFoundError:
        return False

def gate_directory():
    for path in (root/'Build', root/'Build/gate6'):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            fail('unsafe Gate 6 evidence directory')
        path.mkdir(exist_ok=True)
    return root/'Build/gate6'

def archive_attestation(path):
    if not os.path.lexists(path):
        return
    raw = regular(path)
    history = gate_directory()/'confinement-history'
    if history.is_symlink() or (history.exists() and not history.is_dir()):
        fail('unsafe confinement history')
    history.mkdir(exist_ok=True)
    target = history/(hashlib.sha256(raw).hexdigest()+'.json')
    if os.path.lexists(target):
        if regular(target) != raw:
            fail('confinement history hash differs')
        path.unlink()
    else:
        path.rename(target)

def establish_confinement(lock, confinement):
    expected = [r.name for r in topological_records(lock)]
    path = root/'Build/gate6/dependency-confinement.json'
    try:
        binding = confinement_binding(lock, confinement)
    except FileNotFoundError:
        binding = None
    if binding is not None and attestation_matches(path, binding, expected):
        return path
    # Preserve the old binding before invalidation; a failed refresh cannot
    # leave a current PASS marker. The build owner preserves every old attempt.
    archive_attestation(path)
    executed = []
    original = dependency_build.run_adapter
    def observed(record, *args, **kwargs):
        result = original(record, *args, **kwargs)
        executed.append(record.name)
        return result
    dependency_build.run_adapter = observed
    try:
        dependency_build.build_all(root, lock, force_rebuild=True)
    finally:
        dependency_build.run_adapter = original
    boundaries(root)
    prefix_reports(lock, resolve_tool_inventory())
    document = attestation_document(confinement_binding(lock, confinement), executed, expected)
    gate_directory()
    write('dependency-confinement.json', document)
    return path

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
    attestation = establish_confinement(lock, confinement)
    attestation_before = snapshot([attestation])
    tools = resolve_tool_inventory()
    reports = prefix_reports(lock, tools)
    prefixes = {name: report.manifest_sha256 for name, report in reports.items()}
    paths = [root/'Build/prefix', root/'Build/dependencies']
    before = snapshot(paths)
    command(root/'scripts/build', '--build-dependencies')
    unchanged(before, paths, 'prefixes/component evidence')
    command(root/'scripts/build', '--build-dependencies')
    unchanged(before, paths, 'prefixes/component evidence')
    repeated = prefix_reports(lock, tools)
    if {name: report.manifest_sha256 for name, report in repeated.items()} != prefixes:
        fail('second dependency build changed prefix fingerprints')
    unchanged(attestation_before, [attestation], 'confinement attestation')
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
    gate_directory()
    write('network-confinement.json', confinement)
    write('build-validation.json', dict(lock_sha256=fingerprint(lock), prefix_manifests=prefixes,
        dependency_rerun='PASS: prefixes and component evidence unchanged',
        sources='PASS: accepted sources/cache unchanged',
        core_scope='PASS', consumer_scope='PASS', closure='PASS: ADR 0001',
        generated_git_boundary='PASS', distribution='PASS: Dist and aggregate absent'))
    command('/bin/sh', root/'tests/gate6_contract_test.sh', '--live')
    print('PASS: Gate 6 sandboxed dependency build, unchanged rerun, Core, consumer, closure, and report')

class OfflineContracts(unittest.TestCase):
    def test_core_only_changes_preserve_binding_but_dependency_code_invalidates(self):
        global root
        previous = root
        lock = load_lock(root/'config/dependencies.lock')
        with tempfile.TemporaryDirectory(prefix='gate6-authority-', dir='/private/tmp') as name:
            root = Path(name)
            files = ('scripts/build', 'tests/gate6_dependency_build_test.sh',
                'tests/gate6_contract_test.sh', 'scripts/lib/dependency_build.py',
                'scripts/lib/dependency_acquire.py', 'scripts/lib/dependency_lock.py',
                'scripts/lib/dependency_prefix.py', 'scripts/lib/dependencies/command_runner.py',
                'scripts/lib/dependencies/network_adapter.py', 'scripts/lib/reproducible_core.sh',
                'scripts/lib/reproducible_consumer.sh', 'scripts/lib/inspect_core_archive.py')
            for relative in files:
                path = root/relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('initial authority\n')
            for record in lock.dependencies:
                adapter_path(root, record).write_text('adapter\n')
                directory = root/'Build/dependencies'/record.name/'evidence'
                directory.mkdir(parents=True)
                for field in ATTESTED_FIELDS:
                    (directory/field).write_text('accepted evidence\n')
                prefix = root/'Build/prefix'/record.name
                prefix.mkdir(parents=True)
                (prefix/'ingredient').write_text('accepted prefix\n')
            try:
                policy = {'outbound': 'denied', 'localhost': 'allowed'}
                before = confinement_binding(lock, policy)
                path = gate_directory()/'dependency-confinement.json'
                expected = [r.name for r in topological_records(lock)]
                path.write_bytes(_canonical_json(attestation_document(before, expected, expected)))
                for relative in ('scripts/lib/reproducible_core.sh', 'scripts/lib/reproducible_consumer.sh',
                                 'scripts/lib/inspect_core_archive.py'):
                    (root/relative).write_text('Core-only correction\n')
                after = confinement_binding(lock, policy)
                self.assertEqual(after, before)
                self.assertTrue(attestation_matches(path, after, expected))
                for relative in ('scripts/lib/dependencies/command_runner.py',
                                 'scripts/lib/dependencies/build_openssl.sh',
                                 'scripts/lib/dependency_prefix.py'):
                    old = (root/relative).read_bytes()
                    (root/relative).write_text('dependency correction\n')
                    changed = confinement_binding(lock, policy)
                    self.assertNotEqual(changed, before)
                    self.assertFalse(attestation_matches(path, changed, expected))
                    (root/relative).write_bytes(old)
            finally:
                root = previous

    def test_matching_attestation_is_reused_without_rebuild_or_write(self):
        global root
        previous = root
        lock = load_lock(root/'config/dependencies.lock')
        expected = [r.name for r in topological_records(lock)]
        binding = dict(lock_sha256=fingerprint(lock), components={n:{'adapter.log':'a'*64} for n in expected})
        with tempfile.TemporaryDirectory(prefix='gate6-reuse-', dir='/private/tmp') as name:
            root = Path(name)
            path = gate_directory()/'dependency-confinement.json'
            path.write_bytes(_canonical_json(attestation_document(binding, expected, expected)))
            before = snapshot([path])
            try:
                with patch('__main__.confinement_binding', return_value=binding), \
                     patch.object(dependency_build, 'build_all', side_effect=AssertionError('unexpected native rebuild')):
                    self.assertEqual(establish_confinement(lock, {'outbound':'denied'}), path)
                unchanged(before, [path], 'matching attestation')
            finally:
                root = previous

    def test_failed_refresh_has_no_current_attestation_and_preserves_history(self):
        global root
        previous = root
        lock = load_lock(root/'config/dependencies.lock')
        with tempfile.TemporaryDirectory(prefix='gate6-refresh-', dir='/private/tmp') as name:
            root = Path(name)
            path = gate_directory()/'dependency-confinement.json'
            raw = b'previous binding\n'
            path.write_bytes(raw)
            try:
                with patch('__main__.confinement_binding', return_value={'new': 'binding'}), \
                     patch.object(dependency_build, 'build_all', side_effect=ValueError('adapter failed')):
                    with self.assertRaisesRegex(ValueError, 'adapter failed'):
                        establish_confinement(lock, {'outbound': 'denied'})
                self.assertFalse(path.exists())
                history = root/'Build/gate6/confinement-history'/ (hashlib.sha256(raw).hexdigest()+'.json')
                self.assertEqual(history.read_bytes(), raw)
            finally:
                root = previous

    def test_attestation_requires_all_adapters_and_rejects_changed_evidence(self):
        with tempfile.TemporaryDirectory(prefix='gate6-attestation-', dir='/private/tmp') as name:
            path = Path(name)/'dependency-confinement.json'
            binding = dict(lock_sha256='a'*64, components={n: {'adapter.log': 'b'*64} for n in ('a','b')})
            self.assertFalse(attestation_matches(path, binding, ['a','b']))
            with self.assertRaisesRegex(ValueError, 'all locked adapters'):
                attestation_document(binding, ['a'], ['a','b'])
            path.write_bytes(_canonical_json(attestation_document(binding, ['a','b'], ['a','b'])))
            before = snapshot([path])
            self.assertTrue(attestation_matches(path, binding, ['a','b']))
            unchanged(before, [path], 'attestation')
            changed = dict(binding, components={'a': {'adapter.log': 'c'*64}, 'b': {'adapter.log': 'b'*64}})
            self.assertFalse(attestation_matches(path, changed, ['a','b']))

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
