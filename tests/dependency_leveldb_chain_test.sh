#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
exec python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
records = {item['name']: item for item in json.loads((root / 'config/dependencies.lock').read_text())['dependencies']}
assert records['leveldb']['dependencies'] == ['snappy']
sys.path.insert(0, str(root / 'scripts/lib'))
from dependency_lock import load_lock, topological_records
order = [item.name for item in topological_records(load_lock(root / 'config/dependencies.lock'))]
assert order.index('snappy') < order.index('leveldb')

fake = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as stream:
    stream.write(json.dumps({'tool': Path(sys.argv[0]).name, 'argv': args}) + '\n')
assert not any(key in os.environ for key in ('CMAKE_PREFIX_PATH', 'PKG_CONFIG_PATH', 'CMAKE_LIBRARY_PATH', 'CXXFLAGS', 'LDFLAGS')), 'ambient poison survived'
poison = os.environ.get('FIXTURE_POISON', '')
if Path(sys.argv[0]).name == 'ninja':
    build = Path(args[args.index('-C') + 1]); state = json.loads((build / 'state.json').read_text())
    wrong = poison == 'link' and state['kind'] == 'leveldb' or poison == 'consumer-link' and state['kind'] == 'consumer'
    archive = '/opt/homebrew/lib/libsnappy.a' if wrong else state['snappy'] + '/lib/libsnappy.a'
    if poison == 'foreign-link': archive += ' /outside/ambient/libsnappy.a'
    print('/usr/bin/clang++ object.o ' + archive + (' ' + state['stage'] + '/lib/libleveldb.a' if state['kind'] == 'consumer' else '') + ' -o ' + args[-1])
    sys.exit(0)
def opt(name): return next((arg.split('=', 1)[1] for arg in args if arg.startswith('-D' + name + '=')), '')
if '--build' in args:
    build = Path(args[args.index('--build') + 1]); state = json.loads((build / 'state.json').read_text())
    if state['kind'] in ('consumer', 'snappy-consumer'):
        name = 'leveldb-consumer' if state['kind'] == 'consumer' else 'snappy-consumer'
        code = 'import json, os, sys\nfrom pathlib import Path\n'
        code += "with open(os.environ['FIXTURE_RUNS'], 'a') as f: f.write(json.dumps(sys.argv) + '\\n')\n"
        if name == 'leveldb-consumer':
            code += "db = Path(sys.argv[1]); assert db.is_absolute(); (db / 'key').write_text('fixture value'); assert (db / 'key').read_text() == 'fixture value'\n"
        code += 'sys.exit(9 if os.environ.get("FIXTURE_POISON") == "runtime" else 0)\n'
        executable = build / name; executable.write_text('#!' + sys.executable + '\n' + code); executable.chmod(0o755)
    sys.exit(0)
if '--install' in args:
    build = Path(args[args.index('--install') + 1]); state = json.loads((build / 'state.json').read_text()); stage = Path(state['stage'])
    outputs = ['include/snappy.h', 'lib/libsnappy.a', 'lib/cmake/Snappy/SnappyConfig.cmake'] if state['kind'] == 'snappy' else ['include/leveldb/db.h', 'lib/libleveldb.a', 'lib/cmake/leveldb/leveldbConfig.cmake', 'lib/cmake/leveldb/leveldbTargets.cmake']
    for relative in outputs:
        path = stage / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('installed fixture\n')
    if state['kind'] == 'leveldb':
        (stage / 'lib/cmake/leveldb/leveldbTargets.cmake').write_text('  INTERFACE_LINK_LIBRARIES "' + ('snappy;unlocked;Threads::Threads' if poison == 'interface' else 'snappy;Threads::Threads') + '"\n' + ('/opt/homebrew/lib/libsnappy.a\n' if poison == 'config' else ''))
    sys.exit(0)
source = Path(args[args.index('-S') + 1]); build = Path(args[args.index('-B') + 1]); build.mkdir(parents=True, exist_ok=True)
kind = 'snappy' if source.name == 'snappy-src' else 'leveldb' if source.name == 'leveldb-src' else 'snappy-consumer' if source.name == 'snappy-consumer-src' else 'consumer'
stage = opt('CMAKE_INSTALL_PREFIX'); prefix = opt('CMAKE_PREFIX_PATH'); snappy = prefix.split(';')[-1]
if kind in ('snappy', 'leveldb'):
    expected = []
    for arg in json.loads(os.environ['FIXTURE_RECORDS'])[kind]['configure_options']:
        for token, value in {'@STAGE@': stage, '@PREFIX:snappy@': snappy, '@BUILD@': str(build)}.items(): arg = arg.replace(token, value)
        expected.append(arg)
    actual = args[4:]
    assert actual[:len(expected)] == expected, (actual, expected)
    assert actual[len(expected):] == (['-DCMAKE_MAKE_PROGRAM=' + str(Path(sys.argv[0]).with_name('ninja'))] if kind == 'leveldb' else []), actual
    for third_party in ('googletest', 'benchmark'): assert not list((source / 'third_party' / third_party).iterdir())
    if kind == 'leveldb':
        assert prefix == os.environ['FIXTURE_SNAPPY']
        hook = Path(opt('CMAKE_PROJECT_INCLUDE')).read_text()
        assert 'add_library(snappy STATIC IMPORTED GLOBAL)' in hook and snappy + '/lib/libsnappy.a' in hook and snappy + '/include' in hook
        assert opt('CMAKE_REQUIRED_FLAGS') == '-L' + snappy + '/lib'
