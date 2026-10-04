#!/bin/sh
set -eu
case "$#:${1:-}" in
  0:) ;;
  2:--verify) ;;
  *) printf 'FAIL: supported arguments: --verify DIST\n' >&2; exit 64 ;;
esac
if [ "${AIRDCCORE_RUN_DISTRIBUTION_TESTS:-0}" != 1 ]; then
  printf 'SKIP: set AIRDCCORE_RUN_DISTRIBUTION_TESTS=1 for native Gate 7\n'
  exit 0
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
exec python3 - "$ROOT" "$@" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'scripts/lib'))
from distribution_aggregate import canonical, regular, sha
from distribution_package import files_in, package, verify_package

work = Path(tempfile.mkdtemp(prefix='airdc-gate7-', dir='/private/tmp'))
started = time.monotonic()
try:
    verify_only = sys.argv[2:3] == ['--verify']
    first = None
    if verify_only:
        source = Path(sys.argv[3]).absolute()
    else:
        package(root)
        first = regular(root / 'Dist/metadata/checksums.sha256')
        (work / 'first-checksums.sha256').write_bytes(first)
        package(root)
        source = root / 'Dist'
        second = regular(source / 'metadata/checksums.sha256')
        (work / 'second-checksums.sha256').write_bytes(second)
        if first != second:
            raise ValueError('complete distribution rerun inventory/content differs')
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', 'Source', 'Dependencies', 'Build', 'Dist'])
    if tracked:
        raise ValueError('generated source/build/distribution paths are tracked')
    relocated = work / 'relocated/Dist'
    shutil.copytree(source, relocated)
    private = [root / name for name in ('Source', 'Dependencies', 'Build')]
    def audit(event, arguments):
        if event == 'open' and isinstance(arguments[0], (str, bytes)):
            path = Path(arguments[0]).resolve()
            if any(path == base or base in path.parents for base in private):
                raise ValueError('Gate 7 public verification opened private input')
    sys.addaudithook(audit)
    verified = verify_package(relocated, root, fresh_consumer=True, consumer_evidence=work / 'consumer')
    # Adversarial copies rewrite their checksum files: these cases must fail on
    # the independent payload/provenance contract, not merely stale checksums.
    tampered = work / 'tampered'
    shutil.copytree(relocated, tampered)
    def resign():
        inventory = ''.join(sha(regular(path)) + '  ' + name + '\n'
            for name, path in files_in(tampered).items() if name != 'metadata/checksums.sha256')
        (tampered / 'metadata/checksums.sha256').write_text(inventory)
    def rejects(label):
        try:
            verify_package(tampered, root)
        except (ValueError, OSError, KeyError, TypeError):
            return label
        raise ValueError('Gate 7 tampered package accepted: ' + label)
    negative = []
    proof_path = tampered / 'metadata/consumer-proof.json'
    original = regular(proof_path)
    proof = json.loads(original)
    proof['result'] = 'pending'
    proof_path.write_bytes(canonical(proof))
    resign()
    negative.append(rejects('pending/unproved consumer'))
    proof_path.write_bytes(original)
    # Resolve the declared Core license path, rather than assuming its layout.
    manifest = json.loads(regular(tampered / 'metadata/manifest.json'))
    notice = tampered / next(row['path'] for row in manifest['licenses'] if row['path'].endswith('GPL-3.0.txt'))
    notice_bytes = regular(notice)
    notice.unlink()
    resign()
    negative.append(rejects('missing original license material'))
    notice.write_bytes(notice_bytes)
    archive = tampered / 'lib/libairdcpp.a'
    archive_bytes = regular(archive)
    archive.write_bytes(archive_bytes + b'drift')
    resign()
    negative.append(rejects('archive payload drift'))
    receipt = dict(schema_version=1, mode='verification-only' if verify_only else 'complete Gate 7',
        result='PASS', verified=verified, private_input_reads=0, negative_cases=negative,
        rerun_inventory_equal=None if verify_only else True,
        checksums_sha256=sha(regular(relocated / 'metadata/checksums.sha256')),
        consumer_proof_sha256=sha(regular(relocated / 'metadata/consumer-proof.json')),
        elapsed_seconds=round(time.monotonic() - started, 3))
    (work / 'receipt.json').write_bytes(canonical(receipt))
    print('Gate 7: PASS ' + json.dumps(receipt, sort_keys=True))
    print('Private evidence: ' + str(work))
except Exception as error:
    print('Gate 7: FAIL ' + str(error), file=sys.stderr)
    print('Retained private evidence: ' + str(work), file=sys.stderr)
    sys.exit(1)
PY
