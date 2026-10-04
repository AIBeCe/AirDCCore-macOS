#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" "$@" <<'PY'
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT/'scripts/lib'))
import dependency_build as deps
from dependency_lock import load_lock, canonical_bytes, topological_records
from dependency_prefix import validate_prefix
import core_stage

ORDER = ('bzip2','zlib','openssl','miniupnpc','leveldb','libmaxminddb','snappy','boost')

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def checked(*argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise AssertionError(result.stdout+result.stderr)

class ConsumerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='airdc-repro-link-', dir='/private/tmp')
        cls.work = Path(cls.temp.name)
        cls.tools = deps.resolve_tool_inventory()
        cls.lock = load_lock(ROOT/'config/dependencies.lock')
        cls.template = cls.work/'template with spaces'
        for directory in ('scripts','config','smoke-test','cmake'):
            shutil.copytree(ROOT/directory, cls.template/directory, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy2(ROOT/'CMakeLists.txt',cls.template/'CMakeLists.txt')
        write(cls.template/'docs/decisions/0001-aggregate-static-distribution.md',
              (ROOT/'docs/decisions/0001-aggregate-static-distribution.md').read_text())
        checkout = cls.template/'Source/airdcpp-core'
        write(checkout/'airdcpp/stdinc.h', '#pragma once\n')
        write(checkout/'airdcpp/core/version.h',
              '#include <string>\n#include "version.inc"\n'
              'namespace dcpp { std::string getVersionTag() noexcept; std::string getGitCommit() noexcept; }\n')
        for relative in ('CMakeLists.txt','airdcpp/hash/HashStore.cpp','scripts/generate_version.py',
                         'scripts/generate_stringdefs.py','airdcpp/core/localization/StringDefs.h'):
            (checkout/relative).parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(ROOT/'Source/airdcpp-core'/relative,checkout/relative)
        write(checkout/'.gitignore','/airdcpp/core/version.inc\n/airdcpp/core/localization/StringDefs.cpp\n')
        checked('git','init','-q',str(checkout))
        for key,value in (('user.name','Tests'),('user.email','tests@example.invalid'),('commit.gpgsign','false')):
            checked('git','-C',str(checkout),'config',key,value)
        checked('git','-C',str(checkout),'add','.')
        checked('git','-C',str(checkout),'commit','-qm','fixture',env={**os.environ,
            'GIT_AUTHOR_DATE':'1774518197 +0000','GIT_COMMITTER_DATE':'1774518197 +0000'})
        cls.pin = subprocess.check_output(('git','-C',str(checkout),'rev-parse','HEAD'),text=True).strip()
        checked('git','-C',str(checkout),'checkout','-q','--detach')
        checked('git','-C',str(checkout),'remote','add','origin','https://example.invalid/core.git')
        write(cls.template/'config/upstream.env',
              'AIRDCPP_CORE_URL=https://example.invalid/core.git\nAIRDCPP_CORE_COMMIT='+cls.pin+'\n')
        policy=json.loads((cls.template/'config/core-reproducible-policy.json').read_text())
        policy['upstream_commit']=cls.pin
        write(cls.template/'config/core-reproducible-policy.json',json.dumps(policy))
        write(checkout/'airdcpp/core/version.inc','#error original generated version is not a header authority\n')
        write(checkout/'airdcpp/core/localization/StringDefs.cpp','original generated forensic bytes\n')
        # Locked patches must be tracked by the consuming project, as in the
        # real checkout. Keep that provenance check active in private fixtures.
        checked('git','init','-q',str(cls.template))
        for patch in (cls.template/'config/patches').glob('*'):
            checked('git','-C',str(cls.template),'add',str(patch.relative_to(cls.template)))
        symbols = {'bzip2':'bz2','zlib':'z','openssl':'ssl','miniupnpc':'mini',
                   'leveldb':'level','libmaxminddb':'max','snappy':'snappy','boost':'boost'}
        for record in cls.lock.dependencies:
            prefix = cls.template/'Build/prefix'/record.name
            for relative in (*record.expected_headers,*record.license_paths):
                write(prefix/relative, 'fixture\n')
            for relative in record.expected_metadata:
                write(prefix/relative, '# fixture\n' if relative.endswith('.cmake') else
                      'prefix=${pcfiledir}/../..\nName: fixture\nVersion: 1.0\nLibs: -L${prefix}/lib -lfixture\n')
            for ordinal,relative in enumerate(record.expected_archives):
                symbol = 'crypto' if record.name=='openssl' and ordinal==1 else symbols[record.name]
                body = 'return 1;'
                if symbol in ('ssl','level'):
                    other = 'crypto' if symbol=='ssl' else 'snappy'
                    body = 'return fixture_'+other+'();'
                    declaration = 'int fixture_'+other+'(void);\n'
                else:
                    declaration = ''
                source = cls.work/(record.name+str(ordinal)+'.c')
                write(source, declaration+'int fixture_'+symbol+'(void) { '+body+' }\n')
                obj = source.with_suffix('.o')
                checked(cls.tools.apple['cc'],'-arch','arm64','-mmacosx-version-min=14.0','-c',str(source),'-o',str(obj))
                (prefix/relative).parent.mkdir(parents=True,exist_ok=True)
                checked(cls.tools.apple['ar'],'rcs',str(prefix/relative),str(obj))
        write(cls.template/'Build/airdcpp-core/core-release/historical.txt','Gate 3 unchanged\n')
        write(cls.template/'Build/airdcpp-core/link-interface/historical.txt','OpenSSL 3.6.4 unchanged\n')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix='case with spaces-',dir=self.work))
        shutil.copytree(self.template,self.case,dirs_exist_ok=True)
        self.core = self.case/'Build/airdcpp-core/reproducible-release'
        self.output = self.case/'Build/airdcpp-core/reproducible-link-interface'
        reports = {}
        for record in topological_records(self.lock):
            prefix = self.case/'Build/prefix'/record.name
            component = self.case/'Build/dependencies'/record.name
            report = validate_prefix(record,prefix,dict(project=self.case,source=self.case/'Dependencies'/record.name,
                build=component,home=component/'home'),tools=self.tools.apple)
            reports[record.name] = report
            evidence = component/'evidence'
            inputs = deps._input_document(self.lock,record,deps.adapter_path(self.case,record),
                                          {n:reports[n] for n in record.dependencies},self.tools)
            write(evidence/'input-fingerprint.txt',hashlib.sha256(deps._canonical_json(inputs)).hexdigest()+'\n')
            write(evidence/'prefix-report.json',deps._canonical_json(report.as_dict()).decode())
            write(evidence/'install-manifest.jsonl',report.manifest)
            write(evidence/'license-inventory.json',deps._canonical_json([
                dict(path='$PREFIX/'+p,sha256=hashlib.sha256((prefix/p).read_bytes()).hexdigest())
                for p in record.license_paths]).decode())
            write(evidence/'exit-status.txt','0\n')
        write(self.core/'component-manifests.tsv','component\tmanifest_sha256\n'+''.join(
            n+'\t'+reports[n].manifest_sha256+'\n' for n in ORDER))
        write(self.core/'tool-inventory.json',deps._canonical_json(asdict(self.tools)).decode())
        write(self.core/'lock-fingerprint.txt',hashlib.sha256(canonical_bytes(self.lock)).hexdigest()+'\n')
        write(self.core/'upstream-identity.json',deps._canonical_json(dict(commit=self.pin,
            origin='https://example.invalid/core.git',source_prefix_map='airdcpp-core')).decode())
        write(self.core/'build-exit-code.txt','0\n')
        prepared=core_stage.prepare_core_source(self.case,self.case/'Source/airdcpp-core',
                                               self.core,self.tools,os.environ,sys.executable)
        stage=Path(prepared['staged_root'])
        checked(sys.executable,str(self.case/'scripts/lib/core_stage.py'),'version',prepared['version_authority'],
                prepared['version_authority_sha256'],'--',sys.executable,'scripts/generate_version.py',
                './airdcpp/core/version.inc','0.0.0','AirDCCore-macOS','org.airdcpp.core.macos.configure',cwd=stage)
        checked(sys.executable,'scripts/generate_stringdefs.py','./airdcpp/core/localization/',cwd=stage)
        core_stage.finalize_core_source(self.case,self.case/'Source/airdcpp-core',self.core,self.tools,sys.executable)
        self.make_core(self.pin)
        self.bin = self.case/'fixture-bin'
        self.bin.mkdir()
        # Tool discovery is real. Intercept only a requested external-tool fault;
        # all CMake, compiler, linker, archive and executable checks run for real.
        write(self.bin/'python3',f'''#!{sys.executable}
import json, os, subprocess, sys
from pathlib import Path
control=json.loads(Path({str(self.case/'control.json')!r}).read_text())
original=subprocess.run
def run(argv,*args,**kwargs):
    if '--build' in argv and control.get('MUTATE'):
        Path(control['MUTATE']).write_text('changed')
    if '--build' in argv and control.get('BUILD_FAIL'):
        return subprocess.CompletedProcess(argv,29)
    return original(argv,*args,**kwargs)
subprocess.run=run
sys.argv=sys.argv[1:]
exec(compile(sys.stdin.read(),'<consumer>', 'exec'),{{'__name__':'__main__'}})
''')
        (self.bin/'python3').chmod(0o755)
        self.env = {**os.environ,'PATH':str(self.bin)+':'+os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1'}
        for key in ('CMAKE_PREFIX_PATH','CMAKE_MODULE_PATH','PKG_CONFIG_PATH','CPATH','LIBRARY_PATH','CFLAGS','LDFLAGS'):
            self.env[key]='/opt/homebrew/poison'

    def make_core(self, identity, extra='', tag='0.0.0'):
        source = self.work/'core.cpp'
        declarations = ''.join('int fixture_'+n+'(void);' for n in ('bz2','z','ssl','mini','level','max'))
        write(source, '#include <string>\n#include <iconv.h>\nextern "C" { '+declarations+' }\n'+extra+
              '\nnamespace dcpp { std::string getVersionTag() noexcept { return "'+tag+'"; } '
              'std::string getGitCommit() noexcept { '+
              ''.join('fixture_'+n+'();' for n in ('bz2','z','ssl','mini','level','max'))+
              'iconv_t c=iconv_open("UTF-8","ASCII"); if(c!=(iconv_t)-1) iconv_close(c); '
              'return "'+identity+'"; } }\n')
        obj = self.work/'core.o'
        checked(self.tools.apple['cxx'],'-std=c++20','-arch','arm64','-mmacosx-version-min=14.0',
                '-isysroot',self.tools.sdkroot,'-c',str(source),'-o',str(obj))
        archive = self.core/'upstream/libairdcpp.a'
        archive.parent.mkdir(parents=True,exist_ok=True)
        archive.unlink(missing_ok=True)
        checked(self.tools.apple['ar'],'rcs',str(archive),str(obj))
        checked(sys.executable,str(ROOT/'scripts/lib/inspect_core_archive.py'),str(archive),
                str(self.core/'archive-members.tsv'),str(self.core/'archive-symbols.txt'))
        for field,args in (('archive-strings.txt',(self.tools.apple['strings'],str(archive))),
                           ('archive-ar-table.txt',(self.tools.apple['ar'],'-t',str(archive)))):
            write(self.core/field,subprocess.check_output(args,text=True))
        write(self.core/'archive-sha256.txt',hashlib.sha256(archive.read_bytes()).hexdigest()+'  upstream/libairdcpp.a\n')

    def invoke(self, **control):
        write(self.case/'control.json',json.dumps(control))
        return subprocess.run(('/bin/sh',str(self.case/'scripts/build'),'--link-reproducible-consumer'),
                              env=self.env,text=True,capture_output=True)

    def failed(self, message, **control):
        result = self.invoke(**control)
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn(message,result.stdout+result.stderr)
        return result

    def test_force_loaded_static_closure_omission_fixed_point_and_pinned_runtime(self):
        result = self.invoke()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.output/'run/stdout.txt').read_text(),'AirDC++ Core '+self.pin+'\n')
        self.assertEqual((self.output/'run/exit-code.txt').read_text(),'0\n')
        rows = (self.output/'link-interface.tsv').read_text().splitlines()
        self.assertEqual([r.split('\t')[1:] for r in rows], [
            ['core','stage/lib/libairdcpp.a'],['component:bzip2','lib/libbz2.a'],['component:zlib','lib/libz.a'],
            ['component:openssl','lib/libssl.a'],['component:openssl','lib/libcrypto.a'],
            ['component:miniupnpc','lib/libminiupnpc.a'],['component:leveldb','lib/libleveldb.a'],
            ['component:libmaxminddb','lib/libmaxminddb.a'],['component:snappy','lib/libsnappy.a'],
            ['apple-sdk','usr/lib/libiconv.2.tbd']])
        omissions=(self.output/'omission-results.tsv').read_text().splitlines()[1:]
        self.assertEqual(len(omissions),19)
        self.assertEqual([r.split('\t')[2] for r in omissions if r.startswith('2\t')],
                         ['BZip2','ZLIB','OpenSSLSSL','miniupnpc','leveldb','maxminddb','Iconv'])
        command=(self.output/'full/configure-command.txt').read_text()
        self.assertIn('-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF',command)
        self.assertNotIn('/opt/homebrew/poison',command)
        env=json.loads((self.output/'environment.json').read_text())
        self.assertFalse(env.get('CPATH'))
        self.assertEqual(env['HOME'],str(self.output/'home'))
        self.assertTrue((self.output/'full/attempts/0001/sha256.txt').is_file())
        defaults=json.loads((self.output/'openssl-runtime-defaults.json').read_text())
        self.assertEqual(defaults['version'],'3.5.8')
        self.assertEqual(defaults['configured'],{'OPENSSLDIR':'/usr/local/ssl',
            'ENGINESDIR':'/usr/local/lib/engines-3','MODULESDIR':'/usr/local/lib/ossl-modules'})
        self.assertEqual((self.case/'Build/airdcpp-core/link-interface/historical.txt').read_text(),
                         'OpenSSL 3.6.4 unchanged\n')
        self.assertFalse((self.case/'Dist').exists())
        self.assertEqual((self.output/'stage/include/airdcpp/core/version.inc').read_bytes(),
                         (self.core/'source/airdcpp/core/version.inc').read_bytes())
        self.assertEqual((self.case/'Source/airdcpp-core/airdcpp/core/version.inc').read_text(),
                         '#error original generated version is not a header authority\n')
        for name in core_stage.EVIDENCE_FILES:
            self.assertEqual((self.output/name).read_bytes(),(self.core/name).read_bytes())
        inputs=json.loads((self.output/'input-manifest.json').read_text())
        self.assertEqual(inputs['smoke_source_path'],'smoke-test/reproducible-main.cpp')
        self.assertEqual(inputs['smoke_source_sha256'],
                         hashlib.sha256((self.case/'smoke-test/reproducible-main.cpp').read_bytes()).hexdigest())
        self.assertEqual(inputs['expected_version_tag'],'0.0.0')
        self.assertEqual(inputs['expected_git_commit'],self.pin)
        self.assertEqual(inputs['core_source_evidence_sha256'],{
            name:hashlib.sha256((self.core/name).read_bytes()).hexdigest() for name in core_stage.EVIDENCE_FILES})

    def test_runtime_pin_is_enforced(self):
        self.make_core('wrong')
        self.failed('consumer runtime identity differs from pinned Core')

    def test_runtime_tag_is_enforced_with_valid_stage_provenance(self):
        self.make_core(self.pin,tag='wrong-tag')
        self.failed('consumer runtime identity differs from pinned Core')

    def test_stage_header_and_declared_root_tampering_are_rejected_before_link(self):
        header=self.core/'source/airdcpp/core/version.h'
        original=header.read_bytes()
        header.write_bytes(original+b'// changed\n')
        self.failed('Core staged content differs')
        self.assertFalse((self.output/'core-only').exists())
        header.write_bytes(original)
        provenance=self.core/'core-source-provenance.json'
        authority=json.loads(provenance.read_text())
        authority['header_root']=str(self.case/'Source/airdcpp-core/airdcpp')
        provenance.write_bytes(core_stage.canonical(authority))
        self.failed('Core completed staged provenance differs')
        self.assertFalse((self.output/'core-only').exists())

    def test_version_authority_fingerprint_and_incomplete_stage_are_rejected(self):
        for name,message in (('version-authority.json','Core authority differs'),
                             ('core-input-fingerprint.txt','Core input fingerprint differs'),
                             ('core-source-provenance.json','Core completed staged provenance differs')):
            with self.subTest(name=name):
                path=self.core/name
                original=path.read_bytes()
                path.write_bytes(original+b'\n')
                self.failed(message)
                self.assertFalse((self.output/'core-only').exists())
                path.write_bytes(original)
        provenance=self.core/'core-source-provenance.json'
        authority=json.loads(provenance.read_text())
        authority['complete']=False
        provenance.write_bytes(core_stage.canonical(authority))
        self.failed('Core completed staged provenance differs')

    def test_stage_header_symlink_is_rejected_without_mutating_source(self):
        header=self.core/'source/airdcpp/core/version.h'
        original=self.case/'Source/airdcpp-core/airdcpp/core/version.h'
        before=original.stat()
        header.unlink()
        header.symlink_to(original)
        self.failed('unsafe staged content')
        after=original.stat()
        self.assertEqual((before.st_ino,before.st_mtime_ns),(after.st_ino,after.st_mtime_ns))
        self.assertFalse((self.output/'core-only').exists())

    def test_compound_driver_flag_cannot_add_explicit_system_link(self):
        cmake=self.case/'smoke-test/CMakeLists.txt'
        cmake.write_text(cmake.read_text()+
            '\ntarget_link_options(airdcpp-smoke PRIVATE "-Wl,-dead_strip,-lSystem")\n')
        self.failed('link contract differs from ADR 0001')
        self.assertIn('-Wl,-dead_strip,-lSystem',(self.output/'link-command.raw.txt').read_text())
        self.assertEqual((self.output/'full/build-exit-code.txt').read_text(),'0\n')
        self.assertFalse((self.output/'adr-comparison.txt').exists())

    def test_path_leak_is_rejected_but_declared_openssl_defaults_are_recorded(self):
        self.make_core(self.pin,'__attribute__((used)) static const char leaked[]="/opt/homebrew/lib/libforeign.a";')
        self.failed('consumer contains prohibited paths')

    def test_failed_build_still_checks_external_scope_and_records_status(self):
        self.failed('scope changed outside reproducible-link-interface',BUILD_FAIL=True,
                    MUTATE=str(self.case/'Build/airdcpp-core/link-interface/historical.txt'))
        self.assertEqual((self.output/'core-only/build-exit-code.txt').read_text(),'29\n')

    def test_successful_link_still_checks_external_scope(self):
        self.failed('scope changed outside reproducible-link-interface',
                    MUTATE=str(self.case/'Build/airdcpp-core/link-interface/historical.txt'))

    def test_prefix_and_core_evidence_are_revalidated_before_link(self):
        write(self.case/'Build/prefix/bzip2/include/bzlib.h','changed')
        self.failed('accepted evidence mismatch')
        self.assertFalse((self.output/'core-only').exists())

    def test_output_ancestor_symlink_is_rejected(self):
        outside=self.work/'outside'
        outside.mkdir(exist_ok=True)
        self.output.symlink_to(outside,target_is_directory=True)
        self.failed('unsafe directory')
        self.assertEqual(list(outside.iterdir()),[])

    def test_changed_core_hash_and_task8_binding_are_rejected(self):
        manifest=self.core/'component-manifests.tsv'
        original=manifest.read_bytes()
        manifest.write_bytes(original+b'foreign\tbad\n')
        self.failed('Task 8 Core evidence differs: component-manifests.tsv')
        manifest.write_bytes(original)
        archive=self.core/'upstream/libairdcpp.a'
        archive.write_bytes(archive.read_bytes()+b'changed')
        self.failed('Task 8 Core archive hash differs')
        self.assertFalse((self.output/'core-only').exists())

unittest.main(argv=[sys.argv[0],*sys.argv[2:]],verbosity=2)
PY
