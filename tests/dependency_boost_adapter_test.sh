#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import json
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
# Only the expensive upstream bootstrap/install boundary is doubled. The fixture
# libraries, CMake package lookup, compiler, linker and consumer execution are real.
BOOTSTRAP = r'''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
b = Path.cwd()
assert b == Path(sys.argv[0]).resolve().parent, 'bootstrap cwd must be private build'
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
        for name, body in bodies.items():
            src = Path(cls.native.name)/(name+'.cc'); src.write_text(body)
            obj = src.with_suffix('.o')
            subprocess.run(['/usr/bin/clang++', '-std=c++17', '-arch', 'arm64',
                            '-mmacosx-version-min=14.0', '-I'+str(include.parent),
                            '-c', str(src), '-o', str(obj)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/ar', 'rcs', str(lib/('libboost_'+name+'.a')), str(obj)], check=True)
        config = lib/'cmake/Boost-1.90.0'; config.mkdir(parents=True)
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
        for name, body in (('bootstrap.sh', BOOTSTRAP), ('fixture-b2', B2)):
            path = self.source/name; path.write_text(body); path.chmod(0o755)
        shutil.copytree(self.fixture, self.source/'installed')
        self.manifest = self.source_manifest()
        self.runlog = self.root/'runtime.log'
        self.env = {**os.environ, 'CXX': '/usr/bin/clang++', 'SOURCE_DATE_EPOCH': '1764771748',
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

    def test_native_installed_targets_and_private_bootstrap(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        evidence = self.evidence(result)
        self.assertEqual([x['purpose'] for x in evidence if x['type']=='status'],
                         ['bootstrap', 'build', 'consumer-configure', 'consumer-build', 'consumer-run'])
        self.assertTrue(all(x['status']==0 for x in evidence if x['type']=='status'))
        self.assertEqual(list(self.caller.iterdir()), [])
        self.assertTrue((self.build/'project-config.jam').is_file())
        self.assertEqual(self.source_manifest(), self.manifest)
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
