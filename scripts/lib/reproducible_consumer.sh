#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { printf 'build: error: reproducible consumer requires project root\n' >&2; exit 64; }
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0
python3 - "$1" <<'PY'
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root/'scripts/lib'))
from dependency_build import (BuildError, _accepted_evidence_matches, _canonical_json,
    _input_document, _pinned_tools, adapter_path, resolve_tool_inventory)
from dependency_lock import canonical_bytes, load_lock, topological_records
from dependency_prefix import validate_prefix
from core_stage import validate_core_source
from normalize_link_evidence import (adr_expected_rows, assert_adr_closure, parse_link_command,
                                     validate_omissions, classify_runtime_defaults)

ORDER = ('bzip2','zlib','openssl','miniupnpc','leveldb','libmaxminddb','snappy','boost')
CANDIDATES = ('BZip2','ZLIB','OpenSSLSSL','OpenSSLCrypto','miniupnpc','leveldb','maxminddb',
              'BoostThread','BoostRegex','Snappy','Threads','Iconv')
ARCHIVES = (
    ('BZip2','bzip2','lib/libbz2.a'), ('ZLIB','zlib','lib/libz.a'),
    ('OpenSSLSSL','openssl','lib/libssl.a'), ('OpenSSLCrypto','openssl','lib/libcrypto.a'),
    ('miniupnpc','miniupnpc','lib/libminiupnpc.a'), ('leveldb','leveldb','lib/libleveldb.a'),
    ('maxminddb','libmaxminddb','lib/libmaxminddb.a'), ('Snappy','snappy','lib/libsnappy.a'),
)
output = root/'Build/airdcpp-core/reproducible-link-interface'
core = root/'Build/airdcpp-core/reproducible-release'
checkout = root/'Source/airdcpp-core'
CASE_FIELDS = ('configure-command.txt','configure.log','configure-exit-code.txt',
               'build-command.txt','build.log','build-exit-code.txt')

def fail(message):
    raise BuildError(message)

def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        fail(f'unsafe regular file: {path}')
    return path.read_bytes()

def directory(path, create=False):
    for ancestor in reversed((path,*path.parents)):
        if ancestor.exists() or ancestor.is_symlink():
            if not stat.S_ISDIR(ancestor.lstat().st_mode):
                fail(f'unsafe directory: {ancestor}')
        elif create:
            ancestor.mkdir()
        else:
            fail(f'missing directory: {ancestor}')

def snapshot():
    entries = []
    def visit(parent):
        for path in sorted(parent.iterdir(),key=lambda p:os.fsencode(p.name)):
            if path == output:
                continue
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            identity = (info.st_dev,info.st_ino,stat.S_IMODE(info.st_mode))
            if stat.S_ISLNK(info.st_mode):
                entries.append((relative,identity,'link',os.readlink(path)))
            elif stat.S_ISDIR(info.st_mode):
                entries.append((relative,identity,'directory'))
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                entries.append((relative,identity,'file',info.st_mtime_ns,info.st_size,
                                hashlib.sha256(path.read_bytes()).hexdigest()))
            else:
                fail(f'unsupported scope entry: {relative}')
    visit(root)
    return entries

def write(path, data):
    directory(path.parent,create=True)
    if path.exists() or path.is_symlink():
        regular(path)
    path.write_bytes(data if isinstance(data,bytes) else data.encode())

def digest(path):
    return hashlib.sha256(regular(path)).hexdigest()

def text_rows(rows):
    return ''.join(f'{i}\t{kind}\t{value}\n' for i,(kind,value) in enumerate(rows,1))

def preserve_case(case):
    fields = [p for p in CASE_FIELDS if (case/p).exists()]
    if not fields:
        return
    if len(fields) != len(CASE_FIELDS):
        fail(f'previous case is incomplete: {case}')
    attempts = case/'attempts'
    directory(attempts,create=True)
    for ordinal,path in enumerate(sorted(attempts.iterdir()),1):
        if path.name != f'{ordinal:04d}':
            fail('unexpected case attempt path')
        directory(path)
        manifest = ''.join(digest(path/p)+'  '+p+'\n' for p in CASE_FIELDS)
        if regular(path/'sha256.txt').decode() != manifest:
            fail('case attempt digest changed')
    destination = attempts/f'{len(list(attempts.iterdir()))+1:04d}'
    directory(destination,create=True)
    for field in CASE_FIELDS:
        write(destination/field,regular(case/field))
    write(destination/'sha256.txt',''.join(digest(destination/p)+'  '+p+'\n' for p in CASE_FIELDS))

