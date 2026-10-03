#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { printf 'build: error: reproducible Core requires project root\n' >&2; exit 64; }
# Imports are read-only: dependency validation must not create ignored bytecode
# beside the accepted adapters or shared orchestration helpers.
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
python3 - "$1" <<'PY'
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'scripts/lib'))
from dependency_build import (BuildError, _accepted_evidence_matches, _canonical_json,
                              _input_document, _pinned_tools, adapter_path, resolve_tool_inventory)
from dependency_lock import canonical_bytes, load_lock, topological_records
from dependency_prefix import validate_prefix

ORDER = ('bzip2', 'zlib', 'openssl', 'miniupnpc', 'leveldb', 'libmaxminddb', 'snappy', 'boost')
TARGETS = ('BZip2::BZip2', 'ZLIB::ZLIB', 'OpenSSL::SSL', 'OpenSSL::Crypto',
           'miniupnpc::miniupnpc', 'leveldb::leveldb', 'maxminddb::maxminddb',
           'Boost::thread', 'Boost::regex', 'Snappy::snappy', 'Threads::Threads', 'Iconv::Iconv')
output = root / 'Build/airdcpp-core/reproducible-release'

def fail(message):
    raise BuildError(message)

def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        fail(f'unsafe regular file: {path}')
    return path.read_bytes()

def safe_directory(path, *, create=False):
    # Check every ancestor before allowing writes or resolving a supplied path.
    for ancestor in reversed((path, *path.parents)):
        if ancestor.exists() or ancestor.is_symlink():
            if not stat.S_ISDIR(ancestor.lstat().st_mode):
                fail(f'unsafe directory: {ancestor}')
        elif create:
            ancestor.mkdir()
        else:
            fail(f'missing directory: {ancestor}')

def snapshot():
    entries = []
    def visit(directory):
        for path in sorted(directory.iterdir(), key=lambda p: os.fsencode(p.name)):
            if path == output:
                continue
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            identity = (info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode))
            if stat.S_ISLNK(info.st_mode):
                entries.append((relative, identity, 'link', os.readlink(path)))
            elif stat.S_ISDIR(info.st_mode):
                entries.append((relative, identity, 'directory'))
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                entries.append((relative, identity, 'file', info.st_mtime_ns,
                                info.st_size, hashlib.sha256(path.read_bytes()).hexdigest()))
            else:
                fail(f'unsupported scope entry: {relative}')
    visit(root)
    return entries

def write(name, data):
    safe_directory(output)
    path = output / name
    if path.exists() or path.is_symlink():
        regular(path)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())

def command(argv, log, status_name, env):
    write('command.txt' if log == 'configure.log' else 'build-command.txt', shlex.join(argv)+'\n')
    path = output / log
    if path.exists() or path.is_symlink():
        regular(path)
    with path.open('wb') as stream:
        result = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, env=env)
    write(status_name, str(result.returncode)+'\n')
    if result.returncode:
        fail(f'{"Core configure" if log == "configure.log" else "Core build"} failed (status {result.returncode}); log: {path}')

def beneath(path, prefix):
    return path == prefix or prefix in path.parents

