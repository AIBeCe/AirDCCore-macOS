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
        # The current lock reader requires its sole dependency patch tracked in
        # the consuming project. Model that real boundary in the copied fixture.
        subprocess.run(('git','init','-q',str(cls.template)),check=True)
        for key,value in (('user.name','Tests'),('user.email','tests@example.invalid'),('commit.gpgsign','false')):
            subprocess.run(('git','-C',str(cls.template),'config',key,value),check=True)
        subprocess.run(('git','-C',str(cls.template),'add','config'),check=True)
        subprocess.run(('git','-C',str(cls.template),'commit','-qm','tracked lock fixtures'),check=True)
        checkout = cls.template / 'Source/airdcpp-core'
        checkout.mkdir(parents=True)
        subprocess.run(('git', 'init', '-q', str(checkout)), check=True)
        write(checkout / 'state.txt', 'pinned\n')
        for relative in ('CMakeLists.txt','airdcpp/hash/HashStore.cpp','scripts/generate_version.py',
                         'scripts/generate_stringdefs.py','airdcpp/core/localization/StringDefs.h'):
            target=checkout/relative
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(ROOT/'Source/airdcpp-core'/relative,target)
        for name, value in (('user.name', 'Tests'), ('user.email', 'tests@example.invalid'),
                            ('commit.gpgsign', 'false')):
            subprocess.run(('git', '-C', str(checkout), 'config', name, value), check=True)
        subprocess.run(('git', '-C', str(checkout), 'add', '.'), check=True)
        subprocess.run(('git', '-C', str(checkout), 'commit', '-qm', 'fixture'), check=True,
                       env={**os.environ,'GIT_AUTHOR_DATE':'1774518197 +0000','GIT_COMMITTER_DATE':'1774518197 +0000'})
        pin = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
        subprocess.run(('git', '-C', str(checkout), 'checkout', '-q', '--detach'), check=True)
        subprocess.run(('git', '-C', str(checkout), 'remote', 'add', 'origin', 'https://example.invalid/core.git'), check=True)
        write(cls.template / 'config/upstream.env',
              f'AIRDCPP_CORE_URL=https://example.invalid/core.git\nAIRDCPP_CORE_COMMIT={pin}\n')
        policy=json.loads((cls.template/'config/core-reproducible-policy.json').read_text())
        policy['upstream_commit']=pin
        write(cls.template/'config/core-reproducible-policy.json',json.dumps(policy))
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
    if control.get('FIFO_SCOPE'): os.mkfifo(control['FIFO_SCOPE'])
    if control.get('FIFO_EVIDENCE'): os.mkfifo(out/'scope-after.json')
    if control.get('BUILD_FAIL'): sys.exit(29)
    import subprocess, hashlib
    authority=out/'version-authority.json'
    version=json.loads(authority.read_text())
    staged=Path(version['staged_root'])
    subprocess.run([sys.executable,str(staged.parent.parent.parent.parent/'scripts/lib/core_stage.py'),
                    'version',str(authority),hashlib.sha256(authority.read_bytes()).hexdigest(),'--',
                    sys.executable,'scripts/generate_version.py','./airdcpp/core/version.inc','0.0.0',
                    'AirDCCore-macOS','org.airdcpp.core.macos.configure'],cwd=staged,check=True)
    subprocess.run([sys.executable,'scripts/generate_stringdefs.py','./airdcpp/core/localization/'],cwd=staged,check=True)
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
            'set_property(TARGET Threads::Threads PROPERTY INTERFACE_COMPILE_OPTIONS "-pthread")',
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
        upstream=(ROOT/'Source/airdcpp-core/CMakeLists.txt').read_text()
        version_block=upstream[upstream.index('if (NOT CMAKE_BUILD_TYPE STREQUAL Debug'):upstream.index('# Stringdefs')]
        version_block=version_block.replace('add_dependencies(${PROJECT_NAME} version)','add_dependencies(airdcpp version)')
        fixture_cmake='\n'.join(lines)+'\n'+version_block
        write(checkout / 'CMakeLists.txt', fixture_cmake)
        tracked = ['CMakeLists.txt', *(['generate_fixture.py'] if with_generator else [])]
        subprocess.run(('git', '-C', str(checkout), 'add', *tracked), check=True)
        subprocess.run(('git', '-C', str(checkout), 'commit', '-qm',
                        'complete summary fixture'), check=True,
                       env={**os.environ,'GIT_AUTHOR_DATE':'1774518197 +0000','GIT_COMMITTER_DATE':'1774518197 +0000'})
        pin = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
        write(self.case / 'config/upstream.env',
              'AIRDCPP_CORE_URL=https://example.invalid/core.git\n'
              f'AIRDCPP_CORE_COMMIT={pin}\n')
        policy=json.loads((self.case/'config/core-reproducible-policy.json').read_text())
        policy['upstream_commit']=pin
        patched_cmake=fixture_cmake.replace('  find_package (Git)\n',
            '  if (NOT AIRDCCORE_VERSION_COMMAND)\n'
            '    message(FATAL_ERROR "Private Core version command authority is required")\n  endif()\n'
            '  find_package (Git)\n')
        patched_cmake=patched_cmake.replace(
            'COMMAND ${PYTHON_EXECUTABLE} scripts/generate_version.py ./airdcpp/core/version.inc ${VERSION} ${TAG_APPLICATION} ${APPLICATION_ID}',
            'COMMAND ${AIRDCCORE_VERSION_COMMAND}')
        policy['patch']['targets'][1]['preimage_sha256']=hashlib.sha256(fixture_cmake.encode()).hexdigest()
        policy['patch']['targets'][1]['postimage_sha256']=hashlib.sha256(patched_cmake.encode()).hexdigest()
        write(self.case/'config/core-reproducible-policy.json',json.dumps(policy))
        result = self.invoke(REAL_CONFIGURE='1', **({'REAL_GENERATOR':'1'} if with_generator else {}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = (self.output / 'airdcpp-configure-summary.txt').read_text()
        self.assertIn('parent.resource_directory=share/airdcpp\n', summary)
        self.assertIn('parent.global_config_directory=Library/Application Support/AirDC++\n', summary)
        self.assertIn('sdk=' + self.tools.sdkroot + '\n', summary)
        self.assertIn('upstream_source=' + str(checkout) + '\n', summary)
        self.assertIn('effective_upstream_source='+str(self.output/'source')+'\n',summary)
        self.assertIn('target.include_directories='
                      + str(self.case / 'Build/prefix/bzip2/include') + ';'
                      + str(self.case / 'Build/prefix/bzip2/include/headers with spaces')
                      + '\n', summary)
        self.assertEqual((self.output / 'build-exit-code.txt').read_text(), '0\n')
        self.assertIn('Threads::Threads\tINTERFACE_COMPILE_OPTIONS\treviewed-compile-option\t-pthread',
                      (self.output/'dependency-resolution.tsv').read_text())

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
        result=self.failed('scope changed outside reproducible-release', BUILD_FAIL='1',
                           MUTATE=str(self.case/'Build/prefix/bzip2/include/bzlib.h'))
        self.assertIn('Core build failed',result.stderr)
        for name in ('scope-before.json','scope-after.json'):
            self.assertTrue((self.output/name).is_file())

    def test_primary_build_error_survives_scope_collection_and_reporting_failure(self):
        fifo=self.case/'unsupported-scope-entry'
        result=self.failed('Core build failed',BUILD_FAIL='1',FIFO_SCOPE=str(fifo))
        self.assertIn('scope verification failed',result.stderr)
        self.assertIn('unsupported scope entry',result.stderr)
        self.assertEqual((self.output/'build-exit-code.txt').read_text(),'29\n')
        fifo.unlink()
        result=self.failed('Core build failed',BUILD_FAIL='1',FIFO_EVIDENCE='1')
        self.assertIn('scope evidence reporting failed',result.stderr)
        self.assertIn('unsafe regular file',result.stderr)
        self.assertEqual((self.output/'build-exit-code.txt').read_text(),'29\n')
        (self.output/'scope-after.json').unlink()

    def test_preservation_failure_still_runs_guarded_scope_reporting(self):
        write(self.output/'build.log','previous failure\n')
        os.mkfifo(self.output/'unsupported-prior-entry')
        self.failed('unsafe prior Core output')
        self.assertTrue((self.output/'scope-after.json').is_file())
        self.assertEqual((self.output/'scope-status.txt').read_text(),'0\n')
        self.assertEqual((self.output/'build.log').read_text(),'previous failure\n')
        (self.output/'unsupported-prior-entry').unlink()

    def test_preserves_previous_attempt_and_generated_source_forensics(self):
        write(self.output/'build.log','previous failed native log\n')
        write(self.output/'build-exit-code.txt','1\n')
        checkout=self.case/'Source/airdcpp-core'
        write(checkout/'.git/info/exclude','/airdcpp/core/version.inc\n')
        write(checkout/'airdcpp/core/version.inc','original forensic version\n')
        before=(checkout/'airdcpp/core/version.inc').stat()
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        attempt=self.output/'attempts/0001'
        self.assertTrue((attempt/'build.log').is_file(),'previous failed output was not preserved')
        self.assertEqual((attempt/'build.log').read_text(),'previous failed native log\n')
        self.assertEqual((attempt/'source-generated-forensics/airdcpp/core/version.inc').read_text(),
                         'original forensic version\n')
        self.assertEqual((checkout/'airdcpp/core/version.inc').read_text(),'original forensic version\n')
        self.assertEqual(before.st_mtime_ns,(checkout/'airdcpp/core/version.inc').stat().st_mtime_ns)

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
        generated.parent.mkdir(parents=True,exist_ok=True)
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

    def test_records_reviewed_compile_options_link_directories_and_sources(self):
        result, work = self.configure('''
file(WRITE "@WORK@/snappy/include/fixture.cpp" "int fixture() { return 1; }")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS "-Werror;-Wthread-safety;-pthread")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS_RELEASE "-pthread")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_DIRECTORIES "@WORK@/snappy/lib")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_DIRECTORIES_RELEASE "@WORK@/snappy/lib")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_SOURCES "@WORK@/snappy/include/fixture.cpp")
set_property(TARGET Snappy::snappy PROPERTY INTERFACE_SOURCES_RELEASE "@WORK@/snappy/include/fixture.cpp")
''')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        report = (work/'build/dependency-resolution.tsv').read_text()
        for option in ('-Werror', '-Wthread-safety', '-pthread'):
            self.assertIn('Snappy::snappy\tINTERFACE_COMPILE_OPTIONS\treviewed-compile-option\t'+option, report)
        self.assertIn('Snappy::snappy\tINTERFACE_COMPILE_OPTIONS_RELEASE\treviewed-compile-option\t-pthread', report)
        for suffix in ('', '_RELEASE'):
            self.assertIn('Snappy::snappy\tINTERFACE_LINK_DIRECTORIES'+suffix+'\tcomponent:snappy\t$PREFIX/snappy/lib', report)
            self.assertIn('Snappy::snappy\tINTERFACE_SOURCES'+suffix+'\tcomponent:snappy\t$PREFIX/snappy/include/fixture.cpp', report)

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
        self.assertNotEqual(result.returncode,0,'ON without stage must never fall back to Source')
        self.assertIn('private Core source is required',result.stdout+result.stderr)
        result = run(*args,'-DAIRDCCORE_STAGED_SOURCE_DIR=',
                     *(f'-DAIRDCCORE_{n.upper()}_PREFIX={work}/{n}' for n in ORDER))
        self.assertNotEqual(result.returncode,0)
        self.assertIn('private Core source is required',result.stdout+result.stderr)
        stage=work/'wrapper/source'
        write(stage/'CMakeLists.txt',text)
        generator=(ROOT/'Source/airdcpp-core/scripts/generate_version.py').read_bytes()
        write(stage/'scripts/generate_version.py',generator.decode())
        import core_stage
        authority=core_stage.authority_document(json.loads((ROOT/'config/core-reproducible-policy.json').read_text()),
                    {'scripts/generate_version.py':generator},stage,sys.executable)
        authority_path=work/'wrapper/version-authority.json'
        write(authority_path,core_stage.canonical(authority).decode())
        result=run(*args,'-DAIRDCCORE_STAGED_SOURCE_DIR='+str(stage),
                   '-DAIRDCCORE_VERSION_AUTHORITY='+str(authority_path),
                   '-DAIRDCCORE_VERSION_AUTHORITY_SHA256='+core_stage.digest(core_stage.canonical(authority)),
                   '-DAIRDCCORE_VERSION_ADAPTER='+str(ROOT/'scripts/lib/core_stage.py'),
                   '-DPYTHON_EXECUTABLE='+sys.executable,
                   *(f'-DAIRDCCORE_{n.upper()}_PREFIX={work}/{n}' for n in ORDER))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
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
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS "-I/opt/homebrew/include")', 'unreviewed compile option'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS "-isystem;/opt/homebrew/include")', 'unreviewed compile option'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS_RELEASE "-fno-rtti")', 'unreviewed compile option'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_COMPILE_OPTIONS "$<$<BOOL:1>:-pthread>")', 'unsafe generator expression'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_DIRECTORIES /opt/homebrew/lib)', 'undeclared dependency path'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_DIRECTORIES_RELEASE /opt/homebrew/lib)', 'undeclared dependency path'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_LINK_DIRECTORIES "$<LINK_ONLY:Threads::Threads>")', 'undeclared dependency path'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_SOURCES /opt/homebrew/include/foreign.cpp)', 'undeclared dependency path'),
            ('set_property(TARGET Snappy::snappy PROPERTY INTERFACE_SOURCES_RELEASE /opt/homebrew/include/foreign.cpp)', 'undeclared dependency path'),
            ('file(WRITE "@WORK@/foreign.cpp" "int foreign() { return 1; }")\nfile(CREATE_LINK "@WORK@/foreign.cpp" "@WORK@/snappy/include/escape.cpp" SYMBOLIC)\nset_property(TARGET Snappy::snappy PROPERTY INTERFACE_SOURCES "@WORK@/snappy/include/escape.cpp")', 'undeclared dependency path'),
        )
        for code, message in cases:
            with self.subTest(message=message):
                result, work = self.configure(code)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout+result.stderr)

unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