def preserve_run():
    previous = [p for p in output.iterdir() if p.name != 'history']
    if not previous:
        return
    history = output/'history'
    directory(history,create=True)
    for ordinal,path in enumerate(sorted(history.iterdir()),1):
        if path.name != f'{ordinal:04d}':
            fail('unexpected consumer history path')
        directory(path)
        lines = regular(path/'sha256.txt').decode().splitlines()
        for line in lines:
            expected,separator,relative = line.partition('  ')
            candidate = Path(relative)
            if not separator or candidate.is_absolute() or '..' in candidate.parts:
                fail('unsafe history digest path')
            if digest(path/candidate) != expected:
                fail('consumer history digest changed')
    destination = history/f'{len(list(history.iterdir()))+1:04d}'
    directory(destination,create=True)
    for path in previous:
        if path.is_dir():
            shutil.copytree(path,destination/path.name)
        else:
            write(destination/path.name,regular(path))
    write(destination/'sha256.txt',''.join(digest(p)+'  '+p.relative_to(destination).as_posix()+'\n'
        for p in sorted(destination.rglob('*')) if p.is_file()))

def run_case(name, selected, expectation, tools, environment, sdk):
    case = output/name
    directory(case,create=True)
    preserve_case(case)
    build = case/'build'
    if build.exists():
        directory(build)
        shutil.rmtree(build)
    argv = [tools.host['cmake'],'-S',str(root/'smoke-test'),'-B',str(build),'-G','Ninja',
        '-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_ARCHITECTURES=arm64',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DCMAKE_CXX_STANDARD=20','-DCMAKE_CXX_EXTENSIONS=OFF',
        '-DCMAKE_CXX_COMPILER='+tools.apple['cxx'],'-DCMAKE_OSX_SYSROOT='+str(sdk),
        '-DCMAKE_MAKE_PROGRAM='+tools.host['ninja'],
        '-DAIRDCCORE_INCLUDE_DIR='+str(output/'stage/include'),
        '-DAIRDCCORE_LIBRARY='+str(output/'stage/lib/libairdcpp.a'),
        '-DAIRDCCORE_TEST_LINK_ITEMS=fixture', '-DREPRODUCIBLE_LINK_ITEMS='+';'.join(selected),
        '-DCMAKE_PROJECT_INCLUDE='+str(output/'controlled-static.cmake'),
        '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF','-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF',
        '-DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON','-DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF',
        '-DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF','-DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF',
        '-DCMAKE_FIND_USE_INSTALL_PREFIX=OFF','-DCMAKE_FIND_FRAMEWORK=NEVER','-DCMAKE_FIND_APPBUNDLE=NEVER',
        '-DCMAKE_PREFIX_PATH=','-DCMAKE_MODULE_PATH=','-DCMAKE_FRAMEWORK_PATH=','-DCMAKE_APPBUNDLE_PATH=']
    write(case/'configure-command.txt',shlex.join(argv)+'\n')
    with (case/'configure.log').open('wb') as stream:
        configured = subprocess.run(argv,env=environment,stdout=stream,stderr=subprocess.STDOUT)
    write(case/'configure-exit-code.txt',str(configured.returncode)+'\n')
    if configured.returncode:
        fail(f'consumer configure failed: {case}/configure.log')
    argv = [tools.host['cmake'],'--build',str(build),'--verbose']
    write(case/'build-command.txt',shlex.join(argv)+'\n')
    with (case/'build.log').open('wb') as stream:
        linked = subprocess.run(argv,env=environment,stdout=stream,stderr=subprocess.STDOUT)
    write(case/'build-exit-code.txt',str(linked.returncode)+'\n')
    if expectation == 'success' and linked.returncode:
        fail(f'consumer link failed: {case}/build.log')
    if expectation != 'success' and linked.returncode:
        log = regular(case/'build.log').decode(errors='replace')
        if 'Undefined symbols for architecture arm64' not in log:
            fail(f'consumer omission failed for a reason other than unresolved symbols: {case}/build.log')
    if expectation == 'unresolved' and not linked.returncode:
        fail('Core-only link unexpectedly succeeded')
    return linked.returncode