def check_summary(prefixes, sdk, toolchain, tools):
    summary = regular(output / 'airdcpp-configure-summary.txt').decode()
    scalar_paths = {'compiler.c.path', 'compiler.cxx.path', 'sdk'}
    path_lists = {'target.include_directories'}
    link_lists = {'compiler.cxx.implicit_link_libraries', 'target.interface_libraries'}
    metadata_fields = {
        'compiler.id', 'compiler.c.id', 'architecture', 'deployment_target',
        'build_type', 'cxx_standard', 'cxx_standard_required',
        'cxx_extensions', 'build_shared_libs', 'enable_natpmp', 'enable_tbb',
        'source.file_prefix_map', 'parent.version', 'parent.tag_application',
        'parent.application_id', 'parent.resource_directory',
        'parent.global_config_directory', 'parent.project_name',
        'target.name', 'target.exists', 'target.type',
        'target.imported_configurations',
    }
    for line in summary.splitlines():
        key, separator, value = line.partition('=')
        if not separator:
            fail('malformed configure summary field')
        if key == 'upstream_source':
            if value != str(root/'Source/airdcpp-core'):
                fail('unexpected Core source in configure summary')
            continue
        if key in scalar_paths:
            paths = (value,)
        elif key in path_lists:
            paths = value.split(';')
        elif key in link_lists:
            # Target names and reviewed expressions are checked by the CMake
            # target audit. Check complete absolute members here.
            paths = tuple(item for item in value.split(';') if Path(item).is_absolute())
        elif re.fullmatch(r'target\.imported_location(?:\.[A-Z0-9_]+)?', key):
            paths = (value,)
        elif key in metadata_fields:
            continue
        else:
            fail(f'unknown configure summary field: {key}')
        for token in paths:
            if not token:
                continue
            path = Path(token)
            if not path.is_absolute() or not path.exists():
                fail(f'undeclared resolution path: {token}')
            real = path.resolve(strict=True)
            owners = [name for name, prefix in prefixes.items() if beneath(real, prefix)]
            if len(owners) == 1:
                continue
            if not owners and (beneath(real, sdk) or beneath(real, toolchain)):
                continue
            fail(f'undeclared resolution path: {token}')
    tsv = regular(output / 'dependency-resolution.tsv').decode()
    lines = tsv.splitlines()
    if not lines or lines[0] != 'target\tproperty\tclassification\tvalue':
        fail('invalid dependency-resolution.tsv header')
    seen = set()
    for line in lines[1:]:
        fields = line.split('\t')
        if len(fields) != 4:
            fail('malformed dependency-resolution.tsv row')
        target, prop, category, value = fields
        seen.add(target)
        if category.startswith('component:'):
            name = category.removeprefix('component:')
            marker = '$PREFIX/'+name
            if name not in prefixes or not (value == marker or value.startswith(marker+'/')):
                fail('invalid normalized component resolution')
            path = prefixes[name] / value[len(marker):].lstrip('/')
            real = path.resolve(strict=True)
            if not beneath(real, prefixes[name]):
                fail('normalized component path escapes prefix')
        elif category == 'apple-system':
            if value.startswith('$SDK/'):
                path = sdk / value[5:]
                allowed = sdk
            elif value.startswith('$TOOLCHAIN/'):
                path = toolchain / value[11:]
                allowed = toolchain
            else:
                fail('invalid normalized Apple system resolution')
            if not beneath(path.resolve(strict=True), allowed):
                fail('normalized Apple system path escapes root')
        elif category == 'target':
            if prop != 'TYPE' and value not in seen and value not in TARGETS:
                # Recursive targets may appear later in sorted evidence.
                if not any(row.startswith(value+'\tTYPE\ttarget\t') for row in lines[1:]):
                    fail('unrecorded dependency target')
        elif category == 'generator-target':
            if not re.fullmatch(r'\$<LINK_ONLY:[A-Za-z0-9_.:+-]+>', value):
                fail('unsafe normalized generator expression')
        elif category == 'apple-thread-toolchain':
            if target != 'Threads::Threads' or value not in ('-pthread', '-lpthread', 'pthread'):
                fail('unreviewed thread toolchain resolution')
        else:
            fail('unknown dependency resolution classification')
    if not set(TARGETS).issubset(seen):
        fail('missing required target in dependency resolution evidence')

