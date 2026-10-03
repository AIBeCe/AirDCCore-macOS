#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import asdict

ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT / 'scripts/lib'))
import dependency_build as deps
from dependency_lock import canonical_bytes, load_lock, topological_records
from dependency_prefix import validate_prefix

ORDER = ('bzip2', 'zlib', 'openssl', 'miniupnpc', 'leveldb', 'libmaxminddb', 'snappy', 'boost')
TARGETS = ('BZip2::BZip2', 'ZLIB::ZLIB', 'OpenSSL::SSL', 'OpenSSL::Crypto',
           'miniupnpc::miniupnpc', 'leveldb::leveldb', 'maxminddb::maxminddb',
           'Boost::thread', 'Boost::regex', 'Snappy::snappy', 'Threads::Threads', 'Iconv::Iconv')

def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)

def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)

class ControlledCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='airdc-repro-core-', dir='/private/tmp')
        cls.work = Path(cls.temp.name)
        cls.bin = cls.work / 'bin'
        cls.bin.mkdir()
        cls.tools = deps.resolve_tool_inventory()
        cls.real_cmake = cls.tools.host['cmake']
        cls.lock = load_lock(ROOT / 'config/dependencies.lock')
        cls.archive = cls.work / 'fixture.a'
        write(cls.work / 'tiny.c', 'int core_fixture(void) { return 42; }\n')
        subprocess.run((cls.tools.apple['cc'], '-arch', 'arm64', '-mmacosx-version-min=14.0',
                        '-c', str(cls.work / 'tiny.c'), '-o', str(cls.work / 'tiny.o')), check=True)
        subprocess.run((cls.tools.apple['ar'], 'rcs', str(cls.archive), str(cls.work / 'tiny.o')), check=True)
        cls.template = cls.work / 'template'
        shutil.copytree(ROOT / 'scripts', cls.template / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copytree(ROOT / 'config', cls.template / 'config')
        shutil.copytree(ROOT / 'cmake', cls.template / 'cmake')
        shutil.copy2(ROOT / 'CMakeLists.txt', cls.template / 'CMakeLists.txt')
        checkout = cls.template / 'Source/airdcpp-core'
        checkout.mkdir(parents=True)
        subprocess.run(('git', 'init', '-q', str(checkout)), check=True)
        write(checkout / 'state.txt', 'pinned\n')
        for name, value in (('user.name', 'Tests'), ('user.email', 'tests@example.invalid'),
                            ('commit.gpgsign', 'false')):
            subprocess.run(('git', '-C', str(checkout), 'config', name, value), check=True)
        subprocess.run(('git', '-C', str(checkout), 'add', 'state.txt'), check=True)
        subprocess.run(('git', '-C', str(checkout), 'commit', '-qm', 'fixture'), check=True)
        pin = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
        subprocess.run(('git', '-C', str(checkout), 'checkout', '-q', '--detach'), check=True)
        subprocess.run(('git', '-C', str(checkout), 'remote', 'add', 'origin', 'https://example.invalid/core.git'), check=True)
        write(cls.template / 'config/upstream.env',
              f'AIRDCPP_CORE_URL=https://example.invalid/core.git\nAIRDCPP_CORE_COMMIT={pin}\n')
        # Stub external tool discovery only. Prefix inspection, acceptance checks,
        # fingerprints, scope checks and orchestration execute production code.
        sdk_fixture = cls.work / 'SDK with spaces'
        sdk_stub = (Path(cls.tools.sdkroot) / 'usr/lib/libiconv.tbd').resolve()
        (sdk_fixture / 'usr/lib').mkdir(parents=True)
        (sdk_fixture / 'usr/include').mkdir()
        shutil.copy2(sdk_stub, sdk_fixture / 'usr/lib' / sdk_stub.name)
        (sdk_fixture / 'usr/lib/libiconv.tbd').symlink_to(sdk_stub.name)
        cls.tools = deps.ToolInventory(str(sdk_fixture), cls.tools.sdk_version, cls.tools.apple,
                                       {**cls.tools.host, 'cmake': str(cls.bin / 'cmake')}, cls.tools.identities)
        write(cls.work / 'tools.json', json.dumps(asdict(cls.tools)))
        write(cls.bin / 'python3', f'''#!{sys.executable}
import json, sys
from pathlib import Path
if sys.argv[1] != '-':
    import os
    os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])
sys.path.insert(0, str(Path(sys.argv[2]) / 'scripts/lib'))
import dependency_build as d
d.resolve_tool_inventory = lambda: d.ToolInventory(**json.loads(Path({str(cls.work / 'tools.json')!r}).read_text()))
sys.argv=sys.argv[1:]
exec(compile(sys.stdin.read(), '<reproducible-core>', 'exec'), {{'__name__': '__main__'}})
''', True)
        write(cls.bin / 'cmake', f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
control=json.loads(Path({str(cls.work/'control.json')!r}).read_text())
with open(control['CALLS'], 'a') as f:
    f.write(json.dumps({{'argv':args, 'env':dict(os.environ)}})+'\\n')
out=Path(args[1] if args[0]=='--build' else args[args.index('-B')+1])
if control.get('MUTATE'):
    Path(control['MUTATE']).write_text('unexpected mutation')
if args[0]=='--build':
    if control.get('BUILD_FAIL'): sys.exit(29)
    if control.get('REAL_GENERATOR'):
        import subprocess
        result = subprocess.run([{cls.real_cmake!r}, '--build', str(out),
                                 '--target', 'core_python_generator'])
        if result.returncode: sys.exit(result.returncode)
    import shutil
    (out/'upstream').mkdir(exist_ok=True)
    shutil.copyfile({str(cls.archive)!r},out/'upstream/libairdcpp.a')
else:
    if control.get('REAL_CONFIGURE'):
        import subprocess
        result = subprocess.run([
            {cls.real_cmake!r}, *args,
            '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
            '-DCMAKE_C_COMPILER_WORKS=TRUE',
            '-DCMAKE_CXX_COMPILER_WORKS=TRUE',
        ])
        sys.exit(result.returncode)
    (out/'CMakeCache.txt').write_text('CMAKE_BUILD_TYPE:STRING=Release\\n')
    prefix=next(a.split('=',1)[1] for a in args if a.startswith('-DAIRDCCORE_BZIP2_PREFIX='))
    (out/'airdcpp-configure-summary.txt').write_text('target.name=BZip2::BZip2\\ntarget.imported_location='+control.get('BAD_PATH',prefix+'/lib/libbz2.a')+'\\n')
    rows=['target\\tproperty\\tclassification\\tvalue']
    for target in {TARGETS!r}:
        rows.append(target+'\\tTYPE\\ttarget\\tINTERFACE_LIBRARY')
    rows.append('BZip2::BZip2\\tIMPORTED_LOCATION\\tcomponent:bzip2\\t$PREFIX/bzip2/lib/libbz2.a')
    (out/'dependency-resolution.tsv').write_text('\\n'.join(rows)+'\\n')
''', True)
        reports = {}
        for record in topological_records(cls.lock):
            prefix = cls.template / 'Build/prefix' / record.name
            for relative in (*record.expected_headers, *record.license_paths):
                write(prefix / relative, 'fixture\n')
            for relative in record.expected_metadata:
                write(prefix / relative, '# fixture\n' if relative.endswith('.cmake') else
                      'prefix=${pcfiledir}/../..\nName: fixture\nVersion: 1.0\nLibs: -L${prefix}/lib -lfixture\n')
            for relative in record.expected_archives:
                (prefix / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(cls.archive, prefix / relative)
            if record.name == 'bzip2':
                (prefix / 'include/headers with spaces').mkdir()
            component = cls.template / 'Build/dependencies' / record.name
            evidence = component / 'evidence'
            roots = dict(project=cls.template, source=cls.template / 'Dependencies' / record.name,
                         build=component, home=component / 'home')
            report = validate_prefix(record, prefix, roots, tools=cls.tools.apple)
            reports[record.name] = report
            inputs = deps._input_document(cls.lock, record, deps.adapter_path(cls.template, record),
                                         {name: reports[name] for name in record.dependencies}, cls.tools)
            write(evidence / 'input-fingerprint.txt', hashlib.sha256(deps._canonical_json(inputs)).hexdigest()+'\n')
            write(evidence / 'prefix-report.json', deps._canonical_json(report.as_dict()).decode())
            write(evidence / 'install-manifest.jsonl', report.manifest)
            write(evidence / 'license-inventory.json', deps._canonical_json([
                dict(path='$PREFIX/'+relative, sha256=hashlib.sha256((prefix/relative).read_bytes()).hexdigest())
                for relative in record.license_paths]).decode())
            write(evidence / 'exit-status.txt', '0\n')
        write(cls.template / 'Build/airdcpp-core/core-release/historical.txt', 'Gate 3\n')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.work, prefix='case-'))
        shutil.copytree(self.template, self.case, dirs_exist_ok=True)
        self.calls = self.work / ('calls-'+self.case.name)
        self.output = self.case / 'Build/airdcpp-core/reproducible-release'
        self.env = {**os.environ, 'PATH': str(self.bin)+':'+os.environ['PATH'], 'CALLS': str(self.calls),
                    'PYTHONDONTWRITEBYTECODE': '1', 'HOME': str(self.work/'ambient-home')}
        write(self.work/'ambient-home/.cmake/packages/LevelDB/poisoned', '/opt/homebrew/poison\n')
        for key in ('CMAKE_PREFIX_PATH', 'CMAKE_FRAMEWORK_PATH', 'CMAKE_APPBUNDLE_PATH',
                    'PKG_CONFIG_PATH', 'CPATH', 'LIBRARY_PATH', 'CMAKE_MODULE_PATH', 'CFLAGS', 'LDFLAGS'):
            self.env[key] = '/opt/homebrew/poison'

    def invoke(self, **env):
        write(self.work/'control.json', json.dumps({'CALLS': str(self.calls), **env}))
        return run('/bin/sh', str(self.case / 'scripts/build'), '--build-reproducible-core', env={**self.env, **env})

    def failed(self, expected, **env):
        result = self.invoke(**env)
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn(expected, result.stdout+result.stderr)
        return result

    def test_controlled_resolution_and_archive_evidence(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        configure = calls[0]
        args = configure['argv']
        self.assertIn('-DCMAKE_PREFIX_PATH='+';'.join(str(self.case/'Build/prefix'/n) for n in ORDER), args)
        for key, name in (('BZIP2_ROOT','bzip2'), ('ZLIB_ROOT','zlib'), ('OPENSSL_ROOT_DIR','openssl')):
            self.assertIn(f'-D{key}={self.case}/Build/prefix/{name}', args)
        for key in ('CMAKE_FIND_USE_PACKAGE_REGISTRY', 'CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY',
                    'CMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH', 'CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH',
                    'CMAKE_FIND_USE_CMAKE_SYSTEM_PATH'):
            self.assertIn(f'-D{key}=OFF', args)
        self.assertIn('-DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON', args)
        self.assertIn('-DPYTHON_EXECUTABLE='+sys.executable, args)
        self.assertIn('-DIconv_INCLUDE_DIR='+str(Path(self.tools.sdkroot).resolve()/'usr/include'), args)
        self.assertIn('-DIconv_LIBRARY='+str((Path(self.tools.sdkroot)/'usr/lib/libiconv.tbd').resolve()), args)
        for key in ('CMAKE_PREFIX_PATH','CMAKE_FRAMEWORK_PATH','CMAKE_APPBUNDLE_PATH','PKG_CONFIG_PATH','CPATH','LIBRARY_PATH','CFLAGS','LDFLAGS'):
            self.assertFalse(configure['env'].get(key), key)
        self.assertEqual(Path(configure['env']['HOME']), self.output/'home')
        for name in ('command.txt','tool-inventory.json','lock-fingerprint.txt','component-manifests.tsv',
                     'cache.txt','airdcpp-configure-summary.txt','dependency-resolution.tsv','build.log',
                     'build-exit-code.txt','archive-members.tsv','archive-symbols.txt','archive-strings.txt',
                     'archive-sha256.txt','path-leak-scan.txt'):
            self.assertTrue((self.output/name).is_file(), name)
        self.assertEqual((self.case/'Build/airdcpp-core/core-release/historical.txt').read_text(), 'Gate 3\n')
        interpreter = json.loads((self.output/'core-python.json').read_text())
        self.assertEqual(interpreter, {
            'invocation_path': sys.executable,
            'resolved_path': str(Path(sys.executable).resolve()),
            'sha256': hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest(),
            'version': 'Python '+sys.version.split()[0],
        })
        self.assertEqual(json.loads((self.output/'tool-inventory.json').read_text()), asdict(self.tools))

    def test_rejects_contaminated_summary_before_build(self):
        for bad in ('/opt/homebrew/lib/libbad.a', '/usr/local/Cellar/zlib/lib/libz.a',
                    str(Path.home()/'libbad.a'), '/private/tmp/undeclared/libbad.a',
                    '/private/tmp/foreign prefix/libbad.a'):
            with self.subTest(path=bad):
                self.failed('undeclared resolution path', BAD_PATH=bad)
                calls = [json.loads(line)['argv'] for line in self.calls.read_text().splitlines()]
                self.assertFalse(any(args[0]=='--build' for args in calls))

    def test_complete_real_summary_accepts_prefix_and_sdk_paths_with_spaces(self):
        self.complete_real_summary()

    def test_upstream_python_generator_runs_with_disabled_discovery(self):
        fingerprints = {name: (self.case/'Build/dependencies'/name/'evidence/input-fingerprint.txt').read_bytes()
                        for name in ORDER}
        self.complete_real_summary(with_generator=True)
        self.assertEqual((self.output/'upstream/generated.txt').read_text(), sys.executable+'\n')
        self.assertEqual(fingerprints, {
            name: (self.case/'Build/dependencies'/name/'evidence/input-fingerprint.txt').read_bytes()
            for name in ORDER})

    def complete_real_summary(self, with_generator=False):
        spaced_case = self.case.with_name(self.case.name + ' with spaces')
        self.case.rename(spaced_case)
        self.case = spaced_case
        self.output = self.case / 'Build/airdcpp-core/reproducible-release'
        checkout = self.case / 'Source/airdcpp-core'
        imports = (
            ('BZip2::BZip2', 'bzip2', 'libbz2.a'),
            ('ZLIB::ZLIB', 'zlib', 'libz.a'),
            ('OpenSSL::SSL', 'openssl', 'libssl.a'),
            ('OpenSSL::Crypto', 'openssl', 'libcrypto.a'),
            ('miniupnpc::miniupnpc', 'miniupnpc', 'libminiupnpc.a'),
            ('leveldb::leveldb', 'leveldb', 'libleveldb.a'),
            ('maxminddb::maxminddb', 'libmaxminddb', 'libmaxminddb.a'),
            ('Boost::thread', 'boost', 'libboost_thread.a'),
            ('Boost::regex', 'boost', 'libboost_regex.a'),
            ('Snappy::snappy', 'snappy', 'libsnappy.a'),
        )
        lines = ['cmake_minimum_required(VERSION 3.25)',
                 'project(SummaryFixture LANGUAGES C CXX)']
        for target, component, archive in imports:
            prefix = self.case / 'Build/prefix' / component
            includes = str(prefix / 'include')
            if component == 'bzip2':
                includes += ';' + str(prefix / 'include/headers with spaces')
            lines.extend((
                f'add_library({target} STATIC IMPORTED GLOBAL)',
                f'set_target_properties({target} PROPERTIES '
                f'IMPORTED_CONFIGURATIONS RELEASE '
                f'IMPORTED_LOCATION_RELEASE "{prefix}/lib/{archive}" '
                f'INTERFACE_INCLUDE_DIRECTORIES "{includes}")',
            ))
        lines.extend((
            'add_library(Threads::Threads INTERFACE IMPORTED GLOBAL)',
            'set_property(TARGET leveldb::leveldb PROPERTY '
            'INTERFACE_LINK_LIBRARIES "snappy;Threads::Threads")',
            'add_library(Iconv::Iconv INTERFACE IMPORTED GLOBAL)',
            f'set_target_properties(Iconv::Iconv PROPERTIES '
            f'INTERFACE_INCLUDE_DIRECTORIES "{self.tools.sdkroot}/usr/include" '
            f'INTERFACE_LINK_LIBRARIES "{self.tools.sdkroot}/usr/lib/libiconv.tbd")',
            'file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/tiny.cpp" '
            '"int fixture_core() { return 1; }\\n")',
            'add_library(airdcpp STATIC "${CMAKE_CURRENT_BINARY_DIR}/tiny.cpp")',
            'target_link_libraries(airdcpp PRIVATE leveldb::leveldb)',
        ))
        if with_generator:
            # Mirrors upstream's actual Python search and custom-command use;
            # the generated output stays inside the fixture build directory.
            lines.extend((
                'find_program(PYTHON_EXECUTABLE NAMES python3 python PATHS /sw/bin)',
                'if(NOT PYTHON_EXECUTABLE)',
                '  message(FATAL_ERROR "Could not find python executable")',
                'endif()',
                'add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated.txt" '
                'COMMAND "${PYTHON_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/generate_fixture.py" '
                '"${CMAKE_CURRENT_BINARY_DIR}/generated.txt")',
                'add_custom_target(core_python_generator '
                'DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/generated.txt")',
            ))
            write(checkout/'generate_fixture.py',
                  'from pathlib import Path\nimport sys\n'
                  'Path(sys.argv[1]).write_text(sys.executable+"\\n")\n')
        write(checkout / 'CMakeLists.txt', '\n'.join(lines) + '\n')
        tracked = ['CMakeLists.txt', *(['generate_fixture.py'] if with_generator else [])]
        subprocess.run(('git', '-C', str(checkout), 'add', *tracked), check=True)
        subprocess.run(('git', '-C', str(checkout), 'commit', '-qm',
                        'complete summary fixture'), check=True)
        pin = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
        write(self.case / 'config/upstream.env',
              'AIRDCPP_CORE_URL=https://example.invalid/core.git\n'
              f'AIRDCPP_CORE_COMMIT={pin}\n')
        result = self.invoke(REAL_CONFIGURE='1', **({'REAL_GENERATOR':'1'} if with_generator else {}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = (self.output / 'airdcpp-configure-summary.txt').read_text()
        self.assertIn('parent.resource_directory=share/airdcpp\n', summary)
        self.assertIn('parent.global_config_directory=Library/Application Support/AirDC++\n', summary)
        self.assertIn('sdk=' + self.tools.sdkroot + '\n', summary)
        self.assertIn('upstream_source=' + str(checkout) + '\n', summary)
        self.assertIn('target.include_directories='
                      + str(self.case / 'Build/prefix/bzip2/include') + ';'
                      + str(self.case / 'Build/prefix/bzip2/include/headers with spaces')
                      + '\n', summary)
        self.assertEqual((self.output / 'build-exit-code.txt').read_text(), '0\n')

    def test_rejects_stale_fingerprint(self):
        write(self.case/'Build/dependencies/bzip2/evidence/input-fingerprint.txt', '0'*64+'\n')
        self.failed('input fingerprint mismatch')
        self.assertFalse(self.calls.exists())

    def test_revalidates_prefix_and_evidence(self):
        write(self.case/'Build/prefix/bzip2/include/bzlib.h', 'changed\n')
        self.failed('accepted evidence mismatch')
        self.assertFalse(self.calls.exists())

    def test_last_component_evidence_is_required_before_configure(self):
        write(self.case/'Build/dependencies/boost/evidence/exit-status.txt', '1\n')
        self.failed('accepted evidence mismatch')
        self.assertFalse(self.calls.exists())

    def test_failure_records_status_and_enforces_whole_project_scope(self):
        self.failed('Core build failed', BUILD_FAIL='1')
        self.assertEqual((self.output/'build-exit-code.txt').read_text(), '29\n')
        self.failed('scope changed outside reproducible-release', BUILD_FAIL='1',
                    MUTATE=str(self.case/'Build/prefix/bzip2/include/bzlib.h'))

    def test_success_also_enforces_scope(self):
        self.failed('scope changed outside reproducible-release',
                    MUTATE=str(self.case/'Build/airdcpp-core/core-release/historical.txt'))

    def test_rejects_symlink_output_ancestor(self):
        destination = self.work / 'outside'
        destination.mkdir(exist_ok=True)
        (self.case/'Build/airdcpp-core').rename(self.case/'Build/held-core')
        (self.case/'Build/airdcpp-core').symlink_to(destination, target_is_directory=True)
        self.failed('unsafe directory')
        self.assertEqual(list(destination.iterdir()), [])

    def test_pinned_checkout_rejects_symlinked_known_generated_file(self):
        checkout = self.case/'Source/airdcpp-core'
        write(checkout/'.git/info/exclude', '/airdcpp/core/version.inc\n')
        outside = self.work/'held-version.inc'
        write(outside, 'external\n')
        generated = checkout/'airdcpp/core/version.inc'
        generated.parent.mkdir(parents=True)
        generated.symlink_to(outside)
        self.failed('unsafe regular file')
        self.assertFalse(self.calls.exists())

class CMakeResolutionTests(unittest.TestCase):
    def configure(self, change=''):
        temp = tempfile.TemporaryDirectory(prefix='airdc-resolution-', dir='/private/tmp')
        self.addCleanup(temp.cleanup)
        work = Path(temp.name)
        for name in ORDER:
            write(work/name/'lib/libfixture.a', 'fixture')
            (work/name/'include').mkdir()
        write(work/'sdk/usr/lib/libiconv.tbd', 'fixture')
        write(work/'source/CMakeLists.txt', f'''cmake_minimum_required(VERSION 3.25)
project(Resolution NONE)
include("{ROOT}/cmake/modules/AirDCCorePolicy.cmake")
include("{ROOT}/cmake/modules/AirDCCoreLinkAdapters.cmake")
set(CMAKE_OSX_SYSROOT "{work}/sdk")
'''+'\n'.join(f'set(AIRDCCORE_{name.upper()}_PREFIX "{work}/{name}")' for name in ORDER)+f'''
add_library(leveldb::leveldb STATIC IMPORTED)
set_target_properties(leveldb::leveldb PROPERTIES IMPORTED_LOCATION_RELEASE "{work}/leveldb/lib/libfixture.a" IMPORTED_CONFIGURATIONS RELEASE INTERFACE_INCLUDE_DIRECTORIES "{work}/leveldb/include" INTERFACE_LINK_LIBRARIES "snappy;$<LINK_ONLY:Threads::Threads>")
add_library(Snappy::snappy STATIC IMPORTED)
set_target_properties(Snappy::snappy PROPERTIES IMPORTED_LOCATION "{work}/snappy/lib/libfixture.a" INTERFACE_INCLUDE_DIRECTORIES "{work}/snappy/include")
add_library(Threads::Threads INTERFACE IMPORTED)
{change.replace('@WORK@',str(work))}
airdcpp_adapt_reproducible_leveldb()
airdcpp_record_dependency_resolution("{work}/build/dependency-resolution.tsv" leveldb::leveldb)
''')
        return run('cmake', '-S', str(work/'source'), '-B', str(work/'build')), work

    def test_repairs_one_plain_snappy_after_provenance_and_records_recursion(self):
        result, work = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        report = (work/'build/dependency-resolution.tsv').read_text()
        self.assertIn('component:leveldb\t$PREFIX/leveldb/lib/libfixture.a', report)
        self.assertIn('Snappy::snappy\tIMPORTED_LOCATION\tcomponent:snappy', report)
        self.assertIn('generator-target\t$<LINK_ONLY:Threads::Threads>', report)

    def test_real_wrapper_reproducible_mode_accepts_pinned_style_interface(self):
        result, work = self.configure()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        upstream = work/'source/CMakeLists.txt'
        text = upstream.read_text()
        sdk = run('/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path').stdout.strip()
        text = text.replace('project(Resolution NONE)', 'project(Resolution LANGUAGES C CXX)')
        text = text.replace(f'set(CMAKE_OSX_SYSROOT "{work}/sdk")', f'set(CMAKE_OSX_SYSROOT "{sdk}")')
        text = text[:text.index('airdcpp_adapt_reproducible_leveldb()')]
        for target, name in (('BZip2::BZip2','bzip2'),('ZLIB::ZLIB','zlib'),
                             ('OpenSSL::SSL','openssl'),('OpenSSL::Crypto','openssl'),
                             ('miniupnpc::miniupnpc','miniupnpc'),('maxminddb::maxminddb','libmaxminddb'),
                             ('Boost::thread','boost'),('Boost::regex','boost')):
            text += f'add_library({target} STATIC IMPORTED GLOBAL)\nset_target_properties({target} PROPERTIES IMPORTED_LOCATION "{work}/{name}/lib/libfixture.a" INTERFACE_INCLUDE_DIRECTORIES "{work}/{name}/include")\n'
        text += f'add_library(Iconv::Iconv INTERFACE IMPORTED GLOBAL)\nset_target_properties(Iconv::Iconv PROPERTIES INTERFACE_LINK_LIBRARIES "{Path(sdk)/"usr/lib/libiconv.tbd"}")\n'
        text += 'file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/tiny.cpp" "int fixture_core() { return 1; }\\n")\nadd_library(airdcpp STATIC "${CMAKE_CURRENT_BINARY_DIR}/tiny.cpp")\ntarget_link_libraries(airdcpp PRIVATE leveldb::leveldb)\n'
        # Imported targets discovered by upstream must be visible to the parent.
        text = text.replace(' STATIC IMPORTED)', ' STATIC IMPORTED GLOBAL)').replace(' INTERFACE IMPORTED)', ' INTERFACE IMPORTED GLOBAL)')
        write(upstream, text)
        args = ('cmake', '-S', str(ROOT), '-B', str(work/'wrapper'), '-G', 'Ninja',
                '-DCMAKE_TOOLCHAIN_FILE='+str(ROOT/'cmake/toolchains/macos-arm64.cmake'),
                '-DAIRDCPP_CORE_SOURCE_DIR='+str(work/'source'), '-DAIRDCCORE_REPRODUCIBLE_INPUTS=ON',
                '-DCMAKE_OSX_SYSROOT='+sdk)
        result = run(*args, *(f'-DAIRDCCORE_{n.upper()}_PREFIX={work}/{n}' for n in ORDER))
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        summary = (work/'wrapper/airdcpp-configure-summary.txt').read_text()
        self.assertIn('target.interface_libraries=Snappy::snappy;$<LINK_ONLY:Threads::Threads>', summary)
        self.assertIn('source.file_prefix_map=airdcpp-core', summary)
        report = (work/'wrapper/dependency-resolution.tsv').read_text()
        self.assertIn('apple-system\t$SDK/usr/lib/libiconv.2.tbd', report)

    def test_rejects_unsafe_resolution_and_invalid_snappy_contract(self):
        cases = (
            ('set_property(TARGET leveldb::leveldb PROPERTY IMPORTED_LOCATION_RELEASE /opt/homebrew/lib/libbad.a)', 'undeclared dependency path'),
            ('set_property(TARGET leveldb::leveldb PROPERTY INTERFACE_INCLUDE_DIRECTORIES /usr/local/Cellar/leveldb/include)', 'undeclared dependency path'),
            ('set_property(TARGET leveldb::leveldb PROPERTY IMPORTED_LOCATION_RELEASE "@WORK@/snappy/lib/libfixture.a")', 'LevelDB provenance'),
            ('set_property(TARGET leveldb::leveldb PROPERTY INTERFACE_LINK_LIBRARIES "snappy;snappy")', 'exactly one plain snappy'),
            ('set_property(TARGET leveldb::leveldb PROPERTY INTERFACE_LINK_LIBRARIES "snappy;Snappy::snappy")', 'exactly one Snappy reference'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_INCLUDE_DIRECTORIES "Threads::Threads")', 'undeclared dependency path'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_LIBRARIES evil)', 'unreviewed plain linker item'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_LIBRARIES "$<IF:$<BOOL:1>,/opt/homebrew/lib/evil.a,Threads::Threads>")', 'unsafe generator expression'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_OPTIONS -L/opt/homebrew/lib)', 'unreviewed plain linker item'),
        )
        for code, message in cases:
            with self.subTest(message=message):
                result, work = self.configure(code)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout+result.stderr)

unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