else:
    cmake = (source / 'CMakeLists.txt').read_text()
    assert 'find_package(Snappy CONFIG REQUIRED PATHS' in cmake and 'NO_DEFAULT_PATH' in cmake
    assert 'Snappy::snappy' in cmake and 'target_link_libraries(' in cmake
    for flag in ('CMAKE_FIND_USE_PACKAGE_REGISTRY', 'CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY', 'CMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH', 'CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH', 'CMAKE_FIND_USE_CMAKE_SYSTEM_PATH'): assert opt(flag) == 'OFF'
    assert opt('CMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY') == 'ON'
    assert opt('CMAKE_OSX_ARCHITECTURES') == 'arm64' and opt('CMAKE_OSX_DEPLOYMENT_TARGET') == '14.0'
    if kind == 'consumer':
        stage = prefix.split(';')[0]; code = (source / 'leveldb-consumer.cc').read_text()
        for required in ('leveldb::leveldb', 'find_package(leveldb CONFIG REQUIRED PATHS'): assert required in cmake
        for required in ('kSnappyCompression', 'db->Put', 'db->Get', 'db->CompactRange', 'options.create_if_missing = false', 'delete db', 'argv[1]'): assert required in code
        assert code.count('leveldb::DB::Open') == 2
        resolved = snappy + '/lib/libsnappy.a\n' + stage + '/lib/libleveldb.a\n'
    else:
        stage = prefix; code = (source / 'snappy-consumer.cc').read_text()
        assert 'snappy::Compress' in code and 'snappy::Uncompress' in code
        resolved = stage + '/lib/libsnappy.a\n'
    (build / 'resolved-targets.txt').write_text('/opt/homebrew/lib/libsnappy.a\n' if poison == 'target' else resolved)