def main():
    safe_directory(root)
    # Parent containers belong to the preserved tree; require them to exist.
    safe_directory(output.parent)
    if output.exists() or output.is_symlink():
        safe_directory(output)
        if any(p.is_symlink() for p in output.rglob('*')):
            fail('symlinked reproducible output path')
    before = snapshot()
    try:
        subprocess.run(('/bin/sh', '-c', '. "$1/scripts/lib/upstream.sh"; '
                        '. "$1/scripts/lib/configure.sh"; '
                        'load_upstream_config "$1/config/upstream.env" && assert_supported_host && '
                        'validate_configure_checkout "$1" "$1/Source/airdcpp-core" "$AIRDCPP_CORE_COMMIT"',
                        'reproducible-core', str(root)), check=True,
                       env={**os.environ, 'GIT_CONFIG_COUNT': '1',
                            'GIT_CONFIG_KEY_0': 'diff.autoRefreshIndex', 'GIT_CONFIG_VALUE_0': 'false'})
        safe_directory(root/'Source/airdcpp-core')
        for relative in ('airdcpp/core/version.inc', 'airdcpp/core/localization/StringDefs.cpp'):
            generated = root/'Source/airdcpp-core'/relative
            if generated.exists() or generated.is_symlink():
                safe_directory(generated.parent)
                regular(generated)
        regular(root/'config/dependencies.lock')
        lock = load_lock(root/'config/dependencies.lock')
        if set(record.name for record in lock.dependencies) != set(ORDER):
            fail('reproducible Core requires the eight locked components')
        tools = resolve_tool_inventory()
        sdk = Path(tools.sdkroot).resolve(strict=True)
        cc = Path(tools.apple['cc']).resolve(strict=True)
        toolchain = next((p for p in cc.parents if p.name.endswith('.xctoolchain')), None)
        if toolchain is None:
            fail('Apple compiler is outside an Xcode toolchain')
        iconv = (sdk/'usr/lib/libiconv.tbd').resolve(strict=True)
        if not beneath(iconv, sdk) or not iconv.is_file():
            fail('SDK Iconv is not a real SDK stub')
        reports, prefixes = {}, {}
        for record in topological_records(lock):
            component = root/'Build/dependencies'/record.name
            evidence = component/'evidence'
            prefix = root/'Build/prefix'/record.name
            safe_directory(prefix)
            safe_directory(evidence)
            adapter = adapter_path(root, record)
            regular(adapter)
            inputs = _input_document(lock, record, adapter,
                                     {n: reports[n] for n in record.dependencies}, tools)
            fingerprint = hashlib.sha256(_canonical_json(inputs)).hexdigest()+'\n'
            if regular(evidence/'input-fingerprint.txt').decode() != fingerprint:
                fail(f'{record.name}: input fingerprint mismatch')
            report = validate_prefix(record, prefix, dict(project=root,
                source=root/'Dependencies'/record.name, build=component, home=component/'home'),
                tools=_pinned_tools(tools.apple, tools.identities, 'apple'))
            if not _accepted_evidence_matches(record, prefix, evidence, report):
                fail(f'{record.name}: accepted evidence mismatch')
            prefixes[record.name] = prefix.resolve(strict=True)
            reports[record.name] = report
        safe_directory(output, create=True)
        for private in ('home', 'tmp'):
            safe_directory(output/private, create=True)
        write('tool-inventory.json', _canonical_json(asdict(tools)))
        checkout = root/'Source/airdcpp-core'
        write('upstream-identity.json', _canonical_json({
            'commit': subprocess.check_output(('git', '-C', str(checkout), 'rev-parse', 'HEAD'), text=True).strip(),
            'origin': subprocess.check_output(('git', '-C', str(checkout), 'remote', 'get-url', '--all', 'origin'), text=True).strip(),
            'source_prefix_map': 'airdcpp-core'}))
        write('scope-before.sha256', hashlib.sha256(_canonical_json(before)).hexdigest()+'\n')
        write('lock-fingerprint.txt', hashlib.sha256(canonical_bytes(lock)).hexdigest()+'\n')
        write('component-manifests.tsv', 'component\tmanifest_sha256\n'+''.join(
            f'{name}\t{reports[name].manifest_sha256}\n' for name in ORDER))
        environment = {'PATH': ':'.join(dict.fromkeys(str(Path(p).parent) for p in
                       (*tools.apple.values(), *tools.host.values(), '/usr/bin/xcrun')))+':/bin',
                       'HOME': str(output/'home'), 'TMPDIR': str(output/'tmp'),
                       'LANG': 'C', 'LC_ALL': 'C', 'SDKROOT': str(sdk),
                       'PKG_CONFIG_PATH': '', 'PKG_CONFIG_LIBDIR': os.pathsep.join(
                           str(prefixes[n]/'lib/pkgconfig') for n in ORDER),
                       'MACOSX_DEPLOYMENT_TARGET': '14.0', 'ZERO_AR_DATE': '1',
                       'PYTHONDONTWRITEBYTECODE': '1', 'GIT_OPTIONAL_LOCKS': '0'}
        # No ambient CMake, compiler, pkg-config or library search variables.
        write('environment.json', _canonical_json(environment))
        argv = [tools.host['cmake'], '--fresh', '-S', str(root), '-B', str(output), '-G', 'Ninja',
                '-DCMAKE_TOOLCHAIN_FILE='+str(root/'cmake/toolchains/macos-arm64.cmake'),
                '-DCMAKE_MAKE_PROGRAM='+tools.host['ninja'], '-DCMAKE_OSX_SYSROOT='+str(sdk),
                '-DAIRDCCORE_REPRODUCIBLE_INPUTS=ON', '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',
                '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON',
                '-DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF', '-DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF',
                '-DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF', '-DCMAKE_FIND_USE_INSTALL_PREFIX=OFF',
                '-DCMAKE_FIND_FRAMEWORK=NEVER', '-DCMAKE_FIND_APPBUNDLE=NEVER',
                '-DCMAKE_FRAMEWORK_PATH=', '-DCMAKE_APPBUNDLE_PATH=', '-DCMAKE_MODULE_PATH=',
                '-DCMAKE_PREFIX_PATH='+';'.join(str(prefixes[n]) for n in ORDER),
                '-DBZIP2_ROOT='+str(prefixes['bzip2']), '-DZLIB_ROOT='+str(prefixes['zlib']),
                '-DOPENSSL_ROOT_DIR='+str(prefixes['openssl']),
                '-DBZIP2_INCLUDE_DIR='+str(prefixes['bzip2']/'include'),
                '-DBZIP2_LIBRARY_RELEASE='+str(prefixes['bzip2']/'lib/libbz2.a'),
                '-DZLIB_INCLUDE_DIR='+str(prefixes['zlib']/'include'),
                '-DZLIB_LIBRARY_RELEASE='+str(prefixes['zlib']/'lib/libz.a'),
                '-DOPENSSL_INCLUDE_DIR='+str(prefixes['openssl']/'include'),
                '-DOPENSSL_SSL_LIBRARY='+str(prefixes['openssl']/'lib/libssl.a'),
                '-DOPENSSL_CRYPTO_LIBRARY='+str(prefixes['openssl']/'lib/libcrypto.a'),
                '-DIconv_INCLUDE_DIR='+str(sdk/'usr/include'), '-DIconv_LIBRARY='+str(iconv),
                '-DAIRDCCORE_APPLE_TOOLCHAIN_ROOT='+str(toolchain)]
        argv.extend('-DAIRDCCORE_'+n.upper()+'_PREFIX='+str(prefixes[n]) for n in ORDER)
        command(argv, 'configure.log', 'exit-code.txt', environment)
        write('cache.txt', regular(output/'CMakeCache.txt'))
        check_summary(prefixes, sdk, toolchain, tools)
        command([tools.host['cmake'], '--build', str(output), '--target', 'airdcpp',
                 '--config', 'Release', '--parallel', '2'], 'build.log', 'build-exit-code.txt', environment)
        archive = output/'upstream/libairdcpp.a'
        safe_directory(archive.parent)
        if not regular(archive):
            fail('Core archive is empty')
        subprocess.run((sys.executable, str(root/'scripts/lib/inspect_core_archive.py'), str(archive),
                        str(output/'archive-members.tsv'), str(output/'archive-symbols.txt')), check=True, env=environment)
        for name, argv in (('archive-strings.txt', (tools.apple['strings'], str(archive))),
                           ('archive-ar-table.txt', (tools.apple['ar'], '-t', str(archive)))):
            write(name, subprocess.check_output(argv, env=environment))
        write('archive-sha256.txt', hashlib.sha256(regular(archive)).hexdigest()+'  upstream/libairdcpp.a\n')
        strings = regular(output/'archive-strings.txt')
        forbidden = (b'/opt/homebrew', b'/usr/local/Cellar', os.fsencode(root),
                     os.fsencode(Path.home())+b'/', b'/Source/', b'/Build/')
        leaks = [item.decode(errors='backslashreplace') for item in forbidden if item in strings]
        write('path-leak-scan.txt', 'PASS: no prohibited archive paths\n' if not leaks else '\n'.join(leaks)+'\n')
        if leaks:
            fail('archive contains a prohibited absolute path')
    finally:
        after = snapshot()
        if output.exists() and not output.is_symlink():
            write('scope-after.sha256', hashlib.sha256(_canonical_json(after)).hexdigest()+'\n')
            write('scope-status.txt', '0\n' if after == before else '1\n')
        if after != before:
            initial = {entry[0]: entry for entry in before}
            final = {entry[0]: entry for entry in after}
            changed = sorted(path for path in initial.keys() | final.keys()
                             if initial.get(path) != final.get(path))
            fail('scope changed outside reproducible-release: '+', '.join(changed[:12]))
    print(f'build: reproducible Core archive candidate={output}/upstream/libairdcpp.a')

try:
    main()
except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
    print(f'build: error: reproducible Core: {error}', file=sys.stderr)
    sys.exit(1)
PY