def controlled_targets(prefixes, iconv, version_tag, commit):
    def quoted(path):
        value = str(path)
        if any(c in value for c in ('"',';','\n','\r','$','\\')):
            fail('CMake input path contains an unsupported character')
        return '"'+value+'"'
    lines = ['function(reproducible_finish_consumer)',
             f'  set_property(TARGET airdcpp-smoke PROPERTY SOURCES {quoted(root/"smoke-test/reproducible-main.cpp")})',
             '  target_compile_definitions(airdcpp-smoke PRIVATE',
             f'    "AIRDCCORE_EXPECTED_VERSION_TAG=\\"{version_tag}\\""',
             f'    "AIRDCCORE_EXPECTED_GIT_COMMIT=\\"{commit}\\"")']
    for prefix in prefixes.values():
        lines.append(f'  target_include_directories(airdcpp-smoke PRIVATE {quoted(prefix/"include")})')
    # Controlled static interfaces expand at their declared physical positions.
    # CMake's default target traversal otherwise appends Crypto after MaxMindDB.
    for logical,component,relative in ARCHIVES:
        condition = f'"{logical}" IN_LIST REPRODUCIBLE_LINK_ITEMS'
        if logical == 'OpenSSLCrypto':
            condition += ' OR "OpenSSLSSL" IN_LIST REPRODUCIBLE_LINK_ITEMS'
        if logical == 'Snappy':
            condition += ' OR "leveldb" IN_LIST REPRODUCIBLE_LINK_ITEMS'
        lines += [f'  if({condition})',
                  f'    target_link_libraries(airdcpp-smoke PRIVATE {quoted(prefixes[component]/relative)})',
                  '  endif()']
    lines += ['  if("Iconv" IN_LIST REPRODUCIBLE_LINK_ITEMS)',
              f'    target_link_libraries(airdcpp-smoke PRIVATE {quoted(iconv)})',
              '  endif()', 'endfunction()',
              'cmake_language(DEFER CALL reproducible_finish_consumer)']
    return '\n'.join(lines)+'\n'

