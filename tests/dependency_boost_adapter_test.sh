#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import json
import hashlib
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
ADAPTER = ROOT / 'scripts/lib/dependencies/build_boost.sh'
sys.path.insert(0, str(ROOT/'scripts/lib'))
from dependency_lock import load_lock
from dependency_prefix import PrefixError, validate_prefix

# Exact pinned upstream hunk, independently retained as the adapter preimage.
GENERATOR_HUNK = r'''        "get_filename_component(_BOOST_CMAKEDIR \"${CMAKE_CURRENT_LIST_DIR}/../\" REALPATH)"
        : true ;

    if [ path.is-rooted $(cmakedir) ]
    {
        local cmakedir-native = [ path-native-fwd $(cmakedir) ] ;

        print.text

            ""
            "# If the computed and the original directories are symlink-equivalent, use original"
            "if(EXISTS \"$(cmakedir-native)\")"
            "  get_filename_component(_BOOST_CMAKEDIR_ORIGINAL \"$(cmakedir-native)\" REALPATH)"
            "  if(_BOOST_CMAKEDIR STREQUAL _BOOST_CMAKEDIR_ORIGINAL)"
            "    set(_BOOST_CMAKEDIR \"$(cmakedir-native)\")"
            "  endif()"
            "  unset(_BOOST_CMAKEDIR_ORIGINAL)"
            "endif()"
            ""
            : true ;
    }

    get-dir "_BOOST_INCLUDEDIR" : $(includedir) ;

    if $(library-type) = INTERFACE
    {
'''
GENERATOR = 'tools/boost_install/boost-install.jam'
PATCH_PATH = 'config/patches/boost-1.90.0-relocatable-cmake.patch'