(build / 'state.json').write_text(json.dumps({'kind': kind, 'stage': stage, 'snappy': snappy}))
(build / 'CMakeCache.txt').write_text('CMAKE_PREFIX_PATH:PATH=' + ('/opt/homebrew/opt/snappy' if poison == 'cache' else prefix) + '\nHAVE_SNAPPY:INTERNAL=' + ('0' if poison == 'probe' else '1') + '\n')
(build / 'compile_commands.json').write_text('/opt/homebrew/include' if poison == 'compile' else snappy + '/include')
(build / 'CMakeFiles').mkdir(exist_ok=True)
(build / 'CMakeFiles/CMakeConfigureLog.yaml').write_text('Run Build Command(s): /opt/homebrew/bin/ninja -v\n' + ('snappy_compress /opt/homebrew/lib/libsnappy.a\n' if poison == 'probe-link' else 'snappy_compress ' + snappy + '/lib/libsnappy.a\n'))
'''

with tempfile.TemporaryDirectory(prefix='leveldb-chain-') as directory:
    work = Path(directory).resolve(); fakebin = work / 'fakebin'; fakebin.mkdir()
    for name in ('cmake', 'ninja'):
        path = fakebin / name; path.write_text('#!' + sys.executable + '\n' + fake); path.chmod(0o755)
    for name in ('snappy', 'leveldb'):
        source = work / (name + '-src'); source.mkdir()
        (source / 'CMakeLists.txt').touch(); (source / ('COPYING' if name == 'snappy' else 'LICENSE')).touch()
        for third_party in ('googletest', 'benchmark'): (source / 'third_party' / third_party).mkdir(parents=True)
    env = dict(os.environ, PATH=str(fakebin) + ':' + str(Path(sys.executable).parent) + ':/usr/bin:/bin', CC='/usr/bin/clang', CXX='/usr/bin/clang++', SOURCE_DATE_EPOCH='1', CMAKE_PREFIX_PATH='/opt/homebrew/opt/snappy', PKG_CONFIG_PATH='/opt/homebrew/lib/pkgconfig', CMAKE_LIBRARY_PATH='/opt/homebrew/lib', CXXFLAGS='-I/opt/homebrew/include', LDFLAGS='-L/opt/homebrew/lib', FIXTURE_RECORDS=json.dumps(records), FIXTURE_LOG=str(work / 'calls.jsonl'), FIXTURE_RUNS=str(work / 'runs.jsonl'), FIXTURE_SNAPPY=str(work / 'snappy-stage'))
    def invoke(name, suffix='', poison='', prefixes=None):
        build = work / (name + '-build' + suffix); build.mkdir(exist_ok=True)
        stage = work / (name + '-stage' + suffix); stage.mkdir(exist_ok=True)
        args = ['sh', str(root / 'scripts/lib/dependencies' / ('build_' + name + '.sh')), str(work / (name + '-src')), str(build), str(stage), '1', '1']
        if name == 'leveldb': args += prefixes if prefixes is not None else [str(work / 'snappy-stage')]
        return subprocess.run(args, env=dict(env, FIXTURE_POISON=poison), cwd=work, capture_output=True, text=True), build
    for prefixes in ([], [str(work / 'snappy-stage')] * 2):
        result, _ = invoke('leveldb', prefixes=prefixes); assert result.returncode != 0 and 'expected SOURCE' in result.stderr
    result, _ = invoke('snappy'); assert result.returncode == 0, result.stdout + result.stderr
    result, build = invoke('leveldb'); assert result.returncode == 0, result.stdout + result.stderr
    configurations = [json.loads(line) for line in (work / 'calls.jsonl').read_text().splitlines() if json.loads(line)['argv'][:1] == ['-S']]
    assert Path(configurations[0]['argv'][1]).name == 'snappy-src' and Path(configurations[2]['argv'][1]).name == 'leveldb-src'
    runs = [json.loads(line) for line in (work / 'runs.jsonl').read_text().splitlines()]
    assert Path(runs[0][0]).name == 'snappy-consumer'
    db = Path(runs[1][1]); assert db.parent == build and not db.exists()
    poisons = ('cache', 'link', 'foreign-link', 'compile', 'config', 'interface', 'probe', 'probe-link', 'target', 'consumer-link', 'runtime')
    for poison in poisons:
        result, build = invoke('leveldb', '-' + poison, poison)
        assert result.returncode != 0, 'accepted injected ' + poison
        assert not list(build.glob('leveldb-consumer-db.*')), 'database leaked on ' + poison
    assert not (work / 'leveldb-consumer-db').exists()
    for name in ('snappy', 'leveldb'):
        for third_party in ('googletest', 'benchmark'): assert not list((work / (name + '-src') / 'third_party' / third_party).iterdir())
    # A real minimal CMake fixture exercises the pinned bare-library probe,
    # target export, and link semantics without claiming a live dependency build.
    cmake = shutil.which('cmake'); ninja = shutil.which('ninja')
    assert cmake and ninja, 'CMake and Ninja are required for the real probe fixture'
    probe = work / 'probe'; probe.mkdir()
    (probe / 'snappy.cc').write_text('#include <string>\nextern "C" int snappy_compress(void) { std::string value("fixture"); return value == "fixture" ? 0 : 1; }\n')
    subprocess.run(['/usr/bin/clang++', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-c', str(probe / 'snappy.cc'), '-o', str(probe / 'snappy.o')], check=True, capture_output=True)
    archive = work / 'snappy-stage/lib/libsnappy.a'; archive.unlink()
    subprocess.run(['/usr/bin/ar', 'rcs', str(archive), str(probe / 'snappy.o')], check=True, capture_output=True)
    (probe / 'leveldb.cc').write_text('extern "C" int snappy_compress(void); int leveldb(void) { return snappy_compress(); }\n')
    (probe / 'main.cc').write_text('extern int leveldb(void); int main(void) { return leveldb(); }\n')
    (probe / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.20)
project(leveldb-probe LANGUAGES C CXX)
include(CheckLibraryExists)
check_library_exists(snappy snappy_compress "" HAVE_SNAPPY)
if(NOT HAVE_SNAPPY)
  message(FATAL_ERROR "Locked Snappy probe failed")
endif()
add_library(leveldb STATIC leveldb.cc)
target_link_libraries(leveldb snappy)
find_package(Threads REQUIRED)
target_link_libraries(leveldb Threads::Threads)
add_executable(leveldbutil main.cc)
target_link_libraries(leveldbutil PRIVATE leveldb)
install(TARGETS leveldb EXPORT leveldbTargets ARCHIVE DESTINATION lib)
install(EXPORT leveldbTargets NAMESPACE leveldb:: DESTINATION lib/cmake/leveldb)
''')
    probe_build = work / 'probe-build'; probe_stage = work / 'probe-stage'
    command = [cmake, '-S', str(probe), '-B', str(probe_build), '-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + ninja, '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_PROJECT_INCLUDE=' + str(work / 'leveldb-build/locked-snappy.cmake'), '-DCMAKE_REQUIRED_FLAGS=-L' + str(archive.parent), '-DCMAKE_INSTALL_PREFIX=' + str(probe_stage)]
    # Exercise the adapter's actual check-time runtime inputs against the real
    # C++ archive, instead of letting the fake configure invent probe success.
    command += [arg for arg in configurations[2]['argv'] if arg.startswith('-DCMAKE_REQUIRED_LIBRARIES=')]
    clean_env = {key: value for key, value in os.environ.items() if key not in ('CMAKE_PREFIX_PATH', 'PKG_CONFIG_PATH', 'CMAKE_LIBRARY_PATH', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')}
    for argv in (command, [cmake, '--build', str(probe_build)], [cmake, '--install', str(probe_build)]):
        result = subprocess.run(argv, env=clean_env, capture_output=True, text=True); assert result.returncode == 0, result.stdout + result.stderr
    assert 'HAVE_SNAPPY:INTERNAL=1' in (probe_build / 'CMakeCache.txt').read_text()
    commands = subprocess.check_output([ninja, '-C', str(probe_build), '-t', 'commands', 'leveldbutil'], text=True)
    assert '/usr/bin/clang++' in commands and str(archive) in commands and '/opt/homebrew/lib/libsnappy' not in commands
    exported = (probe_stage / 'lib/cmake/leveldb/leveldbTargets.cmake').read_text()
    assert 'INTERFACE_LINK_LIBRARIES "snappy;Threads::Threads"' in exported and str(archive) not in exported
    log = probe_build / 'CMakeFiles/CMakeConfigureLog.yaml'
    if not log.exists(): log = probe_build / 'CMakeFiles/CMakeOutput.log'
    assert str(archive) in log.read_text()
    subprocess.run([str(probe_build / 'leveldbutil')], check=True)
    # Consume the real exported package, including the upstream bare target,
    # then prove a missing advertised Snappy target fails actual CMake.
    package = archive.parent / 'cmake/Snappy/SnappyConfig.cmake'
    package.write_text('add_library(Snappy::snappy STATIC IMPORTED)\nset_target_properties(Snappy::snappy PROPERTIES IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../../libsnappy.a")\n')
    (probe_stage / 'lib/cmake/leveldb/leveldbConfig.cmake').write_text('include("${CMAKE_CURRENT_LIST_DIR}/leveldbTargets.cmake")\n')
    downstream = work / 'downstream'; downstream.mkdir()
    (downstream / 'main.cc').write_text((probe / 'main.cc').read_text())
    (downstream / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.20)
project(installed-probe LANGUAGES C CXX)
find_package(Snappy CONFIG REQUIRED NO_DEFAULT_PATH PATHS "''' + str(package.parent) + '''")
find_package(Threads REQUIRED)
find_package(leveldb CONFIG REQUIRED NO_DEFAULT_PATH PATHS "''' + str(probe_stage / 'lib/cmake/leveldb') + '''")
add_executable(installed-probe main.cc)
target_link_libraries(installed-probe PRIVATE leveldb::leveldb)
file(GENERATE OUTPUT resolved.txt CONTENT "$<TARGET_FILE:Snappy::snappy>\\n")
''')
    downstream_build = work / 'downstream-build'
    configure = [cmake, '-S', str(downstream), '-B', str(downstream_build), '-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + ninja, '-DCMAKE_C_COMPILER=/usr/bin/clang', '-DCMAKE_CXX_COMPILER=/usr/bin/clang++', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_PROJECT_INCLUDE=' + str(work / 'leveldb-build/locked-snappy.cmake'), '-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF', '-DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON', '-DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF', '-DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF', '-DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF']
    for argv in (configure, [cmake, '--build', str(downstream_build)]):
        result = subprocess.run(argv, env=clean_env, capture_output=True, text=True); assert result.returncode == 0, result.stdout + result.stderr
    resolved = Path((downstream_build / 'resolved.txt').read_text().strip()).resolve(); assert resolved == archive
    commands = subprocess.check_output([ninja, '-C', str(downstream_build), '-t', 'commands', 'installed-probe'], text=True)
    assert '/usr/bin/clang++' in commands and str(archive) in commands and str(probe_stage / 'lib/libleveldb.a') in commands
    subprocess.run([str(downstream_build / 'installed-probe')], check=True)
    package.write_text('# Deliberately broken target contract\n')
    broken = configure.copy(); broken[broken.index('-B') + 1] = str(work / 'broken-downstream')
    result = subprocess.run(broken, env=clean_env, capture_output=True, text=True)
    assert result.returncode != 0 and 'Snappy::snappy' in result.stderr
print('PASS: locked argv/order, 2 installed consumer paths, 11 provenance/runtime rejection cases, database cleanup, real CMake probe/export/installed package link and broken target fixture')
PY