def main():
    directory(root)
    directory(output.parent)
    if output.exists() or output.is_symlink():
        directory(output)
        if any(p.is_symlink() for p in output.rglob('*')):
            fail('symlinked consumer output path')
    before = snapshot()
    try:
        subprocess.run(('/bin/sh','-c','. "$1/scripts/lib/upstream.sh"; . "$1/scripts/lib/configure.sh"; '
            'load_upstream_config "$1/config/upstream.env" && assert_supported_host && '
            'validate_configure_checkout "$1" "$1/Source/airdcpp-core" "$AIRDCPP_CORE_COMMIT"',
            'reproducible-consumer',str(root)),check=True,
            env={**os.environ,'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'diff.autoRefreshIndex',
                 'GIT_CONFIG_VALUE_0':'false'})
        directory(checkout)
        directory(core)
        lock = load_lock(root/'config/dependencies.lock')
        if set(r.name for r in lock.dependencies) != set(ORDER):
            fail('consumer requires the eight locked components')
        tools = resolve_tool_inventory()
        sdk = Path(tools.sdkroot).resolve(strict=True)
        iconv = (sdk/'usr/lib/libiconv.tbd').resolve(strict=True)
        if not iconv.is_relative_to(sdk) or not regular(iconv):
            fail('Iconv is outside the selected SDK')
        reports,prefixes = {},{}
        for record in topological_records(lock):
            component = root/'Build/dependencies'/record.name
            prefix = root/'Build/prefix'/record.name
            directory(prefix)
            directory(component/'evidence')
            adapter = adapter_path(root,record)
            regular(adapter)
            inputs = _input_document(lock,record,adapter,{n:reports[n] for n in record.dependencies},tools)
            fingerprint = hashlib.sha256(_canonical_json(inputs)).hexdigest()+'\n'
            if regular(component/'evidence/input-fingerprint.txt').decode() != fingerprint:
                fail(f'{record.name}: input fingerprint mismatch')
            report = validate_prefix(record,prefix,dict(project=root,source=root/'Dependencies'/record.name,
                build=component,home=component/'home'),tools=_pinned_tools(tools.apple,tools.identities,'apple'))
            if not _accepted_evidence_matches(record,prefix,component/'evidence',report):
                fail(f'{record.name}: accepted evidence mismatch')
            prefixes[record.name] = prefix.resolve(strict=True)
            reports[record.name] = report
        manifests = 'component\tmanifest_sha256\n'+''.join(n+'\t'+reports[n].manifest_sha256+'\n' for n in ORDER)
        for field,expected in (
            ('build-exit-code.txt',b'0\n'), ('tool-inventory.json',_canonical_json(asdict(tools))),
            ('lock-fingerprint.txt',(hashlib.sha256(canonical_bytes(lock)).hexdigest()+'\n').encode()),
            ('component-manifests.tsv',manifests.encode())):
            if regular(core/field) != expected:
                fail(f'Task 8 Core evidence differs: {field}')
        pin = subprocess.check_output(('git','-C',str(checkout),'rev-parse','HEAD'),text=True).strip()
        origin = subprocess.check_output(('git','-C',str(checkout),'remote','get-url','--all','origin'),text=True).strip()
        if regular(core/'upstream-identity.json') != _canonical_json(dict(commit=pin,origin=origin,source_prefix_map='airdcpp-core')):
            fail('Task 8 Core upstream identity differs')
        core_authority = validate_core_source(root,checkout,core,tools,sys.executable)
        staged_source = Path(core_authority['staged_root'])
        header_root = Path(core_authority['header_root'])
        if (staged_source != core/'source' or header_root != staged_source/'airdcpp'
                or core_authority['original_root'] != str(checkout)
                or core_authority['upstream_commit'] != pin or core_authority['complete'] is not True):
            fail('Task 8 staged header authority differs')
        source_evidence = {name:regular(core/name) for name in core_authority['evidence_files']}
        version_authority = json.loads(source_evidence['version-authority.json'])
        version_tag = version_authority['version']['tag']
        archive = core/'upstream/libairdcpp.a'
        directory(archive.parent)
        if regular(core/'archive-sha256.txt').decode() != digest(archive)+'  upstream/libairdcpp.a\n':
            fail('Task 8 Core archive hash differs')
        # No distribution or aggregate path may be created by this experiment.
        if (root/'Dist').exists() or (root/'Dist').is_symlink():
            fail('Dist already exists')
        directory(output,create=True)
        preserve_run()
        write(output/'scope-before.sha256',hashlib.sha256(_canonical_json(before)).hexdigest()+'\n')
        environment = {'PATH':':'.join(dict.fromkeys(str(Path(p).parent) for p in
            (*tools.apple.values(),*tools.host.values(),'/usr/bin/xcrun')))+':/bin',
            'HOME':str(output/'home'),'TMPDIR':str(output/'tmp'),'LANG':'C','LC_ALL':'C',
            'SDKROOT':str(sdk),'MACOSX_DEPLOYMENT_TARGET':'14.0','ZERO_AR_DATE':'1',
            'PYTHONDONTWRITEBYTECODE':'1','GIT_OPTIONAL_LOCKS':'0','PKG_CONFIG_PATH':'','PKG_CONFIG_LIBDIR':''}
        directory(output/'home',create=True)
        directory(output/'tmp',create=True)
        write(output/'environment.json',_canonical_json(environment))
        write(output/'tool-inventory.json',_canonical_json(asdict(tools)))
        write(output/'component-manifests.tsv',manifests)
        write(output/'lock-fingerprint.txt',regular(core/'lock-fingerprint.txt'))
        write(output/'upstream-identity.json',regular(core/'upstream-identity.json'))
        for name,data in source_evidence.items():
            write(output/name,data)
        inspection = output/'core-inspection'
        directory(inspection,create=True)
        subprocess.run((sys.executable,str(root/'scripts/lib/inspect_core_archive.py'),str(archive),
            str(inspection/'archive-members.tsv'),str(inspection/'archive-symbols.txt')),check=True,env=environment)
        for field,argv in (('archive-strings.txt',(tools.apple['strings'],str(archive))),
                           ('archive-ar-table.txt',(tools.apple['ar'],'-t',str(archive)))):
            write(inspection/field,subprocess.check_output(argv,env=environment))
        for field in ('archive-members.tsv','archive-symbols.txt','archive-strings.txt','archive-ar-table.txt'):
            if regular(inspection/field) != regular(core/field):
                fail(f'Task 8 Core archive report differs: {field}')
        write(output/'core-archive-sha256.txt',regular(core/'archive-sha256.txt'))
        write(output/'input-manifest.json',_canonical_json(dict(
            upstream_commit=pin,core_archive_sha256=digest(archive),
            smoke_source_path='smoke-test/reproducible-main.cpp',
            smoke_source_sha256=digest(root/'smoke-test/reproducible-main.cpp'),
            expected_version_tag=version_tag,expected_git_commit=pin,
            core_source_evidence_sha256={name:hashlib.sha256(data).hexdigest() for name,data in source_evidence.items()},
            dependencies=[dict(name=r.name,version=r.version,
                input_fingerprint=regular(root/'Build/dependencies'/r.name/'evidence/input-fingerprint.txt').decode().strip(),
                archives={relative:digest(prefixes[r.name]/relative) for relative in r.expected_archives})
                for r in lock.dependencies])))
        stage = output/'stage'
        if stage.exists():
            directory(stage)
            shutil.rmtree(stage)
        directory(stage/'include',create=True)
        directory(stage/'lib',create=True)
        for source in sorted(header_root.rglob('*')):
            if 'modules' in source.relative_to(header_root).parts:
                continue
            if source.suffix in ('.h','.inc'):
                directory(source.parent)
                write(stage/'include'/source.relative_to(staged_source),regular(source))
        write(stage/'lib/libairdcpp.a',regular(archive))
        write(output/'header-manifest.sha256',''.join(digest(p)+'  '+p.relative_to(stage/'include').as_posix()+'\n'
            for p in sorted((stage/'include').rglob('*')) if p.is_file()))
        write(output/'controlled-static.cmake',controlled_targets(prefixes,iconv,version_tag,pin))
        run_case('core-only',(),'unresolved',tools,environment,sdk)
        run_case('full',CANDIDATES,'success',tools,environment,sdk)
        omissions = ['pass\tordinal\tlogical\tclassification\tbuild_exit\n']
        required = []
        for ordinal,logical in enumerate(CANDIDATES,1):
            status = run_case('omissions/pass-1/'+logical,tuple(i for i in CANDIDATES if i!=logical),
                              'classify',tools,environment,sdk)
            category = 'required' if status else 'transitive'
            if status:
                required.append(logical)
            omissions.append(f'1\t{ordinal}\t{logical}\t{category}\t{status}\n')
        run_case('full',required,'success',tools,environment,sdk)
        for ordinal,logical in enumerate(required,1):
            status = run_case('omissions/pass-2/'+logical,tuple(i for i in required if i!=logical),
                              'classify',tools,environment,sdk)
            if not status:
                fail(f'fixed-point classification changed when omitting {logical}')
            omissions.append(f'2\t{ordinal}\t{logical}\trequired\t{status}\n')
        write(output/'omission-results.tsv',''.join(omissions))
        validate_omissions(output/'omission-results.tsv')
        command_lines = [line for line in regular(output/'full/build.log').decode().splitlines()
            if 'airdcpp-smoke' in line and re.search(r'(?:^|\s)\S*(?:clang\+\+|c\+\+)(?:\s|$)',line)
            and ' -o ' in line and not re.search(r'(?:^|\s)-c(?:\s|$)',line)]
        if len(command_lines) != 1:
            fail('verbose full link must contain exactly one compiler link command')
        command = command_lines[0]
        # Ninja emits a shell wrapper; retain raw evidence while parsing only the driver invocation.
        if '&&' in command:
            command = command.split('&&')[1].strip()
        write(output/'link-command.raw.txt',command+'\n')
        argv = shlex.split(command)
        force = '-Wl,-force_load,'+str(stage/'lib/libairdcpp.a')
        force_position = argv.index(force) if force in argv else -1
        for i in range(1,len(argv)-3):
            if argv[i:i+4] == ['-Xlinker','-force_load','-Xlinker',str(stage/'lib/libairdcpp.a')]:
                force_position = i
        if force_position < 0 or any(arg.endswith(('.a','.tbd','.dylib')) for arg in argv[1:force_position]):
            fail('link contract differs from ADR 0001: Core must be force-loaded first')
        try:
            rows = parse_link_command(command,root,{**prefixes,'apple-sdk':sdk})
        except (OSError,ValueError) as error:
            fail(f'link contract differs from ADR 0001: {error}')
        write(output/'link-interface.tsv',text_rows(rows))
        adr = regular(root/'docs/decisions/0001-aggregate-static-distribution.md').decode()
        relative_iconv = iconv.relative_to(sdk).as_posix()
        write(output/'adr-expected-link-interface.tsv',text_rows(adr_expected_rows(adr,relative_iconv)))
        assert_adr_closure(rows,adr,relative_iconv)
        executable = output/'full/airdcpp-smoke'
        write(executable,regular(output/'full/build/airdcpp-smoke'))
        executable.chmod(0o755)
        write(output/'consumer-sha256.txt',digest(executable)+'\n')
        write(output/'file-tool.json',_canonical_json(dict(path='/usr/bin/file',sha256=digest(Path('/usr/bin/file')))))
        for field,argv in (('binary-file.txt',('/usr/bin/file','-b',str(executable))),
                           ('binary-arch.txt',(tools.apple['lipo'],'-archs',str(executable))),
                           ('otool-load-commands.txt',(tools.apple['otool'],'-L',str(executable))),
                           ('otool-mach-o.txt',(tools.apple['otool'],'-l',str(executable))),
                           ('binary-strings.txt',(tools.apple['strings'],str(executable)))):
            write(output/field,subprocess.check_output(argv,env=environment))
        if regular(output/'binary-arch.txt') != b'arm64\n' or not re.fullmatch(
                r'Mach-O 64-bit executable arm64\s*',regular(output/'binary-file.txt').decode()):
            fail('consumer executable is not exactly ARM64')
        loads = regular(output/'otool-load-commands.txt').decode().splitlines()[1:]
        paths = [line.strip().split(' (',1)[0] for line in loads]
        if set(paths) != {'/usr/lib/libiconv.2.dylib','/usr/lib/libc++.1.dylib','/usr/lib/libSystem.B.dylib'} or len(paths)!=3:
            fail('link contract differs from ADR 0001: non-SDK/toolchain load commands')
        if b'LC_RPATH' in regular(output/'otool-mach-o.txt'):
            fail('link contract differs from ADR 0001: consumer contains an RPATH load command')
        run = output/'run'
        directory(run,create=True)
        with (run/'stdout.txt').open('wb') as stdout,(run/'stderr.txt').open('wb') as stderr:
            result = subprocess.run((str(executable),),stdout=stdout,stderr=stderr,env=environment)
        write(run/'exit-code.txt',str(result.returncode)+'\n')
        if result.returncode or regular(run/'stderr.txt') or regular(run/'stdout.txt') != ('AirDC++ Core '+pin+'\n').encode():
            fail('consumer runtime identity differs from pinned Core')
        openssl = next(record for record in lock.dependencies if record.name=='openssl')
        defaults = dict(item.split('=',1) for item in openssl.install_options
                        if item.startswith(('OPENSSLDIR=','ENGINESDIR=','MODULESDIR=')))
        if defaults != {'OPENSSLDIR':'/usr/local/ssl','ENGINESDIR':'/usr/local/lib/engines-3',
                        'MODULESDIR':'/usr/local/lib/ossl-modules'}:
            fail('unreviewed OpenSSL runtime configuration defaults')
        strings = regular(output/'binary-strings.txt')
        forbidden = (os.fsencode(root),os.fsencode(Path.home())+b'/',b'/Source/',b'/Build/',
                     b'/opt/homebrew',b'/usr/local/Cellar',b'/usr/local/opt/',b'/Users/')
        observed,unexpected = classify_runtime_defaults(strings.decode(errors='replace'),defaults)
        write(output/'openssl-runtime-defaults.json',_canonical_json(dict(version=openssl.version,
            configured=defaults,observed=observed,lock_fingerprint=digest(root/'config/dependencies.lock'))))
        leaks = [p.decode(errors='replace') for p in forbidden if p in strings]+unexpected
        write(output/'path-leak-scan.txt','PASS: no prohibited consumer paths\n' if not leaks else '\n'.join(leaks)+'\n')
        if leaks:
            fail('consumer contains prohibited paths')
        write(output/'adr-comparison.txt','PASS: physical closure and Apple system boundary match ADR 0001\n')
    finally:
        after = snapshot()
        if after != before:
            fail('scope changed outside reproducible-link-interface')
        if output.is_dir() and not output.is_symlink():
            write(output/'scope-after.sha256',hashlib.sha256(_canonical_json(after)).hexdigest()+'\n')
    print('build: reproducible consumer matched ADR 0001; evidence='+str(output))

try:
    main()
except (BuildError,OSError,ValueError,subprocess.CalledProcessError) as error:
    print(f'build: error: reproducible consumer: {error}',file=sys.stderr)
    sys.exit(1)
PY