# Literal inventory observed from the pinned upstream install, independent of
# the lock under test. The fixture retains the full build-only export closure.
ARCHIVE_COMPONENTS = ('atomic', 'chrono', 'container', 'date_time', 'exception', 'regex', 'thread')
METADATA = (
    'Boost-1.90.0/BoostConfig.cmake',
    'Boost-1.90.0/BoostConfigVersion.cmake',
    'BoostDetectToolset-1.90.0.cmake',
    'boost_atomic-1.90.0/boost_atomic-config-version.cmake',
    'boost_atomic-1.90.0/boost_atomic-config.cmake',
    'boost_atomic-1.90.0/libboost_atomic-variant-static.cmake',
    'boost_chrono-1.90.0/boost_chrono-config-version.cmake',
    'boost_chrono-1.90.0/boost_chrono-config.cmake',
    'boost_chrono-1.90.0/libboost_chrono-variant-static.cmake',
    'boost_container-1.90.0/boost_container-config-version.cmake',
    'boost_container-1.90.0/boost_container-config.cmake',
    'boost_container-1.90.0/libboost_container-variant-static.cmake',
    'boost_date_time-1.90.0/boost_date_time-config-version.cmake',
    'boost_date_time-1.90.0/boost_date_time-config.cmake',
    'boost_date_time-1.90.0/libboost_date_time-variant-static.cmake',
    'boost_exception-1.90.0/boost_exception-config-version.cmake',
    'boost_exception-1.90.0/boost_exception-config.cmake',
    'boost_headers-1.90.0/boost_headers-config-version.cmake',
    'boost_headers-1.90.0/boost_headers-config.cmake',
    'boost_regex-1.90.0/boost_regex-config-version.cmake',
    'boost_regex-1.90.0/boost_regex-config.cmake',
    'boost_regex-1.90.0/libboost_regex-variant-static.cmake',
    'boost_thread-1.90.0/boost_thread-config-version.cmake',
    'boost_thread-1.90.0/boost_thread-config.cmake',
    'boost_thread-1.90.0/libboost_thread-variant-static.cmake',
)
# Only the expensive upstream bootstrap/install boundary is doubled. The fixture
# libraries, CMake package lookup, compiler, linker and consumer execution are real.
BOOTSTRAP = r'''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
b = Path.cwd()
assert b == Path(sys.argv[0]).resolve().parent, 'bootstrap cwd must be private build'
generator = (b/'tools/boost_install/boost-install.jam').read_text()
assert 'CMAKE_CURRENT_LIST_DIR' in generator
assert 'symlink-equivalent' not in generator, 'relocation patch must precede bootstrap'
prefix = os.environ['FIXTURE_STAGE']
assert sys.argv[1:] == ['--prefix=' + prefix, '--with-libraries=regex,thread']
if os.environ.get('FIXTURE_FAIL') == 'bootstrap': sys.exit(29)
(b/'project-config.jam').write_text('fixture private configuration\n')
shutil.copyfile(b/'fixture-b2', b/'b2'); (b/'b2').chmod(0o755)
'''
B2 = r'''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
b = Path.cwd(); stage = Path(os.environ['FIXTURE_STAGE'])
assert b == Path(sys.argv[0]).resolve().parent, 'b2 cwd must be private build'
assert sys.argv[1:] == ['variant=release', 'link=static', 'runtime-link=shared',
    'threading=multi', 'address-model=64', 'architecture=arm', '--prefix='+str(stage),
    'cxxflags=-arch arm64 -mmacosx-version-min=14.0 -O3 -DNDEBUG',
    'linkflags=-arch arm64 -mmacosx-version-min=14.0', '--layout=system', '-j3', 'install']
failure = os.environ.get('FIXTURE_FAIL')
if failure == 'b2': sys.exit(29)
shutil.copytree(b/'installed', stage, dirs_exist_ok=True)
if failure == 'shared': (stage/'lib/libboost_regex.dylib').write_text('bad shared artifact')
if failure == 'compile': (stage/'include/boost/regex.hpp').write_text('#error fixture compiler failure\n')
if failure == 'config': (stage/'lib/cmake/Boost-1.90.0/BoostConfig.cmake').write_text('message(FATAL_ERROR "fixture config failure")\n')
if failure == 'outside':
    config = stage/'lib/cmake/Boost-1.90.0/BoostConfig.cmake'
    config.write_text(config.read_text().replace('${_prefix}/lib/libboost_${component}.a',
                                               str(b/'installed/lib')+'/libboost_${component}.a'))
if failure == 'transitive':
    config = stage/'lib/cmake/Boost-1.90.0/BoostConfig.cmake'
    config.write_text(config.read_text().replace('Boost::atomic;Threads::Threads', 'Threads::Threads'))
'''
CONFIG = r'''
if(NOT Boost_FIND_COMPONENTS STREQUAL "regex;thread" OR NOT Boost_FIND_VERSION STREQUAL "1.90.0")
  message(FATAL_ERROR "fixture requires versioned regex/thread component lookup")
endif()
get_filename_component(_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
find_package(Threads REQUIRED)
foreach(component regex thread atomic)
  add_library(Boost::${component} STATIC IMPORTED)
  set_target_properties(Boost::${component} PROPERTIES
    IMPORTED_LOCATION "${_prefix}/lib/libboost_${component}.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_prefix}/include")
endforeach()
set_target_properties(Boost::thread PROPERTIES INTERFACE_LINK_LIBRARIES "Boost::atomic;Threads::Threads")
set(Boost_VERSION 1.90.0)
set(Boost_FOUND TRUE)
'''

class BoostAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native = tempfile.TemporaryDirectory(prefix='airdc-boost-native-')
        cls.fixture = Path(cls.native.name)/'installed'
        include = cls.fixture/'include/boost'; include.mkdir(parents=True)
        lib = cls.fixture/'lib'; lib.mkdir()
        (include/'regex.hpp').write_text('''#pragma once
#include <regex>
namespace boost { using regex = std::regex; bool regex_match(const char*, const regex&); }
''')
        (include/'thread.hpp').write_text('''#pragma once
#include <thread>
#include <utility>
namespace boost { class thread { std::thread value; public:
template<class F> explicit thread(F&& f): value(std::forward<F>(f)) {}
void join(); }; }
''')
        bodies = {
            'regex': '''#include <boost/regex.hpp>
#include <cstdlib>
#include <fstream>
bool boost::regex_match(const char* s, const regex& r) {
std::ofstream(std::getenv("FIXTURE_RUN_LOG"), std::ios::app) << "regex\\n";
return std::getenv("FIXTURE_RUNTIME_FAIL") ? false : std::regex_match(s,r); }
''',
            'atomic': 'extern "C" int fixture_atomic() { return 1; }\n',
            'thread': '''#include <boost/thread.hpp>
#include <cstdlib>
#include <fstream>
extern "C" int fixture_atomic();
void boost::thread::join() { if (fixture_atomic() != 1) std::abort(); value.join();
std::ofstream(std::getenv("FIXTURE_RUN_LOG"), std::ios::app) << "joined\\n"; }
'''}
        for name in ARCHIVE_COMPONENTS:
            body = bodies.get(name, 'int fixture_'+name+'() { return 1; }\n')
            src = Path(cls.native.name)/(name+'.cc'); src.write_text(body)
            obj = src.with_suffix('.o')
            subprocess.run(['/usr/bin/clang++', '-std=c++17', '-arch', 'arm64',
                            '-mmacosx-version-min=14.0', '-I'+str(include.parent),
                            '-c', str(src), '-o', str(obj)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/ar', 'rcs', str(lib/('libboost_'+name+'.a')), str(obj)], check=True)
        for name in METADATA:
            path = lib/'cmake'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# fixture installed export\n')
        config = lib/'cmake/Boost-1.90.0'
        (config/'BoostConfig.cmake').write_text(CONFIG)
        (config/'BoostConfigVersion.cmake').write_text('''set(PACKAGE_VERSION "1.90.0")
if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)
set(PACKAGE_VERSION_EXACT TRUE)
set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
''')

    @classmethod
    def tearDownClass(cls):
        cls.native.cleanup()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='airdc-boost-adapter-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.source = self.root/'source with space'; self.build = self.root/'build with space'
        self.stage = self.root/'stage with space'; self.caller = self.root/'caller'
        for p in (self.source, self.build, self.stage, self.caller): p.mkdir()
        (self.source/'LICENSE_1_0.txt').write_text('fixture license\n')
        generator = self.source/GENERATOR
        generator.parent.mkdir(parents=True)
        generator.write_text('# fixture padding\n' * 796 + GENERATOR_HUNK)
        for name, body in (('bootstrap.sh', BOOTSTRAP), ('fixture-b2', B2)):
            path = self.source/name; path.write_text(body); path.chmod(0o755)
        shutil.copytree(self.fixture, self.source/'installed')
        self.manifest = self.source_manifest()
        self.runlog = self.root/'runtime.log'
        self.env = {**os.environ, 'CXX': '/usr/bin/clang++', 'SOURCE_DATE_EPOCH': '1764771748',
                    'PATCH': '/usr/bin/patch',
                    'FIXTURE_STAGE': str(self.stage), 'FIXTURE_RUN_LOG': str(self.runlog)}

    def source_manifest(self):
        return sorted((p.relative_to(self.source).as_posix(), p.read_bytes())
                      for p in self.source.rglob('*') if p.is_file())

    def invoke(self, *, failure=None, adapter=ADAPTER):
        for path in (self.build, self.stage):
            shutil.rmtree(path)
            path.mkdir()
        env = dict(self.env)
        if failure == 'runtime': env['FIXTURE_RUNTIME_FAIL'] = '1'
        elif failure: env['FIXTURE_FAIL'] = failure
        return subprocess.run([str(adapter), str(self.source), str(self.build), str(self.stage),
                               '3', '1764771748'], cwd=self.caller, env=env, text=True, capture_output=True)

    def evidence(self, result):
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]

    def validate_installed(self):
        record = next(r for r in load_lock(ROOT/'config/dependencies.lock').dependencies if r.name=='boost')
        return validate_prefix(record, self.stage, {'project': ROOT, 'source': self.source,
                                                    'build': self.build, 'home': self.root/'home',
                                                    'fixture': Path(self.native.name)})

    def test_full_build_only_inventory_passes_strict_prefix_validation(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        try:
            report = self.validate_installed()
        except PrefixError as error:
            self.fail('installed build-only inventory rejected: '+str(error))
        self.assertEqual(report.role, 'build-only')
        self.assertEqual(tuple(a.path for a in report.archives),
                         tuple('lib/libboost_'+name+'.a' for name in ARCHIVE_COMPONENTS))
        self.assertTrue(all(a.architectures==('arm64',) for a in report.archives))
        self.assertTrue(all('minos 14.0' in a.build_versions for a in report.archives))

    def test_undeclared_archives_and_metadata_remain_rejected(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        try:
            self.validate_installed()
        except PrefixError as error:
            self.fail('installed build-only inventory rejected: '+str(error))
        for relative in ('lib/libboost_unexpected.a', 'lib/cmake/unexpected-config.cmake'):
            with self.subTest(output=relative):
                path = self.stage/relative
                if path.suffix=='.a': shutil.copyfile(self.stage/'lib/libboost_regex.a', path)
                else: path.write_text('# undeclared export\n')
                with self.assertRaisesRegex(PrefixError, 'foreign library file'):
                    self.validate_installed()
                path.unlink()

    def test_native_installed_targets_and_private_bootstrap(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        evidence = self.evidence(result)
        self.assertEqual([x['purpose'] for x in evidence if x['type']=='status'],
                         ['patch', 'bootstrap', 'build', 'consumer-configure', 'consumer-build', 'consumer-run'])
        self.assertTrue(all(x['status']==0 for x in evidence if x['type']=='status'))
        self.assertEqual(list(self.caller.iterdir()), [])
        self.assertTrue((self.build/'project-config.jam').is_file())
        self.assertEqual(self.source_manifest(), self.manifest)
        self.assertIn('symlink-equivalent', (self.source/GENERATOR).read_text())
        self.assertNotIn('symlink-equivalent', (self.build/GENERATOR).read_text())
        patch_command = next(x for x in evidence if x.get('purpose') == 'patch' and x['type'] == 'command')
        self.assertEqual(patch_command['argv'], ['/usr/bin/patch', '--batch', '--forward', '--fuzz=0',
                         '--no-backup-if-mismatch', str(self.build/GENERATOR), str(self.build/'.boost-relocation.patch')])
        identity = next(x for x in evidence if x['type'] == 'patch-input')
        snapshot = self.build/'.boost-relocation.patch'
        self.assertEqual(identity['sha256'], hashlib.sha256(snapshot.read_bytes()).hexdigest())
        self.assertEqual(snapshot.read_bytes(), (ROOT/PATCH_PATH).read_bytes())
        self.assertEqual(self.runlog.read_text(), 'regex\nregex\njoined\n')
        self.assertEqual((self.stage/'LICENSE_1_0.txt').read_text(), 'fixture license\n')
        consumer = self.build/'consumer-build'
        cache = (consumer/'CMakeCache.txt').read_text()
        values = {line.split(':',1)[0]: line.split('=',1)[1]
                  for line in cache.splitlines() if ':' in line and '=' in line and not line.startswith('//')}
        self.assertEqual(values['Boost_DIR'], str(self.stage/'lib/cmake/Boost-1.90.0'))
        self.assertEqual(values['CMAKE_PREFIX_PATH'], str(self.stage))
        for option in ('CMAKE_FIND_USE_PACKAGE_REGISTRY', 'CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY'):
            self.assertEqual(values[option], 'OFF')
        link = (consumer/'CMakeFiles/boost-consumer.dir/link.txt').read_text()
        for name in ('regex', 'thread', 'atomic'):
            self.assertIn(str(self.stage/('lib/libboost_'+name+'.a')), link)
        self.assertNotIn(str(self.source), link)
        arch = subprocess.run(['/usr/bin/lipo', '-archs', str(consumer/'boost-consumer')], text=True, capture_output=True)
        self.assertEqual(arch.stdout.strip(), 'arm64')

    def test_failures_stop_and_report_actual_command_status(self):
        for failure, purpose in (('bootstrap','bootstrap'), ('b2','build'), ('shared','build'),
                                 ('config','consumer-configure'), ('outside','consumer-configure'), ('compile','consumer-build'),
                                 ('transitive','consumer-build'), ('runtime','consumer-run')):
            with self.subTest(failure=failure):
                result = self.invoke(failure=failure)
                self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                statuses = [x for x in self.evidence(result) if x['type']=='status']
                self.assertEqual(statuses[-1]['purpose'], purpose)
                if failure in ('bootstrap','b2'):
                    self.assertEqual(result.returncode, 29)
                if failure != 'shared': self.assertEqual(statuses[-1]['status'], result.returncode)
                if failure != 'runtime': self.assertFalse(self.runlog.exists())
                self.assertEqual(list(self.caller.iterdir()), [])

    def test_context_mismatch_and_offset_refuse_before_bootstrap_without_source_writes(self):
        original = (self.source/GENERATOR).read_text()
        for content in (original.replace('path.is-rooted', 'path.changed'), '# offset\n' + original):
            with self.subTest(content=content[:30]):
                (self.source/GENERATOR).write_text(content)
                before = self.source_manifest()
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('Boost patch preimage mismatch', result.stdout+result.stderr)
                self.assertFalse((self.build/'project-config.jam').exists())
                self.assertEqual(self.source_manifest(), before)

    def private_adapter_project(self):
        project = self.root/'adapter-project'
        for relative in ('scripts/lib/dependencies/build_boost.sh', 'scripts/lib/dependencies/command_runner.py',
                         'scripts/lib/dependency_lock.py', 'config/dependencies.lock', PATCH_PATH):
            destination = project/relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/relative, destination)
        adapter = project/'scripts/lib/dependencies/build_boost.sh'; adapter.chmod(0o755)
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        subprocess.run(['git', '-C', str(project), 'add', PATCH_PATH], check=True)
        return project, adapter

    def test_missing_modified_or_unbound_patch_refuses_before_bootstrap(self):
        project, adapter = self.private_adapter_project()
        patch_file = project/PATCH_PATH; original = patch_file.read_bytes()
        lock_file = project/'config/dependencies.lock'; original_lock = lock_file.read_bytes()
        for mutation in ('missing', 'modified', 'unbound'):
            with self.subTest(mutation=mutation):
                patch_file.write_bytes(original); lock_file.write_bytes(original_lock)
                if mutation == 'missing': patch_file.unlink()
                elif mutation == 'modified': patch_file.write_bytes(original + b'# changed\n')
                else:
                    value = json.loads(original_lock)
                    next(r for r in value['dependencies'] if r['name']=='boost')['patches'] = []
                    lock_file.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
                result = self.invoke(adapter=adapter)
                self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertFalse((self.build/'project-config.jam').exists())
                self.assertEqual(self.source_manifest(), self.manifest)

    def test_patch_bytes_changed_after_lock_validation_are_rejected(self):
        project, adapter = self.private_adapter_project()
        body = adapter.read_text()
        marker = "patch_path = 'config/patches/boost-1.90.0-relocatable-cmake.patch'"
        self.assertIn(marker, body)
        adapter.write_text(body.replace(marker, marker + "\n(project/patch_path).write_bytes(b'changed after lock validation\\n')"))
        result = self.invoke(adapter=adapter)
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('Boost patch sha256 mismatch', result.stdout+result.stderr)
        self.assertFalse((self.build/'project-config.jam').exists())
        self.assertEqual(self.source_manifest(), self.manifest)

    def test_patch_tool_consumes_snapshot_when_repository_artifact_changes(self):
        project, adapter = self.private_adapter_project()
        original = (project/PATCH_PATH).read_bytes()
        runner = project/'scripts/lib/dependencies/command_runner.py'
        body = runner.read_text()
        marker = 'completed = subprocess.run(argv)'
        self.assertIn(marker, body)
        runner.write_text(body.replace(marker,
            "if purpose == 'patch':\n    from pathlib import Path\n    Path(" + repr(str(project/PATCH_PATH)) + ").write_bytes(b'changed before external patch\\n')\n" + marker))
        result = self.invoke(adapter=adapter)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertNotEqual((project/PATCH_PATH).read_bytes(), original)
        self.assertEqual((self.build/'.boost-relocation.patch').read_bytes(), original)
        self.assertEqual(self.source_manifest(), self.manifest)

    def test_symlink_target_and_existing_snapshot_refuse_before_bootstrap(self):
        generator = self.source/GENERATOR
        saved = self.source/'original-generator.jam'
        generator.rename(saved)
        generator.symlink_to(saved)
        before = self.source_manifest()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('unsafe private Boost patch target', result.stdout+result.stderr)
        self.assertFalse((self.build/'project-config.jam').exists())
        self.assertEqual(self.source_manifest(), before)
        generator.unlink(); saved.rename(generator)
        (self.source/'.boost-relocation.patch').write_bytes(b'preexisting snapshot\n')
        before = self.source_manifest()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('FileExistsError', result.stdout+result.stderr)
        self.assertFalse((self.build/'project-config.jam').exists())
        self.assertEqual(self.source_manifest(), before)

    def test_consumer_semantic_mutations_fail(self):
        body = ADAPTER.read_text()
        for old, new in (('boost::regex_match("AirDCCore", boost::regex("Air.*"))', 'true'),
                         ('t.join();', '(void)t;'), ('++completed;', '(void)completed;')):
            with self.subTest(mutation=old):
                self.assertIn(old, body)
                adapter = self.root/'mutated.sh'
                mutated = body.replace(old, new)
                runner = ADAPTER.parent/'command_runner.py'
                mutated = mutated.replace('runner=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/command_runner.py',
                                          'runner='+shlex.quote(str(runner)))
                adapter.write_text(mutated); adapter.chmod(0o755)
                result = self.invoke(adapter=adapter)
                if new == 'true':
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                    self.assertNotEqual(self.runlog.read_text(), 'regex\nregex\njoined\n')
                else: self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                if self.runlog.exists(): self.runlog.unlink()

unittest.main(argv=[sys.argv[0]])
PY
